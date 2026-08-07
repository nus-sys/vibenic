// =============================================================================
// HBMReadEngine — spec §4.2, §5.1 steps 3-4, §5.3 (the 3-channel HBM reader).
//
// Three independent, identical channels (HBM ch0, ch2, ch4 of the left stack).
// Each channel takes a 33-bit byte address (`cmd_chN`, host-assigned, 512 B-
// aligned per spec §4.2) and issues exactly ONE AXI4 read burst of 8 beats of
// 64 B = one 512 B reference vector (spec §4.2: "HBM reads ... are bursts of
// length 8, size 64 B — one full vector per burst"). 8 beats is the HBM
// maximum (Axi4BusesDefines: "bursts shall not be more than 8 beats"), so the
// burst is already maximal — there is NO burst chunking (asserted by
// staticAssert below).
//
// A fixed per-channel ARID of 0 (spec §5.1 step 4: "fixed ARID per channel")
// means the AXI fabric returns this channel's responses strictly in request
// order, so per-channel reassembly is a simple beat counter — no reorder /
// id-keyed tracking is needed (spec §5.1 step 4 "individually FIFO-ordered").
//
// TLM layering per docs/12-bsv-axi-transactions.md: the channel emits TLM3
// `TLMRequest` into reqF and consumes `TLMResponse` from respF;
// mkAxi4MasterFromFifoPair (Axi4Utilities) turns the FIFO pair into the AXI4
// master port.
//
// SINGLE OUTSTANDING READ BURST PER CHANNEL (`inflight` counter): the `cmd`
// port will not accept (hence the master will not issue) burst N+1's AR until
// burst N's 8th read-data beat has been consumed by do_read_resp. An in-order
// HBM read slave serves one burst at a time and can only observe a new AR
// between bursts (spec §5.1-step-4 "fixed ARID, FIFO-ordered, no reorder"; the
// verification HBM slave is exactly this). If the master is allowed to drive
// the next AR while the slave is still streaming the current burst's data, it
// holds ARVALID asserted with ARREADY high — the slave, busy mid-burst,
// advances past and drops those ARs. A dropped AR is a burst whose 8 data
// beats + err token never return, so the averager's 4-input rendezvous and
// the top RRESP-gate (which needs all three channels' err tokens for that
// packet) stall forever — the packet is counted in CNT_HIT at dispatch but
// never reaches mkResultEgress, breaking the spec §7 conservation law
// CNT_HIT == CNT_PROCESSED + CNT_HBM_ERR by exactly the stalled-packet count.
// It only bites once HBM read latency / egress backpressure stretch the
// slave's per-burst busy window past the master's next-AR issue (at full rate
// the slave is idle between bursts and never misses an AR — hence Phase 1 is
// byte-perfect and only the first backpressured packet is lost). One
// outstanding burst per channel is within the spec's "up to 32 ... on one
// ARID" envelope and changes only read-pipeline depth: returned data, packet
// ordering, error stickiness and every counter stay bit-identical.
// The READ-issue / descriptor-build idiom and the TLMResponse field names
// (.command/.data/.status/.is_last, status enum SUCCESS, b_size enum BITS512,
// RequestDescriptor.b_length = beats-1) follow the canonical reference
// PrstKvsValBuf.bsv (axi_rd_issue / do_read_val_cplflush) and the burst-read
// slave model PseudoAxi4Dram.bsv (one Descriptor in, b_length+1 TLMResponse
// beats out, is_last on the final beat).
//
// Error stickiness (spec §5.3): RRESP != OKAY surfaces as a TLM response
// status != SUCCESS on some beat of a burst. We OR it into a per-channel
// `errAcc` across the burst's 8 beats and emit exactly one Bool err token per
// burst (True iff any beat of that burst had a non-OKAY response) when the 8th
// beat is produced, then clear errAcc. All 8 data beats are still produced so
// downstream rendezvous / drain (spec §5.3) stays beat-aligned.
//
// FIFO sizing (spec §5.2/§5.3): the per-channel data buffer holds >= 32 bursts
// (32*8 = 256 beats) in BRAM; the err FIFO holds 32 tokens.
// =============================================================================
package HBMReadEngine;

import FIFO::*;
import GetPut::*;
import Vector::*;
import BRAMFIFO::*;
import Assert::*;
import Counter::*;

import FlowReduceDefines::*;   // shared types + IfcHBMReadEngine + AXI presets

// One AXI burst = 8 beats of 64 B = 512 B. ARLEN field = beats - 1 = 7.
// hbmBurstBeats (=8) comes from FlowReduceDefines (spec §4.2).
UInt#(4) lastBeatIdx = 7;      // 0..7, the 8th (final) beat of every burst

// -----------------------------------------------------------------------------
// Per-channel sub-interface: command in, data/err out, and the AXI master port
// for this channel.  mkHBMReadEngine instantiates three of these and exposes
// the three masters as Vector#(3, HbmAxiMasterIfc) = [ch0, ch2, ch4].
// -----------------------------------------------------------------------------
interface IfcHbmChannel;
    interface Put#(Bit#(33))      cmd;
    interface Get#(NfBeat)        data;
    interface Get#(Bool)          err;
    interface HbmAxiMasterIfc     axi;
endinterface

module mkHbmChannel (IfcHbmChannel);

    // One full 8-beat burst stays inside one HBM page (host offsets are 512 B-
    // aligned, spec §4.2) and is already the HBM maximum — assert no chunking.
    staticAssert(hbmBurstBeats == 8,
        "HBMReadEngine: a 512 B vector is exactly one 8-beat AXI burst; "
      + "burst chunking is intentionally absent (8 is the HBM maximum).");

    // TLM request/response FIFO pair -> AXI4 master.  max_flight only bounds
    // the transactor's internal response tracking; it does NOT throttle AR
    // issue (the xactor still pulls every queued reqF descriptor into its AR
    // address FIFO and keeps ARVALID asserted), so the single-outstanding
    // discipline that the in-order HBM slave requires is enforced explicitly
    // by the `inflight` counter gating the `cmd` port (see header + below).
    FIFO#(HbmTlmReq_t)  reqF  <- mkLFIFO;
    FIFO#(HbmTlmResp_t) respF <- mkLFIFO;
    HbmAxiMasterIfc     m     <- mkAxi4MasterFromFifoPair(reqF, respF, 32);

    // One-outstanding-burst-per-channel gate. `cmd` only accepts a new burst
    // when inflight.value == 0; it .up's on accept, and do_read_resp .down's
    // on the burst's last data beat.  Counter up/down are conflict-free, and
    // because `cmd` is blocked while value != 0 there is never a simultaneous
    // up+down on the same packet — the channel issues AR_N, waits for all 8
    // RDATA_N beats to be drained, then (next cycle) may issue AR_{N+1}, so a
    // single-burst-at-a-time HBM slave never sees an AR while it is mid-burst.
    Counter#(2) inflight <- mkCounter(0);

    // Output buffers (spec §5.2/§5.3): >=32 bursts of data in BRAM, 32 err
    // tokens.  256 = 32 bursts * 8 beats.
    FIFO#(NfBeat) dataF <- mkSizedBRAMFIFO(256);
    FIFO#(Bool)   errF  <- mkSizedFIFO(32);

    // Per-channel response reassembly state. Responses for this ARID arrive in
    // request order (AXI in-order guarantee for a single ID), so a plain beat
    // counter 0..7 reconstructs burst boundaries; errAcc is the sticky OR of
    // the non-OKAY status across the 8 beats of the current burst.
    Reg#(UInt#(4)) rbeat  <- mkReg(0);
    Reg#(Bool)     errAcc <- mkReg(False);

    // Response rule. Each respF pop is one 512-bit READ data beat (the slave /
    // transactor expands a length-N burst into N TLMResponse beats — see
    // PseudoAxi4Dram.bsv). Emit it as an NfBeat with last on the 8th beat;
    // accumulate the sticky error; on the 8th beat emit the err token and
    // reset the per-burst state. aggressive_implicit_conditions so the single
    // rule still fires when only one of the enq targets gates.
    (* aggressive_implicit_conditions *)
    rule do_read_resp;
        let tlmresp <- toGet(respF).get;
        Bool isLast  = (rbeat == lastBeatIdx);
        Bool thisErr = (tlmresp.status != SUCCESS);   // RRESP != OKAY
        dataF.enq(NfBeat { data: tlmresp.data, keep: '1, last: isLast });
        if (isLast) begin
            errF.enq(errAcc || thisErr);
            inflight.down;          // burst complete -> allow the next AR
            rbeat  <= 0;
            errAcc <= False;
        end else begin
            rbeat  <= rbeat + 1;
            errAcc <= errAcc || thisErr;
        end
    endrule

    // Issue exactly one length-8 read burst for the requested 33-bit byte addr.
    // Implicit condition inflight.value == 0: hold off the next burst's AR
    // until the previous burst's read data has been fully drained, so an
    // in-order, one-burst-at-a-time HBM read slave never sees a second AR
    // while it is mid-burst (see the module header for the failure mode).
    interface Put cmd;
        method Action put (Bit#(33) addr) if (inflight.value == 0);
            // Start from defaultValue and set ONLY the fields we need (prevents
            // stale b_length/b_size — see docs/12-bsv-axi-transactions.md).
            HbmTlmReqDesc_t d = defaultValue;
            d.command        = READ;
            d.addr           = zeroExtend(addr);                 // 33-bit byte addr
            d.b_length       = fromInteger(hbmBurstBeats - 1);   // = 7 (8 beats)
            d.b_size         = BITS512;                          // 64 B / beat
            d.transaction_id = 0;                                // fixed ARID 0
            reqF.enq(tagged Descriptor d);
            inflight.up;            // one burst now outstanding on this channel
        endmethod
    endinterface

    interface Get data = toGet(dataF);
    interface Get err  = toGet(errF);
    interface HbmAxiMasterIfc axi = m;

endmodule : mkHbmChannel

// -----------------------------------------------------------------------------
// Top: three identical channels, instantiated via a Vector to avoid copy-paste,
// wired straight to the IfcHBMReadEngine ports in the fixed order [ch0,ch2,ch4].
// -----------------------------------------------------------------------------
(* synthesize *)
module mkHBMReadEngine (IfcHBMReadEngine);

    // ch[0] -> HBM ch0, ch[1] -> HBM ch2, ch[2] -> HBM ch4 (spec §3 / §5.1).
    Vector#(3, IfcHbmChannel) ch <- replicateM(mkHbmChannel);

    Vector#(3, HbmAxiMasterIfc) axiv;
    for (Integer i = 0; i < 3; i = i + 1)
        axiv[i] = ch[i].axi;

    interface Put cmd_ch0 = ch[0].cmd;
    interface Put cmd_ch2 = ch[1].cmd;
    interface Put cmd_ch4 = ch[2].cmd;

    interface Get data_ch0 = ch[0].data;
    interface Get data_ch2 = ch[1].data;
    interface Get data_ch4 = ch[2].data;

    interface Get err_ch0 = ch[0].err;
    interface Get err_ch2 = ch[1].err;
    interface Get err_ch4 = ch[2].err;

    interface hbm_axi = axiv;

endmodule : mkHBMReadEngine

endpackage : HBMReadEngine
