// =============================================================================
// PacketIngress — spec §5.1 step 1 (the ingress parse/filter/admit stage).
//
// Consumes the QDMA-shell RX AXI-Stream (s_axis_rpin, AxisBeatC#(16,16,512,32))
// one beat at a time and runs a per-beat beat-counter FSM that interprets a
// conformant 576 B wire packet as exactly 9 beats:
//
//   beat 0      : 64 B Ethernet/IPv4/UDP header (+ client shim region)
//   beats 1..8  : 512 B int16x256 query vector (tlast on beat 8 = 9th overall)
//
// On the header beat the Ethernet/IPv4/UDP header is overlaid via a packed
// struct (UdpIpEthHeader, EtherDefines) — the struct is ordered so wire byte k
// lands at beat.data[k*8+7:k*8] (see docs/11-bsv-packet-per-beat.md); no byte
// reorder is performed here.
//
// Filter (spec §4.1): a packet is ACCEPTED iff
//   * assert_udpid_hdr(h)            — IPv4 ethertype, version 4, ihl 5, UDP
//   * h.ip.total_len == expIpTotalLen (562)  — IPv4 wire length == 576 B
//   * the frame is exactly 9 beats (tlast on the 9th, i.e. body beat 8)
//   * beat.dest == 0                 — shell ingress tdest (spec §3)
// Anything else is a filtered drop, counted in CNT_DROP_FILTER.
//
// FSM states (Reg#(RxState) + Reg#(UInt#(4)) beatcnt):
//   IDLE  : awaiting/parsing the header beat (beatcnt==0)
//   BODY  : streaming the 8 accepted payload beats into payload_out
//   DRAIN : swallowing the remaining beats of a rejected multi-beat frame so
//           the stream stays frame-aligned for the next packet
//
// Counters (spec §7): CNT_RX counts every ingress packet seen (accepted OR
// filtered); CNT_DROP_FILTER counts the filtered ones. Both are exposed as
// one-cycle pulses on cntPulse, driven from mkDWire flags set in do_rx_init.
//
// Dataflow style per docs/10-bsv-dataflow-handshaking.md: the adapter Get and the
// output FIFOs inject the handshake; exactly one beat is consumed per rule
// firing so the FSM stays beat-accurate, and backpressure on any accepted-path
// FIFO naturally stalls the whole ingress.
//
// FIFO sizing (>= N_INFLIGHT=32 packets, spec §5.2):
//   hdr_out      mkSizedFIFO(64)        ~ 32 single-beat headers + slack
//   payload_out  mkSizedBRAMFIFO(256)   = 32 * 8 vector beats (BRAM, 16 KB)
//   lookup_key   mkSizedFIFO(32)        = 32 packed keys
//   key_echo     mkSizedFIFO(32)        = 32 echoed keys
// =============================================================================
package PacketIngress;

import FIFO::*;
import BRAMFIFO::*;
import GetPut::*;
import ClientServer::*;
import Connectable::*;
import ConfigReg::*;
import DefaultValue::*;

import FlowReduceDefines::*;   // shared types + IfcPacketIngress

typedef enum { IDLE, BODY, DRAIN } RxState deriving (Bits, Eq, FShow);

(* synthesize *)
module mkPacketIngress (IfcPacketIngress);

    // Shell-boundary AXIS slave -> Get#(NfBeatC) of incoming beats. The adapter
    // ANDs tkeep & tstrb and exposes the raw s_axis as its .s_axis port, which
    // we re-export verbatim as the module's s_axis.
    AxisSlaveAdapterC#(16,16,512,32) rxAdpt <- mkAxisSlaveAdapterC;

    // FSM state. mkConfigReg on beatcnt is unnecessary (single writer), plain
    // Reg suffices; one rule fires per cycle so there is never a conflict.
    Reg#(RxState)     state    <- mkReg(IDLE);
    Reg#(UInt#(4))    beatcnt  <- mkReg(0);

    // CTRL[0] enable, sampled by do_rx_init. mkConfigReg so the always_ready
    // set_enable Put can update it in the same cycle the datapath reads it
    // (docs/10-bsv-dataflow-handshaking.md).
    Reg#(Bool)        enabled  <- mkConfigReg(False);

    // Accepted-path output FIFOs (sized for >= 32 in-flight packets, spec §5.2).
    FIFO#(NfBeat)             hdrF    <- mkSizedFIFO(64);
    FIFO#(NfBeat)             payF    <- mkSizedBRAMFIFO(256);
    FIFO#(Bit#(FlowKey_w))    keyF    <- mkSizedFIFO(32);
    FIFO#(FlowKey)            echoF   <- mkSizedFIFO(32);

    // One-cycle counter pulses. mkDWire so they self-clear and read
    // combinationally in the always_ready cntPulse method.
    Wire#(Bool)       pulseRx   <- mkDWire(False);
    Wire#(Bool)       pulseDrop <- mkDWire(False);

    // Convert a shell beat (data/keep/last/id/dest/user) to an internal
    // datapath beat (data/keep/last only).
    function NfBeat toNfBeat (NfBeatC b) =
        NfBeat { data: b.data, keep: b.keep, last: b.last };

    // ---- Header beat: parse, filter, admit (spec §4.1, §5.1 step 1) ----------
    // Fires only when IDLE, at the start of a frame, and enabled. Exactly one
    // beat consumed. The header struct is narrower than 512 b so truncate the
    // beat before unpack.
    rule do_rx_init (state == IDLE && beatcnt == 0 && enabled);
        let beat <- rxAdpt.dout.get;
        UdpIpEthHeader h = unpack(truncate(beat.data));

        // Every ingress packet seen counts toward CNT_RX (incl. filtered).
        pulseRx <= True;

        // Filter: protocol well-formed AND IPv4 wire length 576 B AND single-
        // beat frame must NOT be last here (a conformant packet has 8 more
        // body beats) AND shell ingress tdest == 0.
        Bool proto_ok  = assert_udpid_hdr(h);
        // IPv4 total_length is big-endian on the wire; the header struct reads
        // it byte-swapped (little-endian-relative beat), so compare against the
        // byte-swapped expected value (562 -> 0x3202).
        Bool len_ok    = (pack(h.ip.total_len) == bswap16(pack(expIpTotalLen)));
        Bool dest_ok   = (beat.dest == 0);
        // A conformant 9-beat packet's header beat is never `last`.
        Bool not_short = !beat.last;
        Bool accept    = proto_ok && len_ok && dest_ok && not_short;

        if (accept) begin
            // Push the 64 B header beat (timestamp rides along, spec §5.1).
            hdrF.enq(toNfBeat(beat));
            // Build & submit the 5-tuple lookup key; echo the typed key for
            // the miss/notify path.
            FlowKey k = flowKeyFromHeader(h);
            keyF.enq(packFlowKey(k));
            echoF.enq(k);
            state   <= BODY;
            beatcnt <= 1;
        end
        else begin
            // Filtered drop (spec §4.1): count it, and if the frame has more
            // beats, swallow them so the stream stays frame-aligned.
            pulseDrop <= True;
            if (!beat.last) begin
                state   <= DRAIN;
                beatcnt <= 0;
            end
            else begin
                state   <= IDLE;
                beatcnt <= 0;
            end
        end
    endrule

    // ---- Body beats: stream the 8 accepted vector beats ---------------------
    rule do_rx_body (state == BODY);
        let beat <- rxAdpt.dout.get;
        payF.enq(toNfBeat(beat));
        if (beat.last) begin
            state   <= IDLE;
            beatcnt <= 0;
        end
        else
            beatcnt <= beatcnt + 1;
    endrule

    // ---- Drain: swallow the remainder of a rejected multi-beat frame --------
    rule do_rx_drain (state == DRAIN);
        let beat <- rxAdpt.dout.get;
        if (beat.last) begin
            state   <= IDLE;
            beatcnt <= 0;
        end
    endrule

    // ---- Interface ----------------------------------------------------------
    interface s_axis        = rxAdpt.s_axis;
    interface hdr_out       = toGet(hdrF);
    interface payload_out   = toGet(payF);
    interface lookup_key_out = toGet(keyF);
    interface key_echo_out   = toGet(echoF);

    method Action set_enable (Bool en);
        enabled <= en;
    endmethod

    method CntPulse cntPulse;
        CntPulse p = defaultValue;
        p.rx          = pulseRx;
        p.drop_filter = pulseDrop;
        return p;
    endmethod

endmodule : mkPacketIngress

endpackage : PacketIngress
