// =============================================================================
// SimNotifyEngine — Bluesim testbench for mkNotifyEngine (spec §8).
//
// Topology:
//   mkNotifyEngine.m_axibr  --mkConnection-->  Axi4RdWrSlave (mkAxi4Slave-
//   FromFifoPair over reqF/respF). A tiny TLM slave rule captures every
//   single-beat WRITE (descriptor with b_length==0) into a model ring memory
//   (one NotifyEntry per slot, indexed by (addr-base)/32) and returns a
//   SUCCESS B response — exactly the single-beat write path of
//   kvs_cuckoo/src/PseudoAxi4Dram.bsv (nbeat==0 -> immediate completion).
//
// Tests (test plan §3.8 / §6):
//   1. Single miss: one notify_in -> exactly one 32-byte write at base+0,
//      head advances 0->1, captured bytes decode to the NotifyDesc fields in
//      correct C order (src_ip @ byte0..3, dst_ip @ 4..7, ...).
//   2. Ring fill + full: size_log2=3 (8 entries). Write 7 entries (head
//      0..7), ring becomes full when ((head+1)&7)==tail; the 8th notify_in is
//      dropped — cntPulse.notify_drop pulses, head unchanged, NO new write.
//   3. Recovery: advance tail via set_cfg so the ring is no longer full; the
//      next notify_in succeeds (write lands, head advances).
//
// $display PASS/FAIL, $finish(0) on success / $finish(1) on any failure or
// the global cycle-timeout.
// =============================================================================
package SimNotifyEngine;

import FIFO::*;
import GetPut::*;
import Connectable::*;
import DefaultValue::*;
import Vector::*;
import Cur_Cycle::*;

import FlowReduceDefines::*;
import NotifyEngine::*;

// ---- Test vectors ----------------------------------------------------------
function NotifyDesc mkDesc (Integer i);
    return NotifyDesc {
        src_ip:           fromInteger('hC0A80000 + i),   // 192.168.0.i
        dst_ip:           fromInteger('h0A000000 + i),   // 10.0.0.i
        src_port:         fromInteger('h1000 + i),
        dst_port:         fromInteger('h2000 + i),
        proto:            17,
        timestamp_cycles: fromInteger('hDEAD0000 + i)
    };
endfunction

(* synthesize *)
module mkSimNotifyEngine (Empty);

    IfcNotifyEngine dut <- mkNotifyEngine;

    // Precomputed descriptor table (mkDesc needs a compile-time Integer);
    // index it at runtime with a Bit counter. desc[i] uses seed i.
    Vector#(16, NotifyDesc) desc = newVector;
    for (Integer i = 0; i < 16; i = i + 1) desc[i] = mkDesc(i);

    // ---- Model host ring memory + a captured-write TLM slave --------------
    FIFO#(NotifyTlmReq_t)  slvReqF  <- mkLFIFO;   // master -> slave (AW/W)
    FIFO#(NotifyTlmResp_t) slvRespF <- mkLFIFO;   // slave  -> master (B)
    Axi4RdWrSlave#(4,64,512,8,0) slv <- mkAxi4SlaveFromFifoPair(slvReqF, slvRespF);
    mkConnection(dut.m_axibr, slv);

    Bit#(64) ringBase = 64'h1000;

    // 8-slot model ring (size_log2 = 3). Each slot holds the decoded entry +
    // a written flag + the absolute address it was written at.
    Vector#(8, Reg#(NotifyEntry)) memEnt  <- replicateM(mkRegU);
    Vector#(8, Reg#(Bit#(64)))    memAddr <- replicateM(mkRegU);
    Vector#(8, Reg#(Bool))        memWr   <- replicateM(mkReg(False));
    Reg#(Bit#(32)) writeCnt <- mkReg(0);

    // Single-beat WRITE capture: descriptor carries the data (b_length==0),
    // decode the entry from the low 256 bits, slot = (addr-base)/32, then
    // return a SUCCESS B-resp (mirrors PseudoAxi4Dram nbeat==0 path).
    rule slv_capture_write;
        let req <- toGet(slvReqF).get;
        if (req matches tagged Descriptor .desc &&& desc.command == WRITE) begin
            Bit#(64) off  = desc.addr - ringBase;
            Bit#(3)  slot = truncate(off >> 5);          // /32
            NotifyEntry e = unpack(truncate(desc.data)); // low 256b
            memEnt[slot]  <= e;
            memAddr[slot] <= desc.addr;
            memWr[slot]   <= True;
            writeCnt      <= writeCnt + 1;
            $display("[%5d][Slave] WR slot=%0d addr=%0h src_ip=%0h dst_ip=%0h sp=%0h dp=%0h proto=%0d ts=%0h",
                cur_cycle(), slot, desc.addr, e.src_ip, e.dst_ip, e.src_port,
                e.dst_port, e.proto, e.timestamp_cycles);
            slvRespF.enq(TLMResponse {
                command: WRITE, data: ?, status: SUCCESS, user: 0,
                prty: 0, transaction_id: desc.transaction_id, is_last: True });
        end else begin
            $display("[%5d][Slave] ERROR unexpected non-WRITE-descriptor request",
                cur_cycle());
            slvRespF.enq(TLMResponse {
                command: WRITE, data: ?, status: ERROR, user: 0,
                prty: 0, transaction_id: 0, is_last: True });
        end
    endrule

    // ---- Drop-pulse observation -------------------------------------------
    // cntPulse.notify_drop is a 1-cycle DWire; latch every assertion so the
    // checker can read a cumulative count regardless of sampling cycle.
    Reg#(Bit#(32)) dropCnt <- mkReg(0);
    (* fire_when_enabled, no_implicit_conditions *)
    rule sample_drop;
        if (dut.cntPulse.notify_drop) dropCnt <= dropCnt + 1;
    endrule

    // ---- Test sequencer ----------------------------------------------------
    // Cycle stamps come from Cur_Cycle.cur_cycle() (a shared value method, no
    // user rule -> no scheduling conflict with the phase FSM). The timeout
    // counter is written ONLY by its own rule and read by no phase rule.
    Reg#(UInt#(8)) phase <- mkReg(0);
    Reg#(Bit#(32)) tmr   <- mkReg(0);   // generic settle timer
    Reg#(Bit#(32)) tocnt <- mkReg(0);   // independent timeout counter

    rule do_timeout;
        tocnt <= tocnt + 1;
        if (tocnt > 5000) begin
            $display("FAIL: global timeout at cycle %0d (phase %0d)",
                cur_cycle(), phase);
            $finish(1);
        end
    endrule

    function Action fail (String msg);
        return action
            $display("FAIL [phase %0d, cyc %0d]: %s", phase, cur_cycle(), msg);
            $finish(1);
        endaction;
    endfunction

    // Expected number of writes recorded so far at each checkpoint.
    // Phase map:
    //   0  cfg base/size=3/tail=0
    //   1  send desc #1
    //   2  wait for write #1, check slot 0
    //   3  send descs #2..#7 (6 more) -> head should reach 7, ring full
    //   4  wait for 7 total writes, verify full + head
    //   5  send desc #8 -> must be dropped (no write, head stays 7)
    //   6  verify drop, no 8th write
    //   7  advance tail (set_cfg base/size/tail=4) so ring not full
    //   8  send desc #9 -> must succeed (write #8)
    //   9  wait, verify recovery; PASS

    rule p0_cfg (phase == 0);
        // base=0x1000, size_log2=3 (8 entries), tail=0.
        dut.set_cfg(NotifyCfg { base: ringBase, size_log2: 3, tail: 0 });
        $display("[%5d] cfg base=%0h size_log2=3 tail=0", cur_cycle(), ringBase);
        tmr <= 0;
        phase <= 1;
    endrule

    rule p1_settle_cfg (phase == 1);
        // give set_cfg a cycle to land, then check initial head / not full.
        if (tmr < 2) tmr <= tmr + 1;
        else begin
            if (dut.head != 0) fail("initial head != 0");
            if (dut.ring_full) fail("ring reported full with tail==0,head==0,size8 (only 1 slot used)");
            dut.notify_in.put(desc[1]);
            $display("[%5d] sent notify #1", cur_cycle());
            phase <= 2;
        end
    endrule

    // Wait for the write to be captured AND the B-response round-trip to
    // advance head (head==1). The AXI transactor adds latency between W and
    // B, so poll for head rather than checking on a fixed delay.
    rule p2_wait_w1 (phase == 2);
        if (writeCnt >= 1 && dut.head == 1) begin
            if (writeCnt != 1) fail("more than one write for a single notify");
            if (!memWr[0])     fail("slot 0 not written");
            if (memAddr[0] != ringBase) fail("write addr != base+0");
            let e  = memEnt[0];
            let ex = toNotifyEntry(desc[1]);
            if (e.src_ip    != ex.src_ip)    fail("src_ip mismatch (byte0..3)");
            if (e.dst_ip    != ex.dst_ip)    fail("dst_ip mismatch (byte4..7)");
            if (e.src_port  != ex.src_port)  fail("src_port mismatch (byte8..9)");
            if (e.dst_port  != ex.dst_port)  fail("dst_port mismatch (byte10..11)");
            if (e.proto     != ex.proto)     fail("proto mismatch (byte12)");
            if (e.timestamp_cycles != ex.timestamp_cycles) fail("timestamp mismatch (byte16..23)");
            if (e.rsv != 0 || e.rsv2 != 0)   fail("reserved bytes not zero");
            $display("[%5d] PASS test1: single write @base, fields C-ordered, head=1", cur_cycle());
            tmr <= 0;
            phase <= 3;
        end
    endrule

    // Send descs #2..#7 one per cycle (FIFO + backpressure handle pacing).
    Reg#(Bit#(8)) sendIdx <- mkReg(2);
    rule p3_fill (phase == 3);
        if (sendIdx <= 7) begin
            dut.notify_in.put(desc[sendIdx]);
            $display("[%5d] sent notify #%0d", cur_cycle(), sendIdx);
            sendIdx <= sendIdx + 1;
        end else begin
            phase <= 4;
            tmr <= 0;
        end
    endrule

    // 7 writes total -> slots 0..6 written, head should reach 7 once all
    // B-responses have come back. With tail=0,size=8: ((7+1)&7)==0==tail =>
    // ring_full. Poll head==7 rather than guessing a settle delay.
    rule p4_wait_full (phase == 4);
        if (writeCnt >= 7 && dut.head == 7) begin
            if (writeCnt != 7) fail("expected exactly 7 writes after fill");
            Bool allwr = True;
            for (Integer s = 0; s < 7; s = s + 1)
                if (!memWr[s]) allwr = False;
            if (!allwr) fail("not all slots 0..6 written");
            if (!dut.ring_full) fail("ring not full at head=7,tail=0,size=8");
            $display("[%5d] PASS test2a: 7 writes, head=7, ring_full asserted", cur_cycle());
            phase <= 5;
            tmr <= 0;
        end
    endrule

    Reg#(Bit#(32)) dropCntSnap <- mkReg(0);
    Reg#(Bit#(32)) wrSnap      <- mkReg(0);
    rule p5_send_overflow (phase == 5);
        dropCntSnap <= dropCnt;
        wrSnap      <= writeCnt;
        dut.notify_in.put(desc[8]);
        $display("[%5d] sent notify #8 (ring full -> expect drop)", cur_cycle());
        phase <= 6;
        tmr <= 0;
    endrule

    rule p6_check_drop (phase == 6);
        if (tmr < 8) tmr <= tmr + 1;
        else begin
            if (dropCnt != dropCntSnap + 1) fail("notify_drop did not pulse exactly once on full");
            if (writeCnt != wrSnap)         fail("a write occurred while ring full");
            if (dut.head != 7)              fail("head advanced while ring full");
            if (!dut.ring_full)             fail("ring no longer full unexpectedly");
            $display("[%5d] PASS test2b: overflow dropped (drop pulsed, no write, head=7)", cur_cycle());
            phase <= 7;
            tmr <= 0;
        end
    endrule

    rule p7_advance_tail (phase == 7);
        // Move tail forward (host consumed entries): tail=4. Now
        // ((head+1)&7)=( (7+1)&7 )=0 != 4 => not full.
        dut.set_cfg(NotifyCfg { base: ringBase, size_log2: 3, tail: 4 });
        $display("[%5d] advanced tail=4 (recovery)", cur_cycle());
        tmr <= 0;
        phase <= 8;
    endrule

    rule p8_send_recover (phase == 8);
        if (tmr < 3) tmr <= tmr + 1;
        else begin
            if (dut.ring_full) fail("ring still full after tail advanced");
            wrSnap <= writeCnt;
            dut.notify_in.put(desc[9]);
            $display("[%5d] sent notify #9 (expect success after recovery)", cur_cycle());
            phase <= 9;
            tmr <= 0;
        end
    endrule

    // head was 7; recovery write wraps it: (7+1)&7 = 0. Poll head==0 after
    // the write count bumped (B-resp returned).
    rule p9_check_recover (phase == 9);
        if (writeCnt >= wrSnap + 1 && dut.head == 0) begin
            // slot 7 written at base+7*32.
            if (!memWr[7]) fail("recovery write did not land in slot 7");
            if (memAddr[7] != ringBase + 7*32) fail("recovery write addr wrong");
            let e  = memEnt[7];
            let ex = toNotifyEntry(desc[9]);
            if (e.src_ip != ex.src_ip || e.timestamp_cycles != ex.timestamp_cycles)
                fail("recovery entry payload mismatch");
            $display("[%5d] PASS test3: recovery write succeeded, head wrapped to 0", cur_cycle());
            phase <= 10;
        end
    endrule

    rule p10_done (phase == 10);
        $display("==============================================");
        $display("PASS: all NotifyEngine tests passed (cyc %0d)", cur_cycle());
        $display("==============================================");
        $finish(0);
    endrule

endmodule : mkSimNotifyEngine

endpackage : SimNotifyEngine
