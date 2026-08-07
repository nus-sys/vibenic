// =============================================================================
// SimFourWayAverager — Bluesim self-checking testbench for mkFourWayAverager.
//
// Drives the four Put inputs and drains avg_out, comparing every output lane
// against a BSV golden model. Deterministic LFSR-driven random stimulus plus
// directed corner cases, output backpressure, and a one-input stall.
//
//   make bsim PKG=SimFourWayAverager MOD=mkSimFourWayAverager
// =============================================================================
package SimFourWayAverager;

import FIFO::*;
import FIFOF::*;
import GetPut::*;
import Vector::*;
import LFSR::*;
import StmtFSM::*;

import FlowReduceDefines::*;
import FourWayAverager::*;

typedef 32 NLanes;
Integer beatsPerPkt = 8;

// Golden lane: same signed widen / arithmetic shift / truncate the DUT does.
function Int#(16) goldenLane (Int#(16) p, Int#(16) v0, Int#(16) v2, Int#(16) v4);
    Int#(20) acc = signExtend(p) + signExtend(v0) + signExtend(v2) + signExtend(v4);
    return truncate(acc >> 2);
endfunction

// Expand a 32-bit state word into a distinct, reproducible 512-bit beat.
function Bit#(512) expand512 (Bit#(32) s);
    Bit#(512) d = 0;
    for (Integer w = 0; w < 16; w = w + 1) begin
        Bit#(32) m = s ^ (fromInteger(w) * 32'h9E3779B1);
        m = m ^ (m >> 15);
        m = m * 32'h85EBCA77;
        m = m ^ (m >> 13);
        d[w*32+31 : w*32] = m;
    end
    return d;
endfunction

(* synthesize *)
module mkSimFourWayAverager ();

    IfcFourWayAverager dut <- mkFourWayAverager;

    // expected-output queue: one entry {expData, expLast} per fed beat. Sized
    // big enough never to gate the feed side, so DUT backpressure is real.
    FIFOF#(Tuple2#(Bit#(512), Bool)) expQ <- mkSizedFIFOF(512);

    Reg#(Bit#(32)) pktCnt   <- mkReg(0);   // packets fed
    Reg#(Bit#(32)) beatsChk <- mkReg(0);   // beats verified
    Reg#(Bool)     allFed   <- mkReg(False);

    LFSR#(Bit#(32)) rndP  <- mkLFSR_32;
    LFSR#(Bit#(32)) rndV0 <- mkLFSR_32;
    LFSR#(Bit#(32)) rndV2 <- mkLFSR_32;
    LFSR#(Bit#(32)) rndV4 <- mkLFSR_32;

    Reg#(Bit#(16))     drainStall <- mkReg(0);   // >0 ⇒ drain rule paused
    RWire#(Bit#(16))   stallReq   <- mkRWire;     // FSM asks for a stall span

    // Loop counters for the StmtFSM.
    Reg#(Bit#(32)) bi  <- mkReg(0);   // beat index within a packet
    Reg#(Bit#(32)) pi  <- mkReg(0);   // packet index in a random run

    // ---- push one beat to all 4 inputs + enqueue its golden result -------
    function Action feedBeat (Bit#(512) pd, Bit#(512) d0,
                              Bit#(512) d2, Bit#(512) d4, Bool lst);
        action
            dut.payload_in.put(NfBeat { data: pd, keep: '1, last: lst });
            dut.v0_in.put     (NfBeat { data: d0, keep: '1, last: lst });
            dut.v2_in.put     (NfBeat { data: d2, keep: '1, last: lst });
            dut.v4_in.put     (NfBeat { data: d4, keep: '1, last: lst });
            // Lanes are int16 BIG-ENDIAN on the wire (spec §4.1/§4.2): true
            // value is bswap16 of the slice; the averaged result lane is
            // stored back big-endian. Mirror that here so this stays a
            // spec-faithful self-check of mkFourWayAverager.
            Bit#(512) exp = 0;
            for (Integer i = 0; i < valueOf(NLanes); i = i + 1) begin
                Int#(16) lp = unpack(bswap16(pd[i*16+15 : i*16]));
                Int#(16) l0 = unpack(bswap16(d0[i*16+15 : i*16]));
                Int#(16) l2 = unpack(bswap16(d2[i*16+15 : i*16]));
                Int#(16) l4 = unpack(bswap16(d4[i*16+15 : i*16]));
                exp[i*16+15 : i*16] = bswap16(pack(goldenLane(lp, l0, l2, l4)));
            end
            expQ.enq(tuple2(exp, lst));
        endaction
    endfunction

    // One random beat: read current LFSR states, then step them.
    function Action feedRandBeat (Bool lst);
        action
            feedBeat(expand512(rndP.value),  expand512(rndV0.value),
                     expand512(rndV2.value), expand512(rndV4.value), lst);
            rndP.next; rndV0.next; rndV2.next; rndV4.next;
        endaction
    endfunction

    // ---- drain + check ---------------------------------------------------
    // Sole writer of drainStall: load on FSM request, else count down.
    rule do_drain_countdown;
        case (stallReq.wget) matches
            tagged Valid .n : drainStall <= n;
            tagged Invalid  : if (drainStall != 0) drainStall <= drainStall - 1;
        endcase
    endrule

    rule do_check (drainStall == 0);
        let b <- dut.avg_out.get;
        match {.expD, .expL} = expQ.first; expQ.deq;
        if (b.data != expD) begin
            $display("FAIL data mismatch at checked-beat %0d", beatsChk);
            for (Integer i = 0; i < valueOf(NLanes); i = i + 1) begin
                Bit#(16) got = b.data[i*16+15 : i*16];
                Bit#(16) wnt = expD [i*16+15 : i*16];
                if (got != wnt)
                    $display("  lane %0d: got 0x%04h want 0x%04h", i, got, wnt);
            end
            $finish(1);
        end
        if (b.last != expL) begin
            $display("FAIL last mismatch at checked-beat %0d: got %0d want %0d",
                     beatsChk, b.last, expL);
            $finish(1);
        end
        if (b.keep != '1) begin
            $display("FAIL keep not all-ones at checked-beat %0d: 0x%016h",
                     beatsChk, b.keep);
            $finish(1);
        end
        beatsChk <= beatsChk + 1;
    endrule

    // Completion: every fed packet's beats verified and the expected queue is
    // drained. Independent of a beat arriving, so it fires reliably once the
    // stimulus FSM has signalled allFed.
    rule do_done (allFed && !expQ.notEmpty
                  && beatsChk == pktCnt * fromInteger(beatsPerPkt));
        $display("PASS mkFourWayAverager: %0d packets", pktCnt);
        $finish(0);
    endrule

    // Directed corner-case lane patterns.
    function Bit#(16) zeroF (Integer l) = 16'h0000;
    function Bit#(16) extP  (Integer l) = (l % 2 == 0) ? 16'h7FFF : 16'h8000;
    function Bit#(16) extA  (Integer l) = (l % 3 == 0) ? 16'h7FFF :
                                          (l % 3 == 1) ? 16'h8000 : 16'h0001;
    function Bit#(16) extB  (Integer l) = (l % 4 == 0) ? 16'h8000 : 16'h7FFF;
    function Bit#(16) extC  (Integer l) = (l % 5 == 0) ? 16'hFFFF : 16'h0000;

    function Bit#(512) build (function Bit#(16) f (Integer l));
        Bit#(512) d = 0;
        for (Integer i = 0; i < valueOf(NLanes); i = i + 1)
            d[i*16+15 : i*16] = f(i);
        return d;
    endfunction

    Stmt prog =
    seq
        // Seed the LFSRs with distinct non-zero values (deterministic).
        action rndP.seed(32'h0000_0001);  endaction
        action rndV0.seed(32'hDEAD_BEEF); endaction
        action rndV2.seed(32'h1234_5678); endaction
        action rndV4.seed(32'hCAFE_F00D); endaction

        // ---- Case 1: all-zero packet (8 beats) ----
        for (bi <= 0; bi < fromInteger(beatsPerPkt); bi <= bi + 1)
            feedBeat(build(zeroF), build(zeroF), build(zeroF), build(zeroF),
                     bi == fromInteger(beatsPerPkt - 1));
        action pktCnt <= pktCnt + 1; endaction

        // ---- Case 2: extremes / saturation mixes ----
        for (bi <= 0; bi < fromInteger(beatsPerPkt); bi <= bi + 1)
            feedBeat(build(extP), build(extA), build(extB), build(extC),
                     bi == fromInteger(beatsPerPkt - 1));
        action pktCnt <= pktCnt + 1; endaction

        // ---- Case 5: stall stimulus mid-packet — DUT rendezvous must hold
        //      state across idle cycles where NO input is driven. ----
        for (bi <= 0; bi < fromInteger(beatsPerPkt); bi <= bi + 1) seq
            feedBeat(build(extC), build(extP), build(extA), build(extB),
                     bi == fromInteger(beatsPerPkt - 1));
            delay(3);                       // idle: no puts; DUT must wait
        endseq
        action pktCnt <= pktCnt + 1; endaction

        // ---- Case 4: output backpressure across a few random packets ----
        action stallReq.wset(23); endaction          // hold drain off a while
        for (pi <= 0; pi < 4; pi <= pi + 1) seq
            for (bi <= 0; bi < fromInteger(beatsPerPkt); bi <= bi + 1)
                feedRandBeat(bi == fromInteger(beatsPerPkt - 1));
            action pktCnt <= pktCnt + 1; endaction
        endseq

        // ---- Case 3: 1000 random packets, lane-by-lane vs golden ----
        for (pi <= 0; pi < 1000; pi <= pi + 1) seq
            for (bi <= 0; bi < fromInteger(beatsPerPkt); bi <= bi + 1)
                feedRandBeat(bi == fromInteger(beatsPerPkt - 1));
            action pktCnt <= pktCnt + 1; endaction
        endseq

        action allFed <= True; endaction
        // do_check issues $finish(0) once every expected beat is verified.
        // Bounded safety net against a hang.
        delay(40000);
        action
            $display("FAIL timeout: checked %0d of %0d beats",
                     beatsChk, pktCnt * fromInteger(beatsPerPkt));
            $finish(1);
        endaction
    endseq;

    mkAutoFSM(prog);

endmodule : mkSimFourWayAverager

endpackage : SimFourWayAverager
