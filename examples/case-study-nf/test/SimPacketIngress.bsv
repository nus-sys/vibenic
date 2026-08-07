// =============================================================================
// SimPacketIngress — Bluesim smoke testbench for mkPacketIngress.
//
// Drives the DUT's shell-facing s_axis via a mkAxisMasterAdapterC#(16,16,512,32)
// connected with mkConnection, and exercises three scenarios:
//
//   (a) one well-formed 9-beat UDP/IPv4 packet
//          -> 1 hdr beat, 8 payload beats, 1 lookup key, 1 echoed key,
//             cntPulse.rx seen, cntPulse.drop_filter NOT seen
//   (b) a non-UDP packet (wrong ethertype) -> filtered drop
//          -> drop_filter pulse, no hdr/payload/key, FSM drains and recovers
//   (c) a too-short packet (tlast on the 5th beat) -> filtered drop + DRAIN
//          -> drop_filter pulse, no hdr/payload/key; the FSM returns to IDLE
//             and a subsequent good packet (a repeat of (a)) still works.
//
// All output streams are drained by always-firing collector rules into
// accumulator Regs; the StmtFSM checks the accumulators after each phase and
// prints PASS/FAIL then $finish(0/1).
// =============================================================================
package SimPacketIngress;

import StmtFSM::*;
import FIFO::*;
import GetPut::*;
import ClientServer::*;
import Connectable::*;
import DefaultValue::*;
import Vector::*;

import FlowReduceDefines::*;   // shared types, NfBeatC, adapters
import PacketIngress::*;       // DUT

(* synthesize *)
module mkSimPacketIngress ();

    let dut <- mkPacketIngress;

    // Test driver: an AXIS master whose m_axis feeds the DUT's s_axis slave.
    AxisMasterAdapterC#(16,16,512,32) drv <- mkAxisMasterAdapterC;
    mkConnection(drv.m_axis, dut.s_axis);

    // ---- Output accumulators ------------------------------------------------
    Reg#(UInt#(32)) hdrCnt   <- mkReg(0);
    Reg#(UInt#(32)) payCnt   <- mkReg(0);
    Reg#(UInt#(32)) keyCnt   <- mkReg(0);
    Reg#(UInt#(32)) echoCnt  <- mkReg(0);
    Reg#(UInt#(32)) rxCnt    <- mkReg(0);
    Reg#(UInt#(32)) dropCnt  <- mkReg(0);
    Reg#(Bit#(FlowKey_w)) lastKey  <- mkReg(0);
    Reg#(FlowKey)         lastEcho <- mkReg(unpack(0));

    // Collector rules: drain every DUT output so it never back-pressures.
    rule c_hdr;
        let b <- dut.hdr_out.get;
        hdrCnt <= hdrCnt + 1;
    endrule
    rule c_pay;
        let b <- dut.payload_out.get;
        payCnt <= payCnt + 1;
    endrule
    rule c_key;
        let k <- dut.lookup_key_out.get;
        keyCnt  <= keyCnt + 1;
        lastKey <= k;
    endrule
    rule c_echo;
        let k <- dut.key_echo_out.get;
        echoCnt  <= echoCnt + 1;
        lastEcho <= k;
    endrule

    // cntPulse is combinational; sample it every cycle and accumulate.
    (* fire_when_enabled, no_implicit_conditions *)
    rule c_cnt;
        let p = dut.cntPulse;
        if (p.rx)          rxCnt   <= rxCnt   + 1;
        if (p.drop_filter) dropCnt <= dropCnt + 1;
    endrule

    // ---- Packet builders ----------------------------------------------------
    // Reference 5-tuple used by the good packets.
    Bit#(32) srcIp  = 32'h0A000001;
    Bit#(32) dstIp  = 32'h0A000002;
    Bit#(16) srcPrt = 16'h1234;
    Bit#(16) dstPrt = 16'h5678;

    function UdpIpEthHeader goodHdr ();
        UdpIpEthHeader h = defaultValue;   // ethertype=ipv4, ver=4, ihl=5, prot=udp
        h.eth.dst_mac     = 48'h001122334455;
        h.eth.src_mac     = 48'h0066778899AA;
        // total_length is big-endian on the wire; the header struct reads
        // multibyte fields byte-swapped, so a real 562-B packet has
        // struct total_len == bswap16(562) (matches the numpy golden /
        // mkPacketIngress's corrected wire-length filter).
        h.ip.total_len    = unpack(bswap16(pack(expIpTotalLen)));
        h.ip.src_addr     = srcIp;
        h.ip.dst_addr     = dstIp;
        h.udp.src_port    = srcPrt;
        h.udp.dst_port    = dstPrt;
        h.udp.length      = expUdpLen;      // 542
        return h;
    endfunction

    // 64 B header beat: header struct packed into the LOW bytes (wire byte k at
    // data[k*8+7:k*8]); the client shim / timestamp region above is don't-care.
    function NfBeatC hdrBeat (UdpIpEthHeader h, Bool lst);
        Bit#(512) d = 0;
        d[valueOf(SizeOf#(UdpIpEthHeader))-1:0] = pack(h);
        return NfBeatC { data: d, keep: '1, last: lst, id: 0, dest: 0, user_data: 0 };
    endfunction

    function NfBeatC bodyBeat (Bit#(8) fill, Bool lst);
        // Body content is irrelevant to this smoke test (only beat counts are
        // checked); replicate `fill` across all 64 byte lanes for readability.
        Vector#(64, Bit#(8)) bytes = replicate(fill);
        return NfBeatC { data: pack(bytes), keep: '1, last: lst,
                         id: 0, dest: 0, user_data: 0 };
    endfunction

    // Drive a full conformant 9-beat packet (header + 8 body, tlast on 9th).
    function Stmt sendGoodPkt =
        seq
            drv.din.put(hdrBeat(goodHdr(), False));
            drv.din.put(bodyBeat(8'h01, False));
            drv.din.put(bodyBeat(8'h02, False));
            drv.din.put(bodyBeat(8'h03, False));
            drv.din.put(bodyBeat(8'h04, False));
            drv.din.put(bodyBeat(8'h05, False));
            drv.din.put(bodyBeat(8'h06, False));
            drv.din.put(bodyBeat(8'h07, False));
            drv.din.put(bodyBeat(8'h08, True));   // 9th beat = tlast
        endseq;

    Reg#(Bool) ok <- mkReg(True);

    function Action chk (Bool cond, String msg);
        action
            if (!cond) begin
                $display("FAIL: %s", msg);
                ok <= False;
            end
        endaction
    endfunction

    // ---- Test sequence ------------------------------------------------------
    Stmt test = seq
        dut.set_enable(True);

        // ---- (a) well-formed packet ----
        $display("[TB] Phase A: well-formed UDP/IPv4 packet");
        sendGoodPkt;
        delay(40);
        chk(hdrCnt  == 1, "A: expected 1 header beat");
        chk(payCnt  == 8, "A: expected 8 payload beats");
        chk(keyCnt  == 1, "A: expected 1 lookup key");
        chk(echoCnt == 1, "A: expected 1 key echo");
        chk(rxCnt   == 1, "A: expected 1 rx pulse");
        chk(dropCnt == 0, "A: unexpected drop_filter pulse");
        chk(lastKey == packFlowKey(flowKeyFromHeader(goodHdr())),
               "A: lookup key mismatch");
        chk(lastEcho == flowKeyFromHeader(goodHdr()),
               "A: key echo mismatch");

        // ---- (b) non-UDP packet (wrong ethertype) ----
        $display("[TB] Phase B: non-UDP packet (bad ethertype)");
        action
            UdpIpEthHeader h = goodHdr();
            h.eth.ethertype = 16'hDDEE;   // not IPv4
            drv.din.put(hdrBeat(h, False));
        endaction
        drv.din.put(bodyBeat(8'hAA, False));
        drv.din.put(bodyBeat(8'hAA, False));
        drv.din.put(bodyBeat(8'hAA, False));
        drv.din.put(bodyBeat(8'hAA, False));
        drv.din.put(bodyBeat(8'hAA, False));
        drv.din.put(bodyBeat(8'hAA, False));
        drv.din.put(bodyBeat(8'hAA, False));
        drv.din.put(bodyBeat(8'hAA, True));
        delay(40);
        chk(hdrCnt  == 1, "B: header count must stay 1 (packet dropped)");
        chk(payCnt  == 8, "B: payload count must stay 8 (packet dropped)");
        chk(keyCnt  == 1, "B: key count must stay 1 (packet dropped)");
        chk(echoCnt == 1, "B: echo count must stay 1 (packet dropped)");
        chk(rxCnt   == 2, "B: expected 2 rx pulses cumulative");
        chk(dropCnt == 1, "B: expected 1 drop_filter pulse");

        // ---- (c) too-short bad-header packet (tlast on 5th beat) then good ----
        // Header fails the filter (bad ethertype) AND the frame is truncated
        // at beat 5: do_rx_init rejects -> DRAIN (frame is multi-beat); the
        // DRAIN state then swallows beats 2..5 and returns to IDLE on the early
        // tlast. This directly exercises drop + DRAIN of a short frame.
        $display("[TB] Phase C: too-short bad-header packet, then recovery");
        action
            UdpIpEthHeader h = goodHdr();
            h.eth.ethertype = 16'hBEEF;   // not IPv4 -> rejected at parse
            drv.din.put(hdrBeat(h, False));
        endaction
        drv.din.put(bodyBeat(8'hBB, False));
        drv.din.put(bodyBeat(8'hBB, False));
        drv.din.put(bodyBeat(8'hBB, False));
        drv.din.put(bodyBeat(8'hBB, True));       // tlast on 5th beat -> short
        delay(40);
        // Rejected at parse -> nothing enqueued, drop pulsed, FSM drains the
        // remaining beats and returns to IDLE.
        chk(rxCnt   == 3, "C: expected 3 rx pulses cumulative");
        chk(dropCnt == 2, "C: expected 2 drop_filter pulses cumulative");
        chk(hdrCnt  == 1, "C: header count must stay 1 (short pkt dropped)");
        chk(payCnt  == 8, "C: payload count must stay 8 (short pkt dropped)");
        chk(keyCnt  == 1, "C: key count must stay 1 (short pkt dropped)");

        // Now a clean good packet must still flow end to end (FSM recovered).
        sendGoodPkt;
        delay(60);
        chk(rxCnt   == 4, "C: expected 4 rx pulses cumulative after recovery");
        chk(dropCnt == 2, "C: drop count must stay 2 after good recovery pkt");
        chk(hdrCnt  == 2, "C: expected 2 total header beats after recovery");
        chk(keyCnt  == 2, "C: expected 2 total keys after recovery");
        chk(echoCnt == 2, "C: expected 2 total echoes after recovery");
        // Two accepted full packets (A and the recovery one) => 16 payload.
        chk(payCnt  == 16, "C: expected 16 total payload beats");

        action
            if (ok) begin
                $display("PASS: all PacketIngress smoke checks passed");
                $finish(0);
            end
            else begin
                $display("FAIL: one or more PacketIngress checks failed");
                $finish(1);
            end
        endaction
    endseq;

    mkAutoFSM(test);

endmodule : mkSimPacketIngress

endpackage : SimPacketIngress
