// =============================================================================
// SimHBMReadEngine — Bluesim self-checking testbench for mkHBMReadEngine.
//
//   make bsim PKG=SimHBMReadEngine MOD=mkSimHBMReadEngine
//
// Builds a minimal inline AXI4 TLM slave responder per channel, connected to
// the DUT's hbm_axi[i] master via mkAxi4SlaveFromFifoPair (Axi4Utilities). The
// responder mirrors the burst-read contract proven by PseudoAxi4Dram.bsv: one
// READ Descriptor in (b_length = beats-1), b_length+1 separate TLMResponse
// beats out, is_last on the final beat. Each beat carries deterministic data
//   data = { marker, ..., beatIdx, addr32 } so the checker can verify both
// ordering and which burst a beat belongs to. A per-channel "poison" address
// makes exactly one chosen beat of the matching burst return a non-SUCCESS
// status (RRESP != OKAY), exercising spec §5.3 error stickiness without
// disturbing the 8-beat data stream.
//
// Checking model: the FSM enqueues exactly ONE per-burst descriptor
// {addr, burstErr} per channel (one FIFO enq/burst — no parallel conflict).
// Each per-channel data checker keeps its own beat index 0..7, regenerates
// the expected beat, and on the 8th beat pops the burst descriptor and pushes
// its expected burstErr onto an err-expect FIFO consumed by the err checker.
//
// Tests:
//  (1) one cmd on ch0  -> 8 data beats (last on 8th) + one err=False
//  (2) 32 back-to-back cmds on ch2 -> 32*8 beats, 32 err=False, in order
//  (3) all three channels concurrently, one burst each -> independent streams
//  (4) ch4 burst whose 5th beat returns non-OKAY -> 8 beats + err=True, and a
//      following clean ch4 burst -> err=False (stickiness resets per burst)
//
// $display PASS/FAIL with $finish(0/1) and a cycle-timeout guard.
// =============================================================================
package SimHBMReadEngine;

import FIFO::*;
import GetPut::*;
import Vector::*;
import StmtFSM::*;
import Connectable::*;
import Cur_Cycle::*;

import FlowReduceDefines::*;
import HBMReadEngine::*;

Integer beatsPerBurst = 8;

// Encode an expected/produced data beat: low 32b = req addr[31:0], next byte =
// beat index within the burst. Lets the checker bind a beat to its burst.
function Bit#(512) mkRespData (Bit#(33) addr, UInt#(4) bidx);
    Bit#(512) d = 0;
    d[31:0]    = addr[31:0];
    d[39:32]   = zeroExtend(pack(bidx));
    d[511:480] = 32'hABCD1234;         // marker so all-zero data can't pass
    return d;
endfunction

// -----------------------------------------------------------------------------
// Minimal inline TLM slave responder. Accepts one READ burst Descriptor, emits
// b_length+1 data beats. If the request addr equals `poisonAddr` (and that is
// not 0 == "disabled"), beat index `poisonBeat` returns status != SUCCESS.
// -----------------------------------------------------------------------------
interface IfcSimSlave;
    interface HbmAxiSlaveIfc axi;
    method Action set_poison (Bit#(33) a, UInt#(4) b);
endinterface

module mkSimSlave (IfcSimSlave);
    FIFO#(HbmTlmReq_t)  sreqF  <- mkLFIFO;
    FIFO#(HbmTlmResp_t) srespF <- mkLFIFO;
    HbmAxiSlaveIfc      s      <- mkAxi4SlaveFromFifoPair(sreqF, srespF);

    Reg#(Bool)     busy    <- mkReg(False);
    Reg#(UInt#(4)) bcnt    <- mkReg(0);     // beats remaining-1 .. 0
    Reg#(UInt#(4)) bidx    <- mkReg(0);     // current beat index 0..7
    Reg#(Bit#(33)) raddr   <- mkRegU;
    Reg#(Bit#(6))  rid     <- mkRegU;

    Reg#(Bit#(33)) poisonA <- mkReg(0);     // 0 == disabled
    Reg#(UInt#(4)) poisonB <- mkReg(0);

    rule do_accept (!busy);
        let req <- toGet(sreqF).get;
        if (req matches tagged Descriptor .desc) begin
            // Only READ bursts are expected from the DUT.
            if (desc.command == READ) begin
                busy  <= True;
                bcnt  <= truncate(desc.b_length);   // = 7 for an 8-beat burst
                bidx  <= 0;
                raddr <= desc.addr;
                rid   <= desc.transaction_id;
            end
        end
    endrule

    rule do_respond (busy);
        Bool isLast  = (bcnt == 0);
        Bool poison  = (poisonA != 0) && (raddr == poisonA) && (bidx == poisonB);
        HbmTlmResp_t r = defaultValue;
        r.command        = READ;
        r.data           = mkRespData(raddr, bidx);
        r.status         = poison ? ERROR : SUCCESS;
        r.transaction_id = rid;
        r.is_last        = isLast;
        srespF.enq(r);
        if (isLast) busy <= False;
        else        bcnt <= bcnt - 1;
        bidx <= bidx + 1;
    endrule

    interface HbmAxiSlaveIfc axi = s;
    method Action set_poison (Bit#(33) a, UInt#(4) b);
        poisonA <= a; poisonB <= b;
    endmethod
endmodule

(* synthesize *)
module mkSimHBMReadEngine ();

    IfcHBMReadEngine dut <- mkHBMReadEngine;
    Vector#(3, IfcSimSlave) slv <- replicateM(mkSimSlave);

    // Wire each DUT HBM master to its slave responder.
    for (Integer i = 0; i < 3; i = i + 1)
        mkConnection(dut.hbm_axi[i], slv[i].axi);

    // Per-channel burst-descriptor queues: one entry per issued burst,
    // {addr, burstErr}. One enq/burst -> no parallel-method conflict.
    FIFO#(Tuple2#(Bit#(33), Bool)) bq0 <- mkSizedFIFO(64);
    FIFO#(Tuple2#(Bit#(33), Bool)) bq2 <- mkSizedFIFO(64);
    FIFO#(Tuple2#(Bit#(33), Bool)) bq4 <- mkSizedFIFO(64);

    // Err-expectation queues, fed by the data checker at each burst boundary.
    FIFO#(Bool) eq0 <- mkSizedFIFO(64);
    FIFO#(Bool) eq2 <- mkSizedFIFO(64);
    FIFO#(Bool) eq4 <- mkSizedFIFO(64);

    // Per-channel running beat index within the current burst (0..7).
    Reg#(UInt#(4)) bi0 <- mkReg(0);
    Reg#(UInt#(4)) bi2 <- mkReg(0);
    Reg#(UInt#(4)) bi4 <- mkReg(0);

    Reg#(Bit#(32)) chk0 <- mkReg(0);   // data beats checked
    Reg#(Bit#(32)) chk2 <- mkReg(0);
    Reg#(Bit#(32)) chk4 <- mkReg(0);
    Reg#(Bit#(32)) ec0  <- mkReg(0);   // err tokens checked
    Reg#(Bit#(32)) ec2  <- mkReg(0);
    Reg#(Bit#(32)) ec4  <- mkReg(0);

    Reg#(Bit#(32)) totBurst <- mkReg(0);   // total bursts issued (all channels)
    Reg#(Bool)     done     <- mkReg(False);

    Reg#(Bit#(33)) i <- mkReg(0);          // Test-2 loop index

    function Bit#(32) totData    = chk0 + chk2 + chk4;
    function Bit#(32) totErrChk  = ec0  + ec2  + ec4;

    // Issue a burst on a channel: record its descriptor (one enq), bump count.
    function Action issueBurst (FIFO#(Tuple2#(Bit#(33), Bool)) q,
                                function Action putcmd (Bit#(33) a),
                                Bit#(33) addr, Bool burstErr);
        action
            q.enq(tuple2(addr, burstErr));
            putcmd(addr);
            totBurst <= totBurst + 1;
        endaction
    endfunction

    // ---- generic per-channel data checker body --------------------------
    function Action checkData (String tag,
                               NfBeat b,
                               Reg#(UInt#(4)) biR,
                               Reg#(Bit#(32)) chkR,
                               FIFO#(Tuple2#(Bit#(33), Bool)) bq,
                               FIFO#(Bool) eq);
        action
            match {.a, .be} = bq.first;
            Bool isLast = (biR == fromInteger(beatsPerBurst - 1));
            // For a clean burst every beat's data must match exactly. For an
            // errored burst the AXI master transactor substitutes a
            // TLMErrorCode payload on the SLVERR beat, and spec §5.3 makes the
            // whole burst's data don't-care (it is drained downstream); so we
            // only assert the 8-beat shape (count + last + keep), not content.
            Bit#(512) want = mkRespData(a, biR);
            if (!be && b.data != want) begin
                $display("FAIL %s data mismatch beat %0d: got %032h want %032h",
                         tag, chkR, b.data, want); $finish(1);
            end
            if (b.last != isLast) begin
                $display("FAIL %s last mismatch beat %0d: got %0d want %0d",
                         tag, chkR, b.last, isLast); $finish(1);
            end
            if (b.keep != '1) begin
                $display("FAIL %s keep not all-ones beat %0d", tag, chkR);
                $finish(1);
            end
            chkR <= chkR + 1;
            if (isLast) begin
                bq.deq;          // burst fully consumed
                eq.enq(be);      // hand expected err token to the err checker
                biR <= 0;
            end else
                biR <= biR + 1;
        endaction
    endfunction

    rule chk_data0;
        let b <- dut.data_ch0.get;
        checkData("ch0", b, bi0, chk0, bq0, eq0);
    endrule
    rule chk_data2;
        let b <- dut.data_ch2.get;
        checkData("ch2", b, bi2, chk2, bq2, eq2);
    endrule
    rule chk_data4;
        let b <- dut.data_ch4.get;
        checkData("ch4", b, bi4, chk4, bq4, eq4);
    endrule

    // ---- per-channel err-token checkers ---------------------------------
    function Action checkErr (String tag, Bool e,
                              FIFO#(Bool) eq, Reg#(Bit#(32)) ecR);
        action
            let want = eq.first; eq.deq;
            if (e != want) begin
                $display("FAIL %s err token %0d: got %0d want %0d",
                         tag, ecR, e, want); $finish(1);
            end
            ecR <= ecR + 1;
        endaction
    endfunction

    rule chk_err0;
        let e <- dut.err_ch0.get;
        checkErr("ch0", e, eq0, ec0);
    endrule
    rule chk_err2;
        let e <- dut.err_ch2.get;
        checkErr("ch2", e, eq2, ec2);
    endrule
    rule chk_err4;
        let e <- dut.err_ch4.get;
        checkErr("ch4", e, eq4, ec4);
    endrule

    // Finish when every issued burst has been fully checked (8 data beats +
    // 1 err token each) across all three channels.
    rule finish_when_done (done && totBurst != 0
            && totData    == totBurst * fromInteger(beatsPerBurst)
            && totErrChk  == totBurst);
        $display("PASS mkHBMReadEngine: %0d bursts, %0d data beats, %0d err tokens (ch0=%0d ch2=%0d ch4=%0d)",
                 totBurst, totData, totErrChk, chk0, chk2, chk4);
        $finish(0);
    endrule

    // 512 B-aligned addresses (spec §4.2). Distinct per test/channel.
    Bit#(33) a_t1   = 33'h0000_1000;
    Bit#(33) a_t2b  = 33'h0010_0000;   // base for the 32 back-to-back ch2 bursts
    Bit#(33) a_c0   = 33'h0002_0000;
    Bit#(33) a_c2   = 33'h0002_0200;
    Bit#(33) a_c4   = 33'h0002_0400;
    Bit#(33) a_p    = 33'h0008_0000;   // poisoned ch4 burst
    Bit#(33) a_pc   = 33'h0008_0200;   // clean ch4 burst right after

    Stmt prog =
    seq
        // ---- Test 1: one cmd on ch0 -> 8 beats + err=False ----
        issueBurst(bq0, dut.cmd_ch0.put, a_t1, False);
        while (chk0 != 8 || ec0 != 1) delay(1);
        $display("[%0d] Test1 ok: ch0 single burst (8 beats, err=False)",
                 cur_cycle());

        // ---- Test 2: 32 back-to-back cmds on ch2 ----
        for (i <= 0; i < 32; i <= i + 1)
            issueBurst(bq2, dut.cmd_ch2.put, a_t2b + (i << 9), False);
        while (chk2 != 32 * 8 || ec2 != 32) delay(1);
        $display("[%0d] Test2 ok: ch2 32 back-to-back bursts, in order",
                 cur_cycle());

        // ---- Test 3: all three channels concurrently, one burst each ----
        par
            issueBurst(bq0, dut.cmd_ch0.put, a_c0, False);
            issueBurst(bq2, dut.cmd_ch2.put, a_c2, False);
            issueBurst(bq4, dut.cmd_ch4.put, a_c4, False);
        endpar
        while (chk0 != 2 * 8 || chk2 != 33 * 8 || chk4 != 1 * 8) delay(1);
        $display("[%0d] Test3 ok: 3 concurrent independent streams",
                 cur_cycle());

        // ---- Test 4: poisoned ch4 burst (beat 4 -> RRESP!=OKAY) ----
        slv[2].set_poison(a_p, 4);
        issueBurst(bq4, dut.cmd_ch4.put, a_p, True);     // err token must be True
        while (chk4 != 2 * 8 || ec4 != 2) delay(1);
        // a following clean ch4 burst: stickiness must have reset
        slv[2].set_poison(0, 0);
        issueBurst(bq4, dut.cmd_ch4.put, a_pc, False);
        while (chk4 != 3 * 8 || ec4 != 3) delay(1);
        $display("[%0d] Test4 ok: ch4 error stickiness True then reset to False",
                 cur_cycle());

        action done <= True; endaction
        // finish_when_done fires $finish(0). Timeout guard otherwise.
        delay(20000);
        action
            $display("FAIL timeout: data %0d/%0d err %0d/%0d",
                     totData, totBurst * fromInteger(beatsPerBurst),
                     totErrChk, totBurst);
            $finish(1);
        endaction
    endseq;

    mkAutoFSM(prog);

endmodule : mkSimHBMReadEngine

endpackage : SimHBMReadEngine
