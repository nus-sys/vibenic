// =============================================================================
// NotifyEngine — spec §8 "New-Flow Notification".
//
// On every flow-table miss mkLookupDispatcher hands us a NotifyDesc. We write
// one 32-byte `notify_entry` (C layout fixed by toNotifyEntry in
// FlowReduceDefines — already wire-ordered, NO byte swap) into the host
// notification ring via the AXI-MM-to-PCIe master (XDMA-bypass preset
// 4,64,512,8,0, 64-bit host address).
//
// Ring bookkeeping (host-visible registers 0x40/0x44/0x48/0x4C/0x50):
//   base       = {NOTIFY_BASE_HI, NOTIFY_BASE_LO}   (NotifyCfg.base)
//   size_log2  = NOTIFY_SIZE_LOG2                    (ring length = 2^size_log2)
//   tail       = NOTIFY_TAIL  (host read index, advanced by host)
//   head       = NOTIFY_HEAD  (NIC write index, RO — this module owns it)
//   mask       = (1 << size_log2) - 1
//   ring_full  = ((head + 1) & mask) == tail
//
// The NIC advances HEAD only AFTER a successful B response — never on issue —
// so a HEAD the host samples always points at a fully-committed entry. On a
// full ring the entry is dropped (no AXI traffic, HEAD unchanged) and the
// notify_drop counter pulse fires for one cycle.
//
// Datapath per docs/10-bsv-dataflow-handshaking.md + docs/12-bsv-axi-transactions.md:
//   notify_in.put  -> inF (mkFIFO)
//   do_issue       : pops inF; drop-on-full OR builds the WRITE descriptor
//                    (single beat, b_length=0, BITS512, wstrb = low 32 bytes)
//                    and enqs into reqF; remembers it is awaiting a B-resp.
//   do_write_cpl   : drains the B response from respF and advances headR.
// The TLM FIFO pair is turned into the AXI4 master by mkAxi4MasterFromFifoPair
// exactly as in kvs_cuckoo/src/PrstKvsValBuf.bsv.
// =============================================================================
package NotifyEngine;

import FIFO::*;
import GetPut::*;
import DefaultValue::*;
import ConfigReg::*;

import FlowReduceDefines::*;   // shared types + IfcNotifyEngine

(* synthesize *)
module mkNotifyEngine (IfcNotifyEngine);

    // ---- AXI4 master from a TLM FIFO pair (PrstKvsValBuf idiom) -------------
    FIFO#(NotifyTlmReq_t)  reqF  <- mkLFIFO;
    FIFO#(NotifyTlmResp_t) respF <- mkLFIFO;
    NotifyAxiMasterIfc m <- mkAxi4MasterFromFifoPair(reqF, respF, 4);

    // ---- Config (set_cfg is always_ready: use ConfigReg so a same-cycle host
    //      update never conflicts with the datapath sampling it) -------------
    Reg#(Bit#(64)) baseR     <- mkConfigReg(0);
    Reg#(Bit#(5))  sizeLog2R <- mkConfigReg(0);
    Reg#(Bit#(32)) tailR     <- mkConfigReg(0);

    // ---- Ring write pointer (NIC-owned) ------------------------------------
    Reg#(Bit#(32)) headR <- mkReg(0);

    // ---- Inbound descriptors + a single-cycle drop pulse -------------------
    FIFO#(NotifyDesc) inF <- mkFIFO;
    Wire#(Bool) dropW <- mkDWire(False);

    // One write outstanding at a time: head only advances on the B-response,
    // and the NEXT entry's address depends on the advanced head, so a second
    // write must not be issued before the first completes (otherwise every
    // in-flight entry would target the same stale head*32 address). This
    // serialization is what makes the ring-pointer math correct.
    Reg#(Bool) inflight <- mkReg(False);

    // 2^size_log2 - 1 ; size_log2 capped at 31 so 1<<size_log2 fits Bit#(32).
    function Bit#(32) ringMask ();
        return (32'h1 << sizeLog2R) - 1;
    endfunction

    function Bool isFull ();
        let msk = ringMask();
        return ((headR + 1) & msk) == tailR;
    endfunction

    // Pop one descriptor (only when no write is outstanding): if the ring is
    // full DO NOT write, DO NOT advance head, pulse notify_drop. Otherwise
    // emit exactly one length-1 (b_length=0) WRITE burst of the 32-byte entry
    // to base + head*32 and mark a write in flight.
    rule do_issue (!inflight);
        let desc <- toGet(inF).get;
        if (isFull) begin
            dropW <= True;
        end else begin
            NotifyEntry e = toNotifyEntry(desc);   // correct C/mem layout
            Bit#(64) addr = baseR
                          + (zeroExtend(headR) * fromInteger(notifyEntryBytes));
            NotifyTlmReqDesc_t d = defaultValue;
            d.command        = WRITE;
            d.addr           = addr;
            // 256-bit entry placed in the low half of the 512-bit beat.
            d.data           = zeroExtend(pack(e));
            // wstrb: only the low 32 bytes (256 bits) carry the entry.
            d.byte_enable    = tagged Specify 64'h0000_0000_FFFF_FFFF;
            d.b_size         = BITS512;
            d.b_length       = 0;          // AXI len = beats-1 -> single beat
            d.transaction_id = 0;
            reqF.enq(tagged Descriptor d);
            inflight <= True;
        end
    endrule

    // Drain the write completion (B response). respF only ever carries write
    // completions here (we issue no READs); guard on command anyway, mirroring
    // the split read/write handling in PrstKvsValBuf. HEAD advances ONLY on a
    // successful B-resp; clearing inflight then re-enables do_issue. Give the
    // completion priority over do_issue when both touch `inflight` in one
    // cycle (do_issue's write branch is blocked while inflight anyway, but
    // make the ordering explicit per docs/10-bsv-dataflow-handshaking.md).
    (* descending_urgency = "do_write_cpl, do_issue" *)
    rule do_write_cpl (respF.first.command != READ);
        let resp <- toGet(respF).get;
        headR    <= (headR + 1) & ringMask();
        inflight <= False;
    endrule

    // ---- Interface ---------------------------------------------------------
    interface Put notify_in = toPut(inF);

    method Action set_cfg (NotifyCfg c);
        baseR     <= c.base;
        sizeLog2R <= c.size_log2;
        tailR     <= c.tail;
    endmethod

    method Bit#(32) head    = headR;
    method Bool     ring_full = isFull;

    interface NotifyAxiMasterIfc m_axibr = m;

    method CntPulse cntPulse;
        CntPulse p = defaultValue;
        p.notify_drop = dropW;
        return p;
    endmethod

endmodule : mkNotifyEngine

endpackage : NotifyEngine
