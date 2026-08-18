// =============================================================================
// SimLookupDispatcher — Bluesim self-checking testbench for mkLookupDispatcher.
//
// Drives the four Put inputs (hdr_in, payload_in, lookup_resp_in, key_echo_in)
// in packet order and drains every Get (hdr_post, payload_post, flowident_post,
// hbm_cmd0/2/4, notify_out). cntPulse.hit/.miss are latched into cumulative
// counters by a free-running sampler rule.
//
// Feed model: each fed packet has a 32-bit pktid. The header beat carries a
// tag {0xH, pktid} in data; the 8 payload beats carry {beatIdx, pktid} with
// last on the 8th. For a HIT we feed a FlowKvsResp = tagged Found with a
// distinct FlowVal {flow_ident, off_ch0, off_ch2, off_ch4} all derived from
// pktid; for a MISS we feed tagged Fail and a distinct FlowKey 5-tuple.
//
// Expected-value queues (sized large so the feed side never gates — DUT
// backpressure stays real):
//   hdrQ  : {expHdrData}            one / hit, in order
//   fidQ  : {expFlowIdent}          one / hit, in order
//   c0/2/4Q: expected 33-bit HBM addr  one / hit / channel, in order
//   plQ   : {expData, expLast}      8 / hit, in order
//   ntQ   : expected NotifyDesc (sans timestamp) one / miss, in order
//
// Cases (test plan §3.3):
//   1. 100 all-hit packets.
//   2. 100 all-miss packets (a following hit still works -> DROP_PL drained
//      exactly 8).
//   3. interleaved hit/miss (alternating).
//   4. payload_post drain stalled then resumed (backpressure) — no loss /
//      misalignment.
//
//   make bsim PKG=SimLookupDispatcher MOD=mkSimLookupDispatcher
// =============================================================================
package SimLookupDispatcher;

import FIFO::*;
import FIFOF::*;
import GetPut::*;
import Vector::*;
import DefaultValue::*;
import StmtFSM::*;
import Cur_Cycle::*;

import FlowReduceDefines::*;
import LookupDispatcher::*;

Integer beatsPerPkt = 8;

// ---- Deterministic per-packet stimulus derivations -------------------------
function Bit#(512) hdrData (Bit#(32) pktid);
    // distinctive header pattern: 0xH nibble marker + pktid replicated.
    Bit#(512) d = 0;
    for (Integer w = 0; w < 16; w = w + 1)
        d[w*32+31 : w*32] = pktid ^ (32'hA5A5_0000 | fromInteger(w));
    return d;
endfunction

function Bit#(512) plData (Bit#(32) pktid, Bit#(32) bi);
    Bit#(512) d = 0;
    for (Integer w = 0; w < 16; w = w + 1)
        d[w*32+31 : w*32] = (pktid << 8) ^ (bi << 4) ^ fromInteger(w);
    return d;
endfunction

function Bit#(32) fidOf  (Bit#(32) pktid) = 32'hF100_0000 | pktid;
function Bit#(32) ch0Of  (Bit#(32) pktid) = 32'h0000_0200 + (pktid << 9); // 512B aligned
function Bit#(32) ch2Of  (Bit#(32) pktid) = 32'h0001_0000 + (pktid << 9);
function Bit#(32) ch4Of  (Bit#(32) pktid) = 32'h0002_0000 + (pktid << 9);

function FlowVal valOf (Bit#(32) pktid);
    return FlowVal { flow_ident: fidOf(pktid), off_ch0: ch0Of(pktid),
                     off_ch2: ch2Of(pktid),    off_ch4: ch4Of(pktid) };
endfunction

function FlowKey keyOf (Bit#(32) pktid);
    return FlowKey { src_ip:   32'hC0A8_0000 | pktid,
                     dst_ip:   32'h0A00_0000 | pktid,
                     src_port: 16'h1000 + truncate(pktid),
                     dst_port: 16'h2000 + truncate(pktid),
                     proto:    17 };
endfunction

(* synthesize *)
module mkSimLookupDispatcher ();

    IfcLookupDispatcher dut <- mkLookupDispatcher;

    // ---- Expected-value queues (oversized: feed never gates) --------------
    FIFOF#(Bit#(512))                  hdrQ <- mkSizedFIFOF(1024);
    FIFOF#(Bit#(32))                   fidQ <- mkSizedFIFOF(1024);
    FIFOF#(Bit#(33))                   c0Q  <- mkSizedFIFOF(1024);
    FIFOF#(Bit#(33))                   c2Q  <- mkSizedFIFOF(1024);
    FIFOF#(Bit#(33))                   c4Q  <- mkSizedFIFOF(1024);
    FIFOF#(Tuple2#(Bit#(512), Bool))   plQ  <- mkSizedFIFOF(4096);
    FIFOF#(FlowKey)                    ntQ  <- mkSizedFIFOF(1024);

    // ---- Observed counters -------------------------------------------------
    Reg#(Bit#(32)) hitCnt  <- mkReg(0);   // cntPulse.hit observed
    Reg#(Bit#(32)) missCnt <- mkReg(0);   // cntPulse.miss observed
    Reg#(Bit#(32)) hdrChk  <- mkReg(0);
    Reg#(Bit#(32)) fidChk  <- mkReg(0);
    Reg#(Bit#(32)) plChk   <- mkReg(0);
    Reg#(Bit#(32)) c0Chk   <- mkReg(0);
    Reg#(Bit#(32)) c2Chk   <- mkReg(0);
    Reg#(Bit#(32)) c4Chk   <- mkReg(0);
    Reg#(Bit#(32)) ntChk   <- mkReg(0);

    // Expected totals (set by the stimulus FSM as it feeds).
    Reg#(Bit#(32)) expHit  <- mkReg(0);   // hit packets fed
    Reg#(Bit#(32)) expMiss <- mkReg(0);   // miss packets fed
    Reg#(Bool)     allFed  <- mkReg(False);

    // Last observed notify timestamp, to assert non-decreasing monotonicity.
    Reg#(Bit#(64)) lastTs  <- mkReg(0);
    Reg#(Bool)     haveTs  <- mkReg(False);

    // payload_post drain gate (backpressure case). Sole writer = countdown.
    Reg#(Bit#(16))   plStall  <- mkReg(0);
    RWire#(Bit#(16)) stallReq  <- mkRWire;

    function Action fail (String msg);
        return action
            $display("FAIL [cyc %0d]: %s", cur_cycle(), msg);
            $finish(1);
        endaction;
    endfunction

    // ---- cntPulse sampler (free-running) ----------------------------------
    (* fire_when_enabled, no_implicit_conditions *)
    rule sample_pulses;
        let p = dut.cntPulse;
        if (p.hit)  hitCnt  <= hitCnt  + 1;
        if (p.miss) missCnt <= missCnt + 1;
    endrule

    // ---- Stimulus helpers --------------------------------------------------
    // Feed one HIT packet (header + 8 payload + Found resp + key) and record
    // all expected outputs.
    function Action feedHit (Bit#(32) pktid);
        action
            FlowVal fv = valOf(pktid);
            dut.hdr_in.put(NfBeat { data: hdrData(pktid), keep: '1, last: True });
            dut.lookup_resp_in.put(tagged Found pack(fv));
            dut.key_echo_in.put(keyOf(pktid));
            hdrQ.enq(hdrData(pktid));
            fidQ.enq(fv.flow_ident);
            c0Q.enq(zeroExtend(fv.off_ch0));
            c2Q.enq(zeroExtend(fv.off_ch2));
            c4Q.enq(zeroExtend(fv.off_ch4));
            expHit <= expHit + 1;
        endaction
    endfunction

    // Feed one MISS packet (header + 8 payload + Fail resp + key). Header /
    // payload must be dropped; only a NotifyDesc is expected.
    function Action feedMiss (Bit#(32) pktid);
        action
            dut.hdr_in.put(NfBeat { data: hdrData(pktid), keep: '1, last: True });
            dut.lookup_resp_in.put(tagged Fail);
            dut.key_echo_in.put(keyOf(pktid));
            ntQ.enq(keyOf(pktid));
            expMiss <= expMiss + 1;
        endaction
    endfunction

    // One payload beat for packet pktid at runtime beat index bidx (0..7,
    // last on 7). isHit => also record the expected post-payload entry.
    function Action feedPl (Bit#(32) pktid, Bit#(32) bidx, Bool isHit);
        action
            Bool lst = (bidx == fromInteger(beatsPerPkt - 1));
            dut.payload_in.put(NfBeat { data: plData(pktid, bidx),
                                        keep: '1, last: lst });
            if (isHit) plQ.enq(tuple2(plData(pktid, bidx), lst));
        endaction
    endfunction

    // ---- Drain + check rules ----------------------------------------------
    rule do_chk_hdr;
        let b <- dut.hdr_post.get;
        if (!hdrQ.notEmpty) fail("hdr_post produced with no expected header");
        if (b.data != hdrQ.first) fail("hdr_post data mismatch");
        if (!b.last)               fail("hdr_post beat .last not set");
        hdrQ.deq;
        hdrChk <= hdrChk + 1;
    endrule

    rule do_chk_fid;
        let f <- dut.flowident_post.get;
        if (!fidQ.notEmpty) fail("flowident_post produced with no expected value");
        if (f != fidQ.first) fail("flowident_post mismatch");
        fidQ.deq;
        fidChk <= fidChk + 1;
    endrule

    rule do_chk_c0;
        let a <- dut.hbm_cmd0.get;
        if (!c0Q.notEmpty) fail("hbm_cmd0 produced with no expected addr");
        if (a != c0Q.first) fail("hbm_cmd0 addr mismatch");
        c0Q.deq;
        c0Chk <= c0Chk + 1;
    endrule

    rule do_chk_c2;
        let a <- dut.hbm_cmd2.get;
        if (!c2Q.notEmpty) fail("hbm_cmd2 produced with no expected addr");
        if (a != c2Q.first) fail("hbm_cmd2 addr mismatch");
        c2Q.deq;
        c2Chk <= c2Chk + 1;
    endrule

    rule do_chk_c4;
        let a <- dut.hbm_cmd4.get;
        if (!c4Q.notEmpty) fail("hbm_cmd4 produced with no expected addr");
        if (a != c4Q.first) fail("hbm_cmd4 addr mismatch");
        c4Q.deq;
        c4Chk <= c4Chk + 1;
    endrule

    // payload_post drain — gated by plStall to exercise backpressure (case 4).
    rule do_chk_pl (plStall == 0);
        let b <- dut.payload_post.get;
        if (!plQ.notEmpty) fail("payload_post produced with no expected beat");
        match {.expD, .expL} = plQ.first; plQ.deq;
        if (b.data != expD) fail("payload_post data mismatch");
        if (b.last != expL) fail("payload_post .last mismatch");
        plChk <= plChk + 1;
    endrule

    rule do_chk_notify;
        let n <- dut.notify_out.get;
        if (!ntQ.notEmpty) fail("notify_out produced with no expected miss");
        let k = ntQ.first; ntQ.deq;
        if (n.src_ip   != k.src_ip)   fail("notify src_ip mismatch");
        if (n.dst_ip   != k.dst_ip)   fail("notify dst_ip mismatch");
        if (n.src_port != k.src_port) fail("notify src_port mismatch");
        if (n.dst_port != k.dst_port) fail("notify dst_port mismatch");
        if (n.proto    != k.proto)    fail("notify proto mismatch");
        // timestamp must be non-decreasing across misses (free-running cyc).
        if (haveTs && n.timestamp_cycles < lastTs)
            fail("notify timestamp not monotonic");
        lastTs <= n.timestamp_cycles;
        haveTs <= True;
        ntChk  <= ntChk + 1;
    endrule

    // plStall: load on FSM request, else count down to 0.
    rule do_stall_countdown;
        case (stallReq.wget) matches
            tagged Valid .n : plStall <= n;
            tagged Invalid  : if (plStall != 0) plStall <= plStall - 1;
        endcase
    endrule

    // ---- Completion: all fed, every queue drained, counters consistent ----
    rule do_done (allFed
                  && !hdrQ.notEmpty && !fidQ.notEmpty && !plQ.notEmpty
                  && !c0Q.notEmpty  && !c2Q.notEmpty  && !c4Q.notEmpty
                  && !ntQ.notEmpty
                  && hitCnt  == expHit
                  && missCnt == expMiss
                  && hdrChk  == expHit
                  && fidChk  == expHit
                  && c0Chk   == expHit
                  && c2Chk   == expHit
                  && c4Chk   == expHit
                  && plChk   == expHit * fromInteger(beatsPerPkt)
                  && ntChk   == expMiss);
        $display("PASS mkLookupDispatcher: %0d pkts (%0d hit, %0d miss)",
                 expHit + expMiss, expHit, expMiss);
        $finish(0);
    endrule

    // ---- Stimulus sequencer ------------------------------------------------
    Reg#(Bit#(32)) pi <- mkReg(0);
    Reg#(Bit#(32)) bj <- mkReg(0);

    // The DUT FSM blocks re-dispatch until a packet's 8 payload beats drain,
    // so payload may be enqueued any time — the BRAM FIFO buffers it. The
    // per-case loops below feed header+resp+key then the 8 payload beats.

    Stmt prog =
    seq
        // ---- Case 1: 100 all-hit packets --------------------------------
        for (pi <= 0; pi < 100; pi <= pi + 1) seq
            feedHit(pi);
            for (bj <= 0; bj < fromInteger(beatsPerPkt); bj <= bj + 1)
                feedPl(pi, bj, True);
        endseq

        // ---- Case 2: 100 all-miss packets (header/payload dropped) ------
        for (pi <= 200; pi < 300; pi <= pi + 1) seq
            feedMiss(pi);
            for (bj <= 0; bj < fromInteger(beatsPerPkt); bj <= bj + 1)
                feedPl(pi, bj, False);
        endseq

        // ---- Case 2b: a hit right after the misses proves DROP_PL drained
        //      exactly 8 (this packet's payload must line up correctly). ---
        seq
            feedHit(399);
            for (bj <= 0; bj < fromInteger(beatsPerPkt); bj <= bj + 1)
                feedPl(399, bj, True);
        endseq

        // ---- Case 3: interleaved hit/miss (alternating, 100 pkts) -------
        for (pi <= 400; pi < 500; pi <= pi + 1) seq
            if (pi[0] == 0) feedHit(pi); else feedMiss(pi);
            for (bj <= 0; bj < fromInteger(beatsPerPkt); bj <= bj + 1)
                feedPl(pi, bj, pi[0] == 0);
        endseq

        // ---- Case 4: stall payload_post drain, feed a burst of hits, then
        //      release. No loss / misalignment expected. ------------------
        action stallReq.wset(400); endaction
        for (pi <= 600; pi < 650; pi <= pi + 1) seq
            feedHit(pi);
            for (bj <= 0; bj < fromInteger(beatsPerPkt); bj <= bj + 1)
                feedPl(pi, bj, True);
        endseq
        // drain resumes automatically when plStall counts back to 0.

        action allFed <= True; endaction

        // Bounded safety net — do_done fires once all queues empty.
        delay(200000);
        action
            $display("FAIL timeout: hit %0d/%0d miss %0d/%0d hdr %0d pl %0d nt %0d",
                     hitCnt, expHit, missCnt, expMiss, hdrChk, plChk, ntChk);
            $finish(1);
        endaction
    endseq;

    mkAutoFSM(prog);

endmodule : mkSimLookupDispatcher

endpackage : SimLookupDispatcher
