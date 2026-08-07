// =============================================================================
// SimFlowTable — Verilator testbench for mkFlowTable.
//
// mkFlowTable pulls in the CachedCuckoo "BVI" (lib/CachedCuckoo.v + the
// cached_cuckoo SV core), so this DUT cannot run under Bluesim — the Makefile
// `vsim` target builds it through bsc -verilog + Verilator and instantiates
//   mkSimFlowTable dut(.CLK, .RST_N);
//
// The bench drives, via the always_ready enq_cmd port and the lookup_req Put,
// the scenario:
//   (1) upsert K1->V1, then lookup K1            -> Found V1
//   (2) lookup an absent key                     -> Fail
//   (3) delete K1, then lookup K1                -> Fail
//   (4) upsert 64 distinct keys, then look all up-> all Found w/ right value
//   (5) interleave lookups + a few upserts; confirm responses stay in
//       request order
//   (6) overflow: blast > 16 enq_cmd in consecutive cycles before any drain;
//       confirm cmd_full asserts and a dropped cmd pulses cntPulse.tbl_q_drop
//
// Responses are checked by a single expectation FIFO: every lookup we issue
// pushes its expected KvsResp; a response-collector rule pops the DUT
// lookup_resp and compares. A no-progress watchdog $finish(1)s with FAIL if
// the expected response stream stalls (cuckoo lookup latency is ~6+ cycles;
// inserts/cuckoo displacement add more, so the limit is generous).
//
// PASS  -> $display("PASS mkFlowTable") + $finish(0)
// FAIL  -> $display("FAIL ...")        + $finish(1)
// =============================================================================
package SimFlowTable;

import StmtFSM::*;
import FIFO::*;
import FIFOF::*;
import GetPut::*;
import ClientServer::*;
import Cur_Cycle::*;

import FlowReduceDefines::*;
import CachedCuckoo::*;
import KvsDefines::*;
import FlowTable::*;

// Distinct, non-trivial 104-bit keys / 128-bit values built from a small index.
// `int` (Int#(32)) arg so the same helper works for unrolled scalar calls and
// for `for (i <= 0; i < N; ...) seq` register-driven loops.
function Bit#(FlowKey_w) mkKey (int idx);
    Bit#(32) s = pack(idx) + 32'h1;
    return { s ^ 32'hA5A5_0000, s + 32'h1234_5678,
             40'hCAFE_BABE_00 + zeroExtend(s) };
endfunction

function Bit#(FlowVal_w) mkVal (int idx);
    Bit#(32) s = pack(idx) + 32'h1;
    return { s, s ^ 32'hF0F0_F0F0, s + 32'h0BAD_F00D, ~s };
endfunction

(* synthesize *)
module mkSimFlowTable ();

    IfcFlowTable dut <- mkFlowTable;

    // Expected lookup responses, in request order. The collector rule pops the
    // DUT response and checks it against the head of this FIFO.
    FIFOF#(FlowKvsResp) expF   <- mkSizedFIFOF(256);
    Reg#(Bit#(32))      nDone  <- mkReg(0);   // responses checked OK
    Reg#(Bit#(32))      nExp   <- mkReg(0);   // responses expected total
    Reg#(Bool)          failed <- mkReg(False);
    Reg#(Bool)          finishing <- mkReg(False);

    // Overflow-phase observation latches.
    Reg#(Bool) sawCmdFull   <- mkReg(False);
    Reg#(Bool) sawDropPulse <- mkReg(False);

    // No-progress watchdog: reset on every checked response; FAIL if stalled.
    Reg#(Bit#(32)) idle  <- mkReg(0);
    Reg#(Bit#(32)) lastN <- mkReg(0);
    Bit#(32) idleLimit = 200000;   // very generous vs cuckoo latency

    function Action issueLookup (int idx, FlowKvsResp want);
        action
            dut.lookup_req.put(mkKey(idx));
            expF.enq(want);
            nExp <= nExp + 1;
        endaction
    endfunction

    function Action upsert (int idx);
        action
            dut.enq_cmd(TableCmd { is_delete: False,
                                   key: mkKey(idx), val: mkVal(idx) });
        endaction
    endfunction

    function Action delkey (int idx);
        action
            dut.enq_cmd(TableCmd { is_delete: True,
                                   key: mkKey(idx), val: 0 });
        endaction
    endfunction

    // ---- Response collector / checker --------------------------------------
    rule do_collect (!finishing);
        let got <- dut.lookup_resp.get;
        let want = expF.first; expF.deq;
        Bool ok = (got == want);
        $display("[%0d] resp #%0d got=", cur_cycle, nDone,
                 fshow(got), " want=", fshow(want), ok ? " OK" : " MISMATCH");
        if (!ok) begin
            $display("FAIL mkFlowTable: response mismatch (got=", fshow(got),
                     " want=", fshow(want), ")");
            failed <= True;
        end
        nDone <= nDone + 1;
    endrule

    // Watchdog: track lack of progress while a test is running.
    rule do_watchdog (!finishing);
        if (nDone != lastN) begin
            lastN <= nDone;
            idle  <= 0;
        end else begin
            idle <= idle + 1;
            if (idle > idleLimit) begin
                $display("FAIL mkFlowTable: timeout waiting for response ",
                         "(done=%0d expected=%0d)", nDone, nExp);
                $finish(1);
            end
        end
    endrule

    // Overflow observation: sample cmd_full and the drop pulse every cycle.
    (* fire_when_enabled, no_implicit_conditions *)
    rule do_overflow_obs;
        if (dut.cmd_full)            sawCmdFull   <= True;
        if (dut.cntPulse.tbl_q_drop) sawDropPulse <= True;
    endrule

    // ---- Stimulus -----------------------------------------------------------
    // Cuckoo settle margins: an upsert/displacement chain needs many cycles to
    // commit before a dependent lookup will hit; delays are deliberately
    // generous (correctness test, not a throughput test).
    Reg#(int) i <- mkReg(0);

    Stmt test = seq
        $display("====== mkSimFlowTable start ======");

        // ---- (1) upsert K1 -> V1, lookup K1 -> Found V1 -------------------
        upsert(1);
        delay(400);
        issueLookup(1, tagged Found mkVal(1));
        delay(300);

        // ---- (2) lookup an absent key -> Fail ----------------------------
        issueLookup(9999, tagged Fail);
        delay(300);

        // ---- (3) delete K1, lookup K1 -> Fail ----------------------------
        delkey(1);
        delay(400);
        issueLookup(1, tagged Fail);
        delay(300);

        // ---- (4) upsert 64 distinct keys, then look all up ---------------
        for (i <= 100; i < 164; i <= i + 1) seq
            upsert(i);
            delay(80);          // queue drains a cmd well within 80 cycles
        endseq
        delay(3000);            // let the last cuckoo insert settle
        for (i <= 100; i < 164; i <= i + 1) seq
            issueLookup(i, tagged Found mkVal(i));
            delay(40);
        endseq
        delay(4000);            // drain all 64 lookup responses

        // ---- (5) interleave lookups and a few upserts; in-order check ----
        upsert(500);
        delay(300);
        upsert(501);
        delay(300);
        issueLookup(500, tagged Found mkVal(500));
        upsert(502);
        delay(60);
        issueLookup(501, tagged Found mkVal(501));
        delay(500);
        issueLookup(502, tagged Found mkVal(502));
        issueLookup(7777, tagged Fail);
        delay(2500);

        // ---- (6) overflow: blast > 16 enq_cmd in back-to-back cycles ------
        // The depth-16 cmdF cannot drain a command every cycle (each command
        // is a multi-cycle cuckoo update), so a 40-deep back-to-back burst
        // must fill the FIFO, assert cmd_full, and drop >=1 command (pulsing
        // cntPulse.tbl_q_drop). do_overflow_obs latches both observations.
        for (i <= 0; i < 40; i <= i + 1)
            dut.enq_cmd(TableCmd { is_delete: False,
                                   key: mkKey(900 + i),
                                   val: mkVal(900 + i) });

        action
            if (!sawCmdFull)
                $display("FAIL mkFlowTable: cmd_full never asserted during ",
                         "40-cmd back-to-back burst");
            if (!sawDropPulse)
                $display("FAIL mkFlowTable: cntPulse.tbl_q_drop never pulsed ",
                         "on cmd-FIFO overflow");
            if (!sawCmdFull || !sawDropPulse)
                failed <= True;
        endaction
        delay(50);

        // ---- Final verdict ----------------------------------------------
        finishing <= True;
        delay(5);
        action
            if (failed) begin
                $display("FAIL mkFlowTable");
                $finish(1);
            end else if (nDone != nExp) begin
                $display("FAIL mkFlowTable: only %0d/%0d responses checked",
                         nDone, nExp);
                $finish(1);
            end else begin
                $display("PASS mkFlowTable");
                $display("  (%0d lookup responses verified; overflow: ",
                         nDone, "cmd_full=%0d drop_pulse=%0d)",
                         sawCmdFull, sawDropPulse);
                $finish(0);
            end
        endaction
    endseq;

    mkAutoFSM(test);

endmodule : mkSimFlowTable

endpackage : SimFlowTable
