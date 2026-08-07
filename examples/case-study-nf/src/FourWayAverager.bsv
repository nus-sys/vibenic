// =============================================================================
// FourWayAverager — spec §5.1 step 5 (the 4-input "Average" stage).
//
// Elementwise four-way average of one payload-vector stream against three HBM
// reference-vector streams (ch0/ch2/ch4). Every input is a 512-bit AXIS beat
// holding 32 lanes of int16 in the SAME big-endian, lane-major encoding
// (spec §4.1/§4.2), so lane i is bits [i*16+15 : i*16] of each beat — no
// byte/lane reordering is required.
//
// Per lane:  acc = sext20(p) + sext20(v0) + sext20(v2) + sext20(v4)
//            o   = truncate(acc >>> 2)               // arithmetic, rounds -inf
//
// TIMING: the 4-way sum + shift over 32 lanes is split into TWO registered
// pipeline stages (and the output FIFO is mkFIFO, not mkLFIFO), so the wide
// 2 Kbit-in / 512 bit-out adder cone never appears as a single unregistered
// path. This keeps the stage logic short and routable under congestion at the
// cost of +2 cycles latency (negligible vs the µs / HBM-bound pipeline).
// Result is bit-identical to the one-shot sum (integer add is associative;
// the partials fit Int#(18), the recombined accumulator Int#(20)).
//
// Dataflow style per docs/10-bsv-dataflow-handshaking.md: four input FIFOs adapted as
// Put, one output FIFO adapted as Get; each stage is a rule over FIFOs so
// backpressure & starvation are handled entirely by the scheduler.
// =============================================================================
package FourWayAverager;

import FIFO::*;
import GetPut::*;
import Vector::*;

import FlowReduceDefines::*;   // shared types + IfcFourWayAverager

// 32 lanes of int16 per 512-bit beat.
typedef 32 NLanes;

// Stage-1 partials for one lane: (p+v0) and (v2+v4). Each is a sum of two
// int16 values -> fits signed 17 bits; Int#(18) gives margin.
typedef struct {
    Vector#(NLanes, Int#(18)) s01;   // per-lane  p + v0
    Vector#(NLanes, Int#(18)) s23;   // per-lane  v2 + v4
    Bool                      last;  // rides the payload stream (8 beats/pkt)
} AvgPart deriving (Bits);

(* synthesize *)
module mkFourWayAverager (IfcFourWayAverager);

    // mkFIFO: 2-elem pipeline workhorses on each input so a stalled rendezvous
    // does not immediately back-pressure the upstream producers a cycle early.
    FIFO#(NfBeat) pF  <- mkFIFO;   // payload_in
    FIFO#(NfBeat) v0F <- mkFIFO;
    FIFO#(NfBeat) v2F <- mkFIFO;
    FIFO#(NfBeat) v4F <- mkFIFO;

    // Pipeline register between the two add stages (one beat of partials).
    FIFO#(AvgPart) s1F <- mkFIFO;

    // Registered output (mkFIFO, NOT mkLFIFO): breaks the combinational
    // stage-2 -> consumer path so the wide adder cone is fully registered.
    FIFO#(NfBeat) oF <- mkFIFO;  // avg_out

    // Lanes are int16 BIG-ENDIAN on the wire (spec §4.1/§4.2): within a beat,
    // lane i occupies bits [i*16+15:i*16] but with the two bytes in network
    // order, so the true signed value is unpack(bswap16(slice)). Signed math
    // must be on the true value, hence the bswap on every input lane (and the
    // result lane is byte-swapped back in stage 2).
    function Int#(18) add2 (Bit#(16) a, Bit#(16) b);
        Int#(18) sa = signExtend(unpack(bswap16(a)));
        Int#(18) sb = signExtend(unpack(bswap16(b)));
        return sa + sb;
    endfunction

    // Stage 1 — 4-input rendezvous: per lane form the two pair-sums, register.
    rule do_s1;
        let p  = pF.first;  pF.deq;
        let b0 = v0F.first; v0F.deq;
        let b2 = v2F.first; v2F.deq;
        let b4 = v4F.first; v4F.deq;

        Vector#(NLanes, Int#(18)) s01v = newVector;
        Vector#(NLanes, Int#(18)) s23v = newVector;
        for (Integer i = 0; i < valueOf(NLanes); i = i + 1) begin
            s01v[i] = add2(p.data [i*16+15 : i*16], b0.data[i*16+15 : i*16]);
            s23v[i] = add2(b2.data[i*16+15 : i*16], b4.data[i*16+15 : i*16]);
        end
        s1F.enq(AvgPart { s01: s01v, s23: s23v, last: p.last });
    endrule

    // Stage 2 — recombine to Int#(20), arithmetic >>2, truncate to int16.
    rule do_s2;
        let q = s1F.first; s1F.deq;
        Bit#(512) outd = 0;
        for (Integer i = 0; i < valueOf(NLanes); i = i + 1) begin
            Int#(20) acc = signExtend(q.s01[i]) + signExtend(q.s23[i]);
            Int#(16) o   = truncate(acc >> 2);   // `>>` on Int# is arithmetic
            // store the result lane back in big-endian (spec §4.3 egress).
            outd[i*16+15 : i*16] = bswap16(pack(o));
        end
        oF.enq(NfBeat { data: outd, keep: '1, last: q.last });
    endrule

    interface payload_in = toPut(pF);
    interface v0_in       = toPut(v0F);
    interface v2_in       = toPut(v2F);
    interface v4_in       = toPut(v4F);
    interface avg_out      = toGet(oF);

endmodule : mkFourWayAverager

endpackage : FourWayAverager
