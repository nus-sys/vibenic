// =============================================================================
// LookupDispatcher — spec §5.1 step 3 ("Dispatch"), §5.2, §6.
//
// Joins the three ingress-side FIFOs (header / payload / lookup-response) plus
// the echoed FlowKey, all of which arrive strictly in ingress (packet) order
// and aligned: per accepted packet there is exactly one header beat, 8 payload
// beats, one FlowKvsResp (Found/Fail only — Succ never reaches here) and one
// FlowKey.  Per packet:
//
//   * HIT  (tagged Found v):  unpackFlowVal(v) -> {flow_ident,off_ch0/2/4};
//     issue the three chan-local 512 B-aligned HBM byte addresses (zero-
//     extended to 33b), forward the header beat + flow_ident downstream and
//     stream this packet's 8 payload beats to PayloadPostFIFO. Pulse .hit.
//   * MISS (tagged Fail):     build a NotifyDesc from the echoed FlowKey and
//     the free-running user-clock cycle counter (spec §8 "local user clock
//     cycles at miss"); discard the header and drain this packet's 8 payload
//     beats. Pulse .miss.
//
// Dataflow style per docs/10-bsv-dataflow-handshaking.md & docs/11-bsv-packet-per-beat.md:
// every move is a rule over FIFOs, exactly one beat consumed/produced per rule
// firing, all handshaking implicit (notEmpty on first/deq, notFull on enq —
// so if any post-FIFO fills the rule simply does not fire and the stall
// propagates upstream automatically). A small FSM (IDLE/FWD_PL/DROP_PL) with a
// beat counter keeps the payload stream beat-accurate and prevents re-
// dispatching the next packet's header/resp/key until the current packet's 8
// payload beats are fully drained.
//
// FIFO flavour / sizing (spec §5.2, N_INFLIGHT=32):
//   hdrF     mkSizedFIFO(64)        — ingress header slack (32+ pkts)
//   payloadF mkSizedBRAMFIFO(256)   — 32 pkts * 8 beats of 512 b in BRAM
//   respF    mkSizedFIFO(32)        — one lookup resp / pkt
//   keyF     mkSizedFIFO(32)        — one echoed key / pkt
//   cmd0/2/4 mkSizedFIFO(32)        — one 33-bit HBM addr / hit / channel
//   hdrPostF mkSizedFIFO(64)        — header beat / hit -> egress
//   plPostF  mkSizedBRAMFIFO(256)   — 8 beats / hit -> averager payload
//   fidPostF mkSizedFIFO(32)        — flow_ident / hit -> egress
//   notifyF  mkSizedFIFO(32)        — NotifyDesc / miss -> notify engine
// =============================================================================
package LookupDispatcher;

import FIFO::*;
import GetPut::*;
import DefaultValue::*;
import BRAMFIFO::*;

import FlowReduceDefines::*;   // shared types + IfcLookupDispatcher

// FSM: IDLE dispatches one packet's header/resp/key; FWD_PL forwards its 8
// payload beats (hit); DROP_PL discards its 8 payload beats (miss).
typedef enum { IDLE, FWD_PL, DROP_PL } DispState deriving (Bits, Eq, FShow);

// 8 payload beats per packet; plcnt counts 0..7, last beat is the 8th.
UInt#(4) lastPlIdx = 7;

(* synthesize *)
module mkLookupDispatcher (IfcLookupDispatcher);

    // ---- Ingress-side buffers (aligned, in packet order) -------------------
    FIFO#(NfBeat)      hdrF     <- mkSizedFIFO(64);
    FIFO#(NfBeat)      payloadF <- mkSizedBRAMFIFO(256);
    FIFO#(FlowKvsResp) respF    <- mkSizedFIFO(32);
    FIFO#(FlowKey)     keyF     <- mkSizedFIFO(32);

    // ---- Post-dispatch outputs --------------------------------------------
    FIFO#(Bit#(33))   cmd0F     <- mkSizedFIFO(32);
    FIFO#(Bit#(33))   cmd2F     <- mkSizedFIFO(32);
    FIFO#(Bit#(33))   cmd4F     <- mkSizedFIFO(32);
    FIFO#(NfBeat)     hdrPostF  <- mkSizedFIFO(64);
    FIFO#(NfBeat)     plPostF   <- mkSizedBRAMFIFO(256);
    FIFO#(Bit#(32))   fidPostF  <- mkSizedFIFO(32);
    FIFO#(NotifyDesc) notifyF   <- mkSizedFIFO(32);

    // ---- Free-running user-clock cycle counter (spec §8 timestamp) --------
    Reg#(Bit#(64)) cyc <- mkReg(0);
    (* fire_when_enabled, no_implicit_conditions *)
    rule do_cyc;
        cyc <= cyc + 1;
    endrule

    // ---- Dispatch FSM ------------------------------------------------------
    Reg#(DispState)  st    <- mkReg(IDLE);
    Reg#(UInt#(4))   plcnt <- mkReg(0);

    // Counter pulses (combinational, asserted only on the dispatch cycle).
    PulseWire pulseHit  <- mkPulseWire;
    PulseWire pulseMiss <- mkPulseWire;

    // do_dispatch: one packet's header + lookup-resp + echoed key consumed
    // together (all three arrive aligned in packet order). HIT issues the
    // three HBM addresses + forwards header & flow_ident, then enters FWD_PL
    // to stream the 8 payload beats. MISS builds the NotifyDesc and enters
    // DROP_PL to discard the 8 payload beats. The FSM (st != IDLE while a
    // packet's payload drains) blocks re-dispatch, so header/resp/key are
    // consumed exactly once per packet.
    rule do_dispatch (st == IDLE);
        let r = respF.first;  respF.deq;
        let h = hdrF.first;   hdrF.deq;
        let k = keyF.first;   keyF.deq;
        case (r) matches
            tagged Found .v : begin
                FlowVal fv = unpackFlowVal(v);
                cmd0F.enq(zeroExtend(fv.off_ch0));
                cmd2F.enq(zeroExtend(fv.off_ch2));
                cmd4F.enq(zeroExtend(fv.off_ch4));
                hdrPostF.enq(h);
                fidPostF.enq(fv.flow_ident);
                pulseHit.send;
                plcnt <= 0;
                st    <= FWD_PL;
            end
            // Only Found / Fail reach this port; treat anything not-Found
            // (Fail) as a miss.
            default : begin
                notifyF.enq(NotifyDesc {
                    src_ip:           k.src_ip,
                    dst_ip:           k.dst_ip,
                    src_port:         k.src_port,
                    dst_port:         k.dst_port,
                    proto:            k.proto,
                    timestamp_cycles: cyc
                });
                pulseMiss.send;
                plcnt <= 0;
                st    <= DROP_PL;
            end
        endcase
    endrule

    // do_fwd_pl: forward this hit packet's payload beats one per firing; the
    // 8th (beat.last) returns to IDLE for the next packet.
    rule do_fwd_pl (st == FWD_PL);
        let b = payloadF.first; payloadF.deq;
        plPostF.enq(b);
        if (b.last) st <= IDLE;
        else        plcnt <= plcnt + 1;
    endrule

    // do_drop_pl: discard this miss packet's payload beats one per firing;
    // the 8th (beat.last) returns to IDLE. Draining exactly 8 keeps the
    // stream packet-aligned for the following packet.
    rule do_drop_pl (st == DROP_PL);
        let b = payloadF.first; payloadF.deq;
        if (b.last) st <= IDLE;
        else        plcnt <= plcnt + 1;
    endrule

    // ---- Interface ---------------------------------------------------------
    interface Put hdr_in         = toPut(hdrF);
    interface Put payload_in     = toPut(payloadF);
    interface Put lookup_resp_in = toPut(respF);
    interface Put key_echo_in    = toPut(keyF);

    interface Get hdr_post       = toGet(hdrPostF);
    interface Get payload_post   = toGet(plPostF);
    interface Get flowident_post = toGet(fidPostF);
    interface Get hbm_cmd0       = toGet(cmd0F);
    interface Get hbm_cmd2       = toGet(cmd2F);
    interface Get hbm_cmd4       = toGet(cmd4F);
    interface Get notify_out     = toGet(notifyF);

    method CntPulse cntPulse;
        CntPulse p = defaultValue;
        p.hit  = pulseHit;
        p.miss = pulseMiss;
        return p;
    endmethod

endmodule : mkLookupDispatcher

endpackage : LookupDispatcher
