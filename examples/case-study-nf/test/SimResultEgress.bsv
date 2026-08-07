// =============================================================================
// SimResultEgress — Bluesim testbench for mkResultEgress (spec §4.3 / §5.1.6).
//
// Topology:
//   mkResultEgress.m_axis  --mkConnection-->  mkAxisSlaveAdapterC#(16,16,512,32)
// A collector rule drains the slave adapter's .dout into a model output ring
// (the 9 emitted beats per packet) so the full byte map can be checked.
//
// Stimulus: N packets. For each packet i a header beat is fed whose echo
// regions carry a recognizable pattern — pid=i in wire bytes 0..3 and a known
// 64-bit client_timestamp in wire bytes 56..63 — while bytes 42..55 hold
// garbage (must be overwritten by the splice). Then flow_ident_i, then 8
// averaged beats each tagged with (pid, beat index).
//
// Endianness recomputed independently here: wire byte k == beat.data[k*8+7:k*8]
// and flow_ident / sequence_num land in NETWORK byte order, so the TB applies
// bswap32 itself to derive the expected spliced 32-bit fields (mirrors the
// Python golden parse_result_packet offsets: flow_ident @ 42..45,
// sequence_num @ 46..49, padding @ 50..55 == 0, client_ts @ 56..63 echoed).
//
// Checks per packet:
//   (a) beat 1: bytes 0..41 and 56..63 EXACTLY equal the fed header bytes;
//       bytes 42..45 == bswap32(flow_ident_i); bytes 46..49 ==
//       bswap32(expected_seqnum) with expected_seqnum incrementing from 0;
//       bytes 50..55 == 0.
//   (b) beats 2..9 equal the 8 fed averaged beats, in order.
//   (c) tlast asserted only on beat 9; tid==0 and tdest==0 on all 9 beats.
//   (d) seqnum monotonic across packets (0,1,2,...).
//   (e) sink backpressure (collector randomly stalls) AND a producer gap
//       (avg beats fed late) — output stays correct and contiguous per packet.
//
// $display PASS/FAIL, $finish(0) on success / $finish(1) on any failure or the
// global cycle-timeout.
// =============================================================================
package SimResultEgress;

import StmtFSM::*;
import FIFO::*;
import GetPut::*;
import ClientServer::*;
import Connectable::*;
import DefaultValue::*;
import Vector::*;
import LFSR::*;
import Cur_Cycle::*;

import FlowReduceDefines::*;   // shared types, NfBeatC, adapters
import ResultEgress::*;        // DUT

(* synthesize *)
module mkSimResultEgress (Empty);

    let dut <- mkResultEgress;

    // Sink: a slave adapter whose s_axis is fed by the DUT m_axis.
    AxisSlaveAdapterC#(16,16,512,32) sink <- mkAxisSlaveAdapterC;
    mkConnection(dut.m_axis, sink.s_axis);

    Integer nPkts = 6;

    // ---- Stimulus model -----------------------------------------------------
    // Header beat for packet i: pid=i in wire bytes 0..3, a known 64-bit
    // client_timestamp in bytes 56..63, GARBAGE in 42..55 (must be spliced
    // away). Everything else (4..41) is also a recognizable echo pattern.
    function Bit#(64) clientTs (Integer i) = fromInteger('h1122334455660000 + i);
    function Bit#(32) flowId   (Integer i) = fromInteger('hABCD0000 + i*7 + 1);

    function Bit#(512) hdrBytes (Integer i);
        Bit#(512) d = 0;
        // bytes 0..3 = pid (recognizable echo region)
        d[31:0]    = fromInteger(i);
        // bytes 4..41 = a recognizable filler echo pattern
        for (Integer b = 4; b < 42; b = b + 1) begin
            Bit#(8) fb = fromInteger((64 + b + i) % 256);
            d[b*8+7 : b*8] = fb;
        end
        // bytes 42..55 = garbage that MUST be overwritten by the splice
        d[45*8+7 : 42*8] = 32'hDEADBEEF;     // bytes 42..45 garbage
        d[49*8+7 : 46*8] = 32'hC0FFEE11;     // bytes 46..49 garbage
        d[55*8+7 : 50*8] = 48'hA5A5A5A5A5A5; // bytes 50..55 garbage
        // bytes 56..63 = known client_timestamp (echoed verbatim)
        d[511:448] = clientTs(i);
        return d;
    endfunction

    // Averaged beat j (0..7) of packet i: a deterministic, distinguishable
    // 512-bit content (32 int16 lanes carrying pid/beat-derived values).
    function Bit#(512) avgBytes (Integer i, Integer j);
        Bit#(512) d = 0;
        for (Integer ln = 0; ln < 32; ln = ln + 1) begin
            Bit#(16) v = fromInteger((i*131 + j*17 + ln*3) % 65536);
            d[ln*16+15 : ln*16] = v;
        end
        return d;
    endfunction

    // Precomputed expectation tables (mkXxx need compile-time Integers; index
    // at runtime with Bit counters).
    Vector#(16, Bit#(512))    expHdr  = newVector;
    Vector#(16, Bit#(32))     expFid  = newVector;
    Vector#(16, Bit#(64))     expTs   = newVector;
    Vector#(128, Bit#(512))   expAvg  = newVector;
    for (Integer i = 0; i < 16; i = i + 1) begin
        expHdr[i] = hdrBytes(i);
        expFid[i] = flowId(i);
        expTs[i]  = clientTs(i);
    end
    for (Integer i = 0; i < 16; i = i + 1)
        for (Integer j = 0; j < 8; j = j + 1)
            expAvg[i*8+j] = avgBytes(i, j);

    // Independent re-implementation of bswap32 in the TB (do NOT reuse the DUT
    // path) to verify the byte order explicitly.
    function Bit#(32) tbBswap (Bit#(32) x) =
        { x[7:0], x[15:8], x[23:16], x[31:24] };

    // ---- Output collector (with random sink backpressure) ------------------
    // The DUT drives the slave adapter; this rule drains sink.dout, but only
    // when its LFSR-derived stall bit is clear, exercising backpressure (e).
    Reg#(Bit#(32))  beatIdx  <- mkReg(0);   // global emitted-beat index
    Reg#(Bool)      ok       <- mkReg(True);
    Reg#(Bool)      done     <- mkReg(False);

    LFSR#(Bit#(16)) rng <- mkLFSR_16;
    Reg#(Bool)      rngInit <- mkReg(False);

    // A PulseWire decouples the (possibly multiple) per-beat failure reports
    // from the single ok-Reg write (Reg writes cannot be combined in a rule).
    // Within the collector rule, all per-check verdicts fold into one local
    // Bool and the pulse is sent at most once at the end of the rule body.
    PulseWire       failPW  <- mkPulseWire;

    rule latch_fail (failPW);
        ok <= False;
    endrule

    // chk just prints on failure (Action — multiple $display in one rule do
    // NOT conflict; only Reg/method writes do) and the rule folds the raw
    // comparison Bools so a single end-of-rule send drives failPW.
    function Action chk (Bool cond, String msg);
        return action
            if (!cond)
                $display("FAIL [beat %0d, cyc %0d]: %s",
                         beatIdx, cur_cycle(), msg);
        endaction;
    endfunction

    rule init_rng (!rngInit);
        rng.seed(16'hBEEF);
        rngInit <= True;
    endrule

    // Free-running LFSR advance: MUST be independent of do_collect, otherwise a
    // stall cycle would freeze the LFSR (rng never advances -> permanent
    // stall -> deadlock). One step per cycle once seeded.
    rule advance_rng (rngInit);
        rng.next;
    endrule

    // Stall ~ when low bit of LFSR is 1 (roughly half the cycles), so the DUT
    // sees sink backpressure intermittently.
    Bool stall = (rng.value[0] == 1'b1);

    rule do_collect (rngInit && !stall && !done);
        let b <- sink.dout.get;

        Bit#(32) gi  = beatIdx;
        Bit#(32) pkt = gi / 9;          // packet index
        Bit#(32) pos = gi % 9;          // 0 = header, 1..8 = vector beats

        Bit#(512) ehdr = expHdr[pkt];
        Bit#(32)  efid = expFid[pkt];
        Bit#(32)  eseq = pkt;                 // (d) seqnum == pkt index

        // (c) sideband: tid/tdest must be 0 on every beat; tlast only on beat 9.
        Bool wantLast = (pos == 8);
        Bool c_id   = (b.id   == 0);
        Bool c_dst  = (b.dest == 0);
        Bool c_last = (b.last == wantLast);
        Bool c_keep = (b.keep == '1);

        // (a) header beat: echo regions + the 14-byte splice.
        Bit#(336) gotEcho  = b.data[335:0];     // bytes 0..41
        Bit#(336) wantEcho = ehdr[335:0];
        Bit#(64)  gotTs    = b.data[511:448];   // bytes 56..63
        Bit#(32)  got42    = b.data[367:336];   // bytes 42..45
        Bit#(32)  got46    = b.data[399:368];   // bytes 46..49
        Bit#(48)  got50    = b.data[447:400];   // bytes 50..55
        Bool isHdr = (pos == 0);
        Bool c_echo = !isHdr || (gotEcho == wantEcho);
        Bool c_ts1  = !isHdr || (gotTs == ehdr[511:448]);
        Bool c_ts2  = !isHdr || (gotTs == expTs[pkt]);
        Bool c_f42  = !isHdr || (got42 == tbBswap(efid));
        Bool c_f46  = !isHdr || (got46 == tbBswap(eseq));
        Bool c_pad  = !isHdr || (got50 == 48'h0);

        // (b) vector beats 2..9 == the 8 fed averaged beats, in order.
        Bit#(32) vidx = pkt * 8 + (pos - 1);
        Bool c_vec = isHdr || (b.data == expAvg[vidx]);

        chk(c_id,   "tid must be 0");
        chk(c_dst,  "tdest must be 0");
        chk(c_last, wantLast ? "tlast must be set on beat 9"
                             : "tlast must be clear on beats 1..8");
        chk(c_keep, "tkeep must be all-ones");
        chk(c_echo, "header bytes 0..41 not echoed verbatim");
        chk(c_ts1,  "client_timestamp bytes 56..63 not echoed verbatim");
        chk(c_ts2,  "client_timestamp value mismatch");
        chk(c_f42,  "bytes 42..45 != bswap32(flow_ident)");
        chk(c_f46,  "bytes 46..49 != bswap32(sequence_num)");
        chk(c_pad,  "bytes 50..55 (padding) not zeroed");
        chk(c_vec,  "averaged vector beat content/order mismatch");

        Bool good = c_id && c_dst && c_last && c_keep && c_echo &&
                    c_ts1 && c_ts2 && c_f42 && c_f46 && c_pad && c_vec;
        if (!good) failPW.send;

        if (gi == fromInteger(nPkts * 9 - 1)) done <= True;
        beatIdx <= beatIdx + 1;
    endrule

    // ---- Stimulus sequencer -------------------------------------------------
    // Feeds N packets. Header + flow_ident first; then (e) a deliberate
    // producer gap before the 8 averaged beats so the DUT must wait in VEC
    // state without corrupting / reordering output.
    Reg#(Bit#(32)) tocnt <- mkReg(0);
    rule do_timeout;
        tocnt <= tocnt + 1;
        if (tocnt > 30000) begin
            $display("FAIL: global timeout at cycle %0d (beat %0d)",
                cur_cycle(), beatIdx);
            $finish(1);
        end
    endrule

    // Per-packet feed: header, flow_ident, gap, 8 avg beats. mkXxx tables are
    // indexed by a runtime Reg so the StmtFSM stays a single static body with
    // a loop counter.
    Reg#(UInt#(8)) pi <- mkReg(0);

    Stmt feedOne =
        seq
            // header beat + flow_ident for packet `pi`
            action
                dut.hdr_in.put(NfBeat { data: expHdr[pi], keep: '1, last: False });
            endaction
            action
                dut.flowident_in.put(expFid[pi]);
            endaction
            // (e) producer gap: stall the averager feed for several cycles so
            // the DUT sits in VEC waiting on avgF (must not emit early/garbage).
            delay(7);
            // 8 averaged beats, tlast carried on the 8th (mirrors the
            // averager's avg_out stream; the DUT sets wire tlast itself).
            action dut.avg_in.put(NfBeat { data: expAvg[pi*8+0], keep: '1, last: False }); endaction
            action dut.avg_in.put(NfBeat { data: expAvg[pi*8+1], keep: '1, last: False }); endaction
            action dut.avg_in.put(NfBeat { data: expAvg[pi*8+2], keep: '1, last: False }); endaction
            action dut.avg_in.put(NfBeat { data: expAvg[pi*8+3], keep: '1, last: False }); endaction
            action dut.avg_in.put(NfBeat { data: expAvg[pi*8+4], keep: '1, last: False }); endaction
            action dut.avg_in.put(NfBeat { data: expAvg[pi*8+5], keep: '1, last: False }); endaction
            action dut.avg_in.put(NfBeat { data: expAvg[pi*8+6], keep: '1, last: False }); endaction
            action dut.avg_in.put(NfBeat { data: expAvg[pi*8+7], keep: '1, last: True  }); endaction
        endseq;

    Stmt test = seq
        // Drive packets back to back (the DUT FIFOs absorb in-flight slack;
        // the collector applies random backpressure throughout).
        for (pi <= 0; pi < fromInteger(nPkts); pi <= pi + 1)
            feedOne;

        // Wait for all 9*N beats to be collected (or the timeout to fire).
        await(done);

        action
            if (ok) begin
                $display("PASS mkResultEgress: %0d pkts", nPkts);
                $finish(0);
            end
            else begin
                $display("FAIL: one or more ResultEgress checks failed");
                $finish(1);
            end
        endaction
    endseq;

    mkAutoFSM(test);

endmodule : mkSimResultEgress

endpackage : SimResultEgress
