// =============================================================================
// ResultEgress — spec §4.3 / §5.1 step 6 (the result-packet construction +
// QDMA-C2H egress stage).
//
// Pops, per result packet, one stored header beat (HeaderPostFIFO), one
// flow_ident (FlowIdentPostFIFO) and the averager's 8-beat vector stream, and
// drives the QDMA-shell TX AXI-Stream (m_axis_rpout, AxisBeatC#(16,16,512,32))
// as exactly 9 beats: 1 spliced header beat + 8 averaged-vector beats with
// tlast on the 9th. tid=0/tdest=0 (spec §3).
//
// Endianness (see the header of src/FlowReduceDefines.bsv): the 64-byte beat is
// little-endian relative to the wire — wire byte k is beat.data[k*8+7 : k*8].
// flow_ident and sequence_num are host-native 32-bit scalars that must appear
// on the wire in NETWORK byte order, so each is byte-swapped with bswap32
// before being spliced in. The header echo (bytes 0..41, 56..63) and the
// averaged vector are passed through verbatim — already wire-ordered.
//
// Header splice (spec §4.3), with byte k at data[k*8+7 : k*8]:
//   bytes 42..45  flow_ident   -> data[45*8+7 : 42*8] = data[367:336] = bswap32(fid)
//   bytes 46..49  sequence_num -> data[49*8+7 : 46*8] = data[399:368] = bswap32(seqnum)
//   bytes 50..55  padding      -> data[55*8+7 : 50*8] = data[447:400] = 0
//   bytes 0..41, 56..63        : echoed unchanged
//
// FSM: Reg#(EgState){HDR,VEC} + Reg#(UInt#(4)) vbeat. One beat emitted per rule
// firing (dataflow handshake per docs/10-bsv-dataflow-handshaking.md and
// docs/11-bsv-packet-per-beat.md):
//   HDR : pop hdrF + fidF, splice, emit header beat (last=False), -> VEC, vbeat=0
//   VEC : pop avgF, emit vector beat (last on the 8th); on the 8th bump the
//         global sequence_num, pulse cntPulse.processed, -> HDR
//
// Sequence numbering (spec §11.1): one global 32-bit monotonic counter,
// stamped into every result and incremented once per emitted packet, wrapping
// at 2^32.
//
// FIFO sizing (>= N_INFLIGHT=32 packets, spec §5.2):
//   hdrF  mkSizedFIFO(64)        ~ 32 single-beat headers + slack
//   fidF  mkSizedFIFO(32)        = 32 packed flow_idents
//   avgF  mkSizedBRAMFIFO(256)   = 32 * 8 averaged vector beats (BRAM, 16 KB)
// =============================================================================
package ResultEgress;

import FIFO::*;
import BRAMFIFO::*;
import GetPut::*;
import ClientServer::*;
import Connectable::*;
import DefaultValue::*;

import FlowReduceDefines::*;   // shared types + IfcResultEgress

typedef enum { HDR, VEC } EgState deriving (Bits, Eq, FShow);

(* synthesize *)
module mkResultEgress (IfcResultEgress);

    // Shell-boundary AXIS master adapter: feed it NfBeatC via .din, expose its
    // raw m_axis as the module's m_axis (width-matches m_axis_rpout).
    AxisMasterAdapterC#(16,16,512,32) txAdpt <- mkAxisMasterAdapterC;

    // Input buffers sized for >= 32 in-flight packets (spec §5.2).
    FIFO#(NfBeat)    hdrF <- mkSizedFIFO(64);       // 1 stored header beat / pkt
    FIFO#(Bit#(32))  fidF <- mkSizedFIFO(32);       // 1 flow_ident / pkt
    FIFO#(NfBeat)    avgF <- mkSizedBRAMFIFO(256);  // 8 averaged beats / pkt

    // Global monotonic sequence counter (spec §11.1); wraps at 2^32.
    Reg#(Bit#(32))   seqnum <- mkReg(0);

    // FSM: alternate one header beat then 8 vector beats per packet.
    Reg#(EgState)    st     <- mkReg(HDR);
    Reg#(UInt#(4))   vbeat  <- mkReg(0);

    // One-cycle counter pulse; mkDWire so it self-clears and reads
    // combinationally in the always_ready cntPulse method.
    Wire#(Bool)      pulseProc <- mkDWire(False);

    // ---- Header beat: splice bytes 42..55, echo everything else -------------
    // Implicit conditions: hdrF/fidF notEmpty and the adapter sbuf notFull.
    rule do_emit_hdr (st == HDR);
        let hdr = hdrF.first; hdrF.deq;
        let fid = fidF.first; fidF.deq;

        Bit#(512) d = hdr.data;
        // byte k -> d[k*8+7 : k*8]
        d[45*8+7 : 42*8] = bswap32(fid);       // bytes 42..45 = flow_ident   (NBO)
        d[49*8+7 : 46*8] = bswap32(seqnum);    // bytes 46..49 = sequence_num (NBO)
        d[55*8+7 : 50*8] = 48'h0;              // bytes 50..55 = padding (zero)
        // bytes 0..41 and 56..63 pass through unchanged (echo).

        txAdpt.din.put(NfBeatC {
            data: d, keep: '1, last: False,
            id: 0, dest: 0, user_data: 0 });

        st    <= VEC;
        vbeat <= 0;
    endrule

    // ---- Vector beats: 8 averaged beats, tlast on the 8th ------------------
    rule do_emit_vec (st == VEC);
        let avg = avgF.first; avgF.deq;

        Bool lst = (vbeat == 7);

        txAdpt.din.put(NfBeatC {
            data: avg.data, keep: '1, last: lst,
            id: 0, dest: 0, user_data: 0 });

        if (lst) begin
            // Last beat of the packet: advance the global sequence number and
            // pulse CNT_PROCESSED (spec §5.1 step 6 / §7).
            seqnum    <= seqnum + 1;
            pulseProc <= True;
            st        <= HDR;
        end
        else
            vbeat <= vbeat + 1;
    endrule

    // ---- Interface ----------------------------------------------------------
    interface hdr_in       = toPut(hdrF);
    interface flowident_in = toPut(fidF);
    interface avg_in       = toPut(avgF);
    interface m_axis       = txAdpt.m_axis;

    method CntPulse cntPulse;
        CntPulse p = defaultValue;
        p.processed = pulseProc;
        return p;
    endmethod

endmodule : mkResultEgress

endpackage : ResultEgress
