// Copyright (c) 2025-2026 Yunfan Li
// SPDX-License-Identifier: Apache-2.0

package EtherDefines;

import DefaultValue::*;
import FShow::*;
import GetPut::*;
import ClientServer::*;
import AxisGetPut::*;
import FIFO::*;
import FIFOF::*;
import Connectable::*;

export Cmac_w, Cmac_nbyte, CmacBeat;
export EtherHeader(..), swap_eth_mac;
export IPv4Header(..), ipv4EtherType, swap_ip_addr;
export UdpHeader(..), udpIpProto, swap_udp_port;
export UdpIpEthHeader(..), assert_udpid_hdr;
export IfcEtherFilter(..);
export mkEtherPingbackOthers, NetHeaderSwapOption(..);

typedef 512 Cmac_w;
typedef TDiv#(Cmac_w, 8) Cmac_nbyte;
typedef AxisBeatS#(Cmac_w) CmacBeat;

// Ethernet Frame Header
typedef struct {
    Bit#(16) ethertype;
    Bit#(48) src_mac;
    Bit#(48) dst_mac;
} EtherHeader deriving (Bits, Eq, FShow);

typedef struct {
    Bit#(32) dst_addr;
    Bit#(32) src_addr;
    Bit#(16) checksum;
    Bit#(8)  prot;
    UInt#(8) ttl;
    UInt#(8) frag_ofs_lsb;
    Bit#(3)  flags;
    UInt#(5) frag_ofs_msb;
    Bit#(16) id;
    UInt#(16) total_len;
    Bit#(6)  dscp;
    Bit#(2)  ecn;
    Bit#(4)  version;   // 4 for ipv4
    Bit#(4)  ihl;       // 5 for 20B
} IPv4Header deriving (Bits, Eq, FShow);
Bit#(16) ipv4EtherType = 16'h0008;  // in little-endian

typedef struct {
    Bit#(16) checksum;
    UInt#(16) length;
    Bit#(16) dst_port;
    Bit#(16) src_port;
} UdpHeader deriving (Bits, Eq, FShow);
Bit#(8) udpIpProto = 8'h11;

typedef struct {
    UdpHeader udp;
    IPv4Header ip;
    EtherHeader eth;
} UdpIpEthHeader deriving (Bits, Eq, FShow);

function EtherHeader swap_eth_mac (EtherHeader eth_hdr);
    let smac = eth_hdr.src_mac;
    eth_hdr.src_mac = eth_hdr.dst_mac;
    eth_hdr.dst_mac = smac;
    return eth_hdr;
endfunction

function IPv4Header swap_ip_addr (IPv4Header ip_hdr);
    let srcip = ip_hdr.src_addr;
    ip_hdr.src_addr = ip_hdr.dst_addr;
    ip_hdr.dst_addr = srcip;
    return ip_hdr;
endfunction

function UdpHeader swap_udp_port (UdpHeader udp_hdr);
    let srcport = udp_hdr.src_port;
    udp_hdr.src_port = udp_hdr.dst_port;
    udp_hdr.dst_port = srcport;
    return udp_hdr;
endfunction

function Bool assert_udpid_hdr (UdpIpEthHeader hdr);
    return (hdr.eth.ethertype == ipv4EtherType) &&
        (hdr.ip.version == 4) && (hdr.ip.ihl == 5) &&
        (hdr.ip.prot == udpIpProto);
endfunction

instance DefaultValue#(EtherHeader);
    defaultValue = unpack('0);
endinstance

instance DefaultValue#(UdpHeader);
    defaultValue = unpack('0);
endinstance

function IPv4Header getDefaultValueOfIpv4Header ();
    IPv4Header hdr = unpack('0);
    hdr.version = 4;
    hdr.ihl = 5;
    return hdr;
endfunction

instance DefaultValue#(IPv4Header);
    defaultValue = getDefaultValueOfIpv4Header();
endinstance

function UdpIpEthHeader getDefaultValueOfUdpIpEthHeader ();
    UdpIpEthHeader hdr = unpack('0);
    hdr.eth = defaultValue;
    hdr.eth.ethertype = ipv4EtherType;
    hdr.ip = defaultValue;
    hdr.ip.prot = udpIpProto;
    hdr.udp = defaultValue;
    return hdr;
endfunction

instance DefaultValue#(UdpIpEthHeader);
    defaultValue = getDefaultValueOfUdpIpEthHeader();
endinstance

/****** Utility Modules ******/

typedef enum {IDLE, PNGBK, USER} EthSortTgt deriving (Bits, Eq, Bounded, FShow);
typedef enum {ASIS, LEARN, ETH, IP, UDP} NetHeaderSwapOption
    deriving (Bits, Eq, Bounded, FShow);

interface IfcEtherFilter;
    interface Client #(CmacBeat, CmacBeat)  user;
    interface AXI4_Stream_Slave_IFC #(0, 0, Cmac_w, 0)  eth_rx;
    interface AXI4_Stream_Master_IFC #(0, 0, Cmac_w, 0) eth_tx;
endinterface

module mkEtherPingbackOthers #(
    function Bool header_matched (Bit#(Cmac_w) header_beat),
    NetHeaderSwapOption hdr_swp
) (IfcEtherFilter);

    AxisSlaveAdapterS #(Cmac_w) eth_rx_adpt <- mkAxisSlaveAdapterS;
    AxisMasterAdapterS #(Cmac_w) eth_tx_adpt <- mkAxisMasterAdapterS;
    FIFO #(CmacBeat) eth_ibuf <- mkFIFO;
    FIFO #(CmacBeat) eth_obuf <- mkFIFO;
    mkConnection(eth_rx_adpt.dout, toPut(eth_ibuf));
    mkConnection(eth_tx_adpt.din, toGet(eth_obuf));

    FIFO #(CmacBeat) user_rxbuf <- mkFIFO;
    FIFOF #(CmacBeat) user_txbuf <- mkFIFOF;

    Reg #(EthSortTgt) ingress_state <- mkReg(IDLE);
    Reg #(EthSortTgt) egress_state <- mkReg(IDLE);
    Reg #(EtherHeader) src_eth_hdr <- mkRegU;
    Integer eth_hdr_sz = valueOf(SizeOf#(EtherHeader));
    Integer ip_hdr_sz = valueOf(SizeOf#(IPv4Header));
    FIFOF #(CmacBeat) pngbk_buf <- mkFIFOF;

    // Ethernet Ingress
    rule do_sort_eth_in (ingress_state == IDLE);
        let ethb = eth_ibuf.first;
        EtherHeader eth_hdr = unpack(truncate(ethb.data));
        if (header_matched(ethb.data)) begin
            user_rxbuf.enq(ethb);
            eth_ibuf.deq;
            if (!ethb.last) ingress_state <= USER;
        end else ingress_state <= PNGBK;
        src_eth_hdr <= swap_eth_mac(eth_hdr);
    endrule

    (* aggressive_implicit_conditions *)
    rule do_fwd_eth_in (ingress_state != IDLE);
        let ethb <- toGet(eth_ibuf).get;
        if (ingress_state == PNGBK)
            pngbk_buf.enq(ethb);
        else user_rxbuf.enq(ethb);
        if (ethb.last) ingress_state <= IDLE;
    endrule

    // Ethernet Egress
    (* aggressive_implicit_conditions *)
    rule do_arb_eth_out (egress_state == IDLE);
        (* split *)
        if (pngbk_buf.notEmpty)
            egress_state <= PNGBK;
        else if (user_txbuf.notEmpty) begin
            let user_header <- toGet(user_txbuf).get;
            UdpIpEthHeader hdrs = unpack(truncate(user_header.data));
            case (hdr_swp)
                LEARN:
                    user_header.data[eth_hdr_sz-1:0] = pack(src_eth_hdr);
                ETH:
                    user_header.data[eth_hdr_sz-1:0] = pack(swap_eth_mac(hdrs.eth));
                IP:
                    user_header.data[ip_hdr_sz+eth_hdr_sz-1:0] =
                        {pack(swap_ip_addr(hdrs.ip)), pack(swap_ip_addr(hdrs.ip))};
                UDP: begin
                    hdrs.eth = swap_eth_mac(hdrs.eth);
                    hdrs.ip = swap_ip_addr(hdrs.ip);
                    hdrs.udp = swap_udp_port(hdrs.udp);
                    hdrs.udp.checksum = 16'h0;
                    user_header.data[valueOf(SizeOf#(UdpIpEthHeader))-1:0] = pack(hdrs);
                end
                default: noAction;
            endcase
            eth_obuf.enq(user_header);
            if (user_header.last != True) egress_state <= USER;
        end
    endrule

    (* aggressive_implicit_conditions *)
    rule do_fwd_eth_out (egress_state != IDLE);
        CmacBeat ethb;
        if (egress_state == PNGBK)
            ethb <- toGet(pngbk_buf).get;
        else ethb <- toGet(user_txbuf).get;
        eth_obuf.enq(ethb);
        if (ethb.last == True) egress_state <= IDLE;
    endrule

    interface AXI4_Stream_Slave_IFC eth_rx = eth_rx_adpt.s_axis;
    interface AXI4_Stream_Master_IFC eth_tx = eth_tx_adpt.m_axis;
    interface Client user = toGPClient(user_rxbuf, user_txbuf);

endmodule

endpackage : EtherDefines