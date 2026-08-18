// =============================================================================
// FlowReduceDefines — shared contract for the UDP Vector-Averaging NF.
//
// Every flow_reduce module imports this package. It fixes the type surface so
// that independently-authored submodules interlock: beat types, the cuckoo
// key/value packing, the AXI-Lite register map, the notification ring entry,
// the inter-module counter pulse bus, and the AXI presets reused from the
// kvs_cuckoo libraries.
//
// Endianness convention (see docs/11-bsv-packet-per-beat.md):
//   A 512-bit AXIS beat is little-endian relative to the wire — wire byte k
//   occupies beat.data[k*8+7 : k*8]. BSV `pack` puts a struct's FIRST field in
//   the MSBs, so structs that overlay wire bytes list the network header LAST
//   (already true for UdpIpEthHeader in EtherDefines). The same rule makes the
//   32-byte notify entry come out with the correct C/memory layout when the
//   lowest-address fields are placed LAST in the BSV struct — and it means the
//   raw values parsed from the header need NO byte-swap for the notification
//   (they are already wire-ordered). The egress header splice DOES need a
//   byte-swap (bswap32) because flow_ident / sequence_num are host-native
//   scalars that must land on the wire in network byte order.
// =============================================================================
package FlowReduceDefines;

import DefaultValue::*;
import GetPut::*;
import ClientServer::*;
import Vector::*;

import KvsDefines::*;
import EtherDefines::*;
import AxisGetPut::*;
import Axi4BusesDefines::*;

// ---- Re-exports so a submodule only needs `import FlowReduceDefines::*` ----
export KvsDefines::*;
export EtherDefines::*;
export AxisGetPut::*;
export Axi4BusesDefines::*;
export FlowReduceDefines::*;

// =============================================================================
// AXIS beat types
// =============================================================================
// Internal datapath beats: data/keep/last only (tid/tdest/tuser irrelevant
// once a packet is inside the pipeline).
typedef AxisBeatS#(512)            NfBeat;
// Shell-boundary beats: the QDMA-shell s_axis_rpin / m_axis_rpout carry
// tid[15:0], tdest[15:0], tuser[31:0]. mkPacketIngress / mkResultEgress use the
// `...C` adapters so the packaged IP width-matches the shell stream.
typedef AxisBeatC#(16,16,512,32)   NfBeatC;

typedef AXI4_Stream_Slave_IFC #(16,16,512,32)  NfAxisSlaveIfc;
typedef AXI4_Stream_Master_IFC#(16,16,512,32)  NfAxisMasterIfc;

// 576 B wire packet = 1 header beat (64 B) + 8 vector beats (8*64 = 512 B).
Integer hdrBeatBytes = 64;
Integer vecBeats     = 8;
Integer vecBytes     = 512;
Integer wirePktBytes = 576;
Integer nInflight    = 32;     // N_INFLIGHT (spec §5.2)

// IPv4 total_length / UDP length expected on a conformant packet (spec §4.1).
UInt#(16) expIpTotalLen = 562;
UInt#(16) expUdpLen     = 542;

// =============================================================================
// Flow table key / value  (cuckoo: kw=104, vw=128)  — spec §5.1, §6, §7
// =============================================================================
typedef 104 FlowKey_w;          // 32+32+16+16+8
typedef 128 FlowVal_w;          // 32*4

// Canonical 5-tuple key. Built identically by mkPacketIngress (from the parsed
// header) and mkCtrlRegs (from scratch regs); only the bit pattern needs to be
// consistent between the two, so natural field order is fine.
typedef struct {
    Bit#(32) src_ip;
    Bit#(32) dst_ip;
    Bit#(16) src_port;
    Bit#(16) dst_port;
    Bit#(8)  proto;             // always 17 (UDP)
} FlowKey deriving (Bits, Eq, FShow);

// Cuckoo value: {flow_ident, off_ch0, off_ch2, off_ch4} — spec §6.
// flow_ident -> pack MSBs [127:96], off_ch4 -> LSBs [31:0].
typedef struct {
    Bit#(32) flow_ident;
    Bit#(32) off_ch0;
    Bit#(32) off_ch2;
    Bit#(32) off_ch4;
} FlowVal deriving (Bits, Eq, FShow);

typedef KvsReq #(FlowKey_w, FlowVal_w)  FlowKvsReq;
typedef KvsResp#(FlowVal_w)             FlowKvsResp;

function Bit#(FlowKey_w) packFlowKey (FlowKey k) = pack(k);
function Bit#(FlowVal_w) packFlowVal (FlowVal v) = pack(v);
function FlowVal         unpackFlowVal (Bit#(FlowVal_w) b) = unpack(b);

// Build the key from a parsed wire header (used by mkPacketIngress).
function FlowKey flowKeyFromHeader (UdpIpEthHeader h);
    return FlowKey {
        src_ip:    h.ip.src_addr,
        dst_ip:    h.ip.dst_addr,
        src_port:  h.udp.src_port,
        dst_port:  h.udp.dst_port,
        proto:     h.ip.prot
    };
endfunction

// =============================================================================
// AXI-Lite -> FlowTable command (atomic snapshot on TBL_CMD commit, spec §7)
// =============================================================================
typedef struct {
    Bool             is_delete;   // op: False=upsert, True=delete
    Bit#(FlowKey_w)  key;
    Bit#(FlowVal_w)  val;
} TableCmd deriving (Bits, Eq, FShow);

// =============================================================================
// New-flow notification (spec §8)
// =============================================================================
// Internal descriptor passed mkLookupDispatcher -> mkNotifyEngine.
typedef struct {
    Bit#(32) src_ip;
    Bit#(32) dst_ip;
    Bit#(16) src_port;
    Bit#(16) dst_port;
    Bit#(8)  proto;
    Bit#(64) timestamp_cycles;    // local user-clock cycle count at miss
} NotifyDesc deriving (Bits, Eq, FShow);

// 32-byte wire/memory entry. Lowest-address C fields are placed LAST so that
// `pack` -> AXI wdata gives the correct little-endian-memory C struct layout;
// the parsed src_ip/dst_ip/ports are already wire-ordered so NO swap is needed.
//   C layout: src_ip@0 dst_ip@4 src_port@8 dst_port@10 proto@12 rsv[3]@13
//             timestamp_cycles@16 rsv2@24
typedef struct {
    Bit#(64) rsv2;                // bytes 24..31
    Bit#(64) timestamp_cycles;    // bytes 16..23
    Bit#(24) rsv;                 // bytes 13..15
    Bit#(8)  proto;               // byte  12
    Bit#(16) dst_port;            // bytes 10..11
    Bit#(16) src_port;            // bytes 8..9
    Bit#(32) dst_ip;              // bytes 4..7
    Bit#(32) src_ip;              // bytes 0..3
} NotifyEntry deriving (Bits, Eq, FShow);   // == 256 bits == 32 B

function NotifyEntry toNotifyEntry (NotifyDesc d);
    return NotifyEntry {
        rsv2: 0, timestamp_cycles: d.timestamp_cycles, rsv: 0,
        proto: d.proto, dst_port: d.dst_port, src_port: d.src_port,
        dst_ip: d.dst_ip, src_ip: d.src_ip
    };
endfunction

Integer notifyEntryBytes = 32;

// Ring geometry pushed from mkCtrlRegs to mkNotifyEngine.
typedef struct {
    Bit#(64) base;        // {NOTIFY_BASE_HI, NOTIFY_BASE_LO}
    Bit#(5)  size_log2;   // ring length = 2^size_log2 entries
    Bit#(32) tail;        // host-maintained read index (NOTIFY_TAIL)
} NotifyCfg deriving (Bits, Eq, FShow);

instance DefaultValue#(NotifyCfg);
    defaultValue = NotifyCfg { base: 0, size_log2: 0, tail: 0 };
endinstance

// =============================================================================
// AXI presets (reused verbatim from Axi4BusesDefines — tested in kvs_cuckoo)
// =============================================================================
// HBM read masters: HbmAxiMasterIfc / HbmTlmReq_t / HbmTlmResp_t /
//   HbmTlmReqDesc_t  (6,33,512,8,0).  Built with mkAxi4MasterFromFifoPair.
// Notification master: the XDMA-bypass preset is exactly 4,64,512,8,0 (64-bit
//   host address) — reuse it rather than minting a new preset.
typedef XdmaBypAxiMasterIfc     NotifyAxiMasterIfc;
typedef XdmaBypTlmReq_t         NotifyTlmReq_t;
typedef XdmaBypTlmResp_t        NotifyTlmResp_t;
typedef XdmaBypTlmReqDesc_t     NotifyTlmReqDesc_t;

// AXI-Lite slave preset for mkCtrlRegs (matches PrstKvsAxilCfg AXIL_TLM_PRMS).
//   params: id=1, addr=32, data=32, len=1, user=0
`define FR_AXIL_PRMS  1, 32, 32, 1, 0

// HBM burst: a 512 B vector is exactly one length-8, size-64B burst (spec §4.2).
Integer hbmBurstBeats = 8;      // AXI ARLEN field = hbmBurstBeats - 1

// =============================================================================
// Inter-module counter pulse bus (spec §7 CNT_*).  One-hot-ish: any subset of
// pulses may be asserted in a cycle; mkCtrlRegs sums them into ConfigRegs.
// =============================================================================
typedef struct {
    Bool rx;            // CNT_RX           — ingress packets seen
    Bool drop_filter;   // CNT_DROP_FILTER  — dropped on header filter
    Bool hit;           // CNT_HIT          — flow-table hits
    Bool miss;          // CNT_MISS         — flow-table misses
    Bool processed;     // CNT_PROCESSED    — result packets emitted
    Bool hbm_err;       // CNT_HBM_ERR      — HBM RRESP != OKAY
    Bool notify_drop;   // CNT_NOTIFY_DROP  — notifications dropped (ring full)
    Bool tbl_q_drop;    // CNT_TBL_Q_DROP   — table commands dropped (FIFO full)
} CntPulse deriving (Bits, Eq, FShow);

instance DefaultValue#(CntPulse);
    defaultValue = CntPulse {
        rx: False, drop_filter: False, hit: False, miss: False,
        processed: False, hbm_err: False, notify_drop: False,
        tbl_q_drop: False
    };
endinstance

// =============================================================================
// AXI-Lite register map (spec §7).  Byte offsets; CtrlRegs decodes addr[31:2].
// =============================================================================
Bit#(32) regCTRL            = 32'h00;
Bit#(32) regSTATUS          = 32'h04;
Bit#(32) regTBL_KEY_0       = 32'h10;   // src_ip
Bit#(32) regTBL_KEY_1       = 32'h14;   // dst_ip
Bit#(32) regTBL_KEY_2       = 32'h18;   // {src_port, dst_port}
Bit#(32) regTBL_KEY_3       = 32'h1C;   // {proto, rsv[23:0]}
Bit#(32) regTBL_VAL_CH0     = 32'h20;
Bit#(32) regTBL_VAL_CH2     = 32'h24;
Bit#(32) regTBL_VAL_CH4     = 32'h28;
Bit#(32) regTBL_VAL_FLOW_ID = 32'h2C;
Bit#(32) regTBL_CMD         = 32'h30;   // [1:0]=op, [31]=commit (W1SC)
Bit#(32) regNOTIFY_BASE_LO  = 32'h40;
Bit#(32) regNOTIFY_BASE_HI  = 32'h44;
Bit#(32) regNOTIFY_SIZE_LOG2= 32'h48;
Bit#(32) regNOTIFY_HEAD     = 32'h4C;   // RO
Bit#(32) regNOTIFY_TAIL     = 32'h50;
Bit#(32) regCNT_RX          = 32'h80;   // RO
Bit#(32) regCNT_DROP_FILTER = 32'h84;   // RO
Bit#(32) regCNT_HIT         = 32'h88;   // RO
Bit#(32) regCNT_MISS        = 32'h8C;   // RO
Bit#(32) regCNT_PROCESSED   = 32'h90;   // RO
Bit#(32) regCNT_HBM_ERR     = 32'h94;   // RO
Bit#(32) regCNT_NOTIFY_DROP = 32'h98;   // RO
Bit#(32) regCNT_TBL_Q_DROP  = 32'h9C;   // RO

Integer tblCmdQDepth = 16;              // table-command FIFO depth (spec §7)

// =============================================================================
// Byte-swap helpers (host-native scalar -> network byte order on the wire).
// =============================================================================
function Bit#(32) bswap32 (Bit#(32) x) =
    { x[7:0], x[15:8], x[23:16], x[31:24] };

function Bit#(16) bswap16 (Bit#(16) x) =
    { x[7:0], x[15:8] };

// =============================================================================
// Inter-module interface contract.  Each mk<Name> module (authored in its own
// package, importing this one) implements exactly its Ifc<Name>.  Declaring
// them centrally guarantees the independently-written modules interlock; the
// Phase-3 top (mkVectorAvgNF) imports all and wires them with mkConnection /
// mkBufGPConnection.  Beat-stream conventions:
//   * One header beat per accepted packet; 8 payload/vector beats per packet
//     with `last` set on the 8th.
//   * Counter pulses: every module exposes `cntPulse` (combinational, the
//     pulses asserted this cycle); the top ORs them into mkCtrlRegs.cnt_in.
// =============================================================================

interface IfcPacketIngress;
    interface NfAxisSlaveIfc            s_axis;          // <- shell s_axis_rpin
    interface Get#(NfBeat)             hdr_out;          // 1 hdr beat / acc pkt
    interface Get#(NfBeat)             payload_out;      // 8 beats / acc pkt
    interface Get#(Bit#(FlowKey_w))    lookup_key_out;   // 1 / acc pkt
    interface Get#(FlowKey)            key_echo_out;     // 1 / acc pkt (for miss)
    (* always_ready *) method Action   set_enable (Bool en);   // CTRL[0]
    (* always_ready *) method CntPulse cntPulse;         // rx, drop_filter
endinterface

interface IfcFlowTable;
    interface Put#(Bit#(FlowKey_w))    lookup_req;
    interface Get#(FlowKvsResp)        lookup_resp;      // Found / Fail only
    (* always_ready *) method Action   enq_cmd (TableCmd c);    // on commit; self-drops if full
    (* always_ready *) method Bool     cmd_full;         // -> STATUS.tbl_q_full
    (* always_ready *) method CntPulse cntPulse;         // tbl_q_drop
endinterface

interface IfcLookupDispatcher;
    interface Put#(NfBeat)             hdr_in;
    interface Put#(NfBeat)             payload_in;
    interface Put#(FlowKvsResp)        lookup_resp_in;
    interface Put#(FlowKey)            key_echo_in;
    interface Get#(NfBeat)             hdr_post;         // -> egress
    interface Get#(NfBeat)             payload_post;     // -> averager payload
    interface Get#(Bit#(32))           flowident_post;   // -> egress (1 / hit)
    interface Get#(Bit#(33))           hbm_cmd0;         // chan-local 512B-aligned addr
    interface Get#(Bit#(33))           hbm_cmd2;
    interface Get#(Bit#(33))           hbm_cmd4;
    interface Get#(NotifyDesc)         notify_out;       // -> notify (1 / miss)
    (* always_ready *) method CntPulse cntPulse;         // hit, miss
endinterface

interface IfcHBMReadEngine;
    interface Put#(Bit#(33))           cmd_ch0;          // issues one len-8 burst
    interface Put#(Bit#(33))           cmd_ch2;
    interface Put#(Bit#(33))           cmd_ch4;
    interface Get#(NfBeat)             data_ch0;         // 8 beats / burst
    interface Get#(NfBeat)             data_ch2;
    interface Get#(NfBeat)             data_ch4;
    interface Get#(Bool)               err_ch0;          // 1 / burst; True=RRESP!=OKAY
    interface Get#(Bool)               err_ch2;
    interface Get#(Bool)               err_ch4;
    interface Vector#(3, HbmAxiMasterIfc) hbm_axi;       // -> shell HBM ch0,2,4
endinterface

interface IfcFourWayAverager;
    interface Put#(NfBeat)             payload_in;       // 8 beats / pkt
    interface Put#(NfBeat)             v0_in;
    interface Put#(NfBeat)             v2_in;
    interface Put#(NfBeat)             v4_in;
    interface Get#(NfBeat)             avg_out;          // 8 beats / pkt
endinterface

interface IfcResultEgress;
    interface Put#(NfBeat)             hdr_in;
    interface Put#(Bit#(32))           flowident_in;
    interface Put#(NfBeat)             avg_in;           // 8 beats / pkt
    interface NfAxisMasterIfc          m_axis;           // -> shell m_axis_rpout
    (* always_ready *) method CntPulse cntPulse;         // processed
endinterface

interface IfcNotifyEngine;
    interface Put#(NotifyDesc)         notify_in;
    (* always_ready *) method Action   set_cfg (NotifyCfg c);
    (* always_ready *) method Bit#(32) head;             // -> NOTIFY_HEAD (RO)
    (* always_ready *) method Bool     ring_full;        // -> STATUS bit
    interface NotifyAxiMasterIfc       m_axibr;          // -> shell m_axibr
    (* always_ready *) method CntPulse cntPulse;         // notify_drop
endinterface

interface IfcCtrlRegs;
    interface Axi4LRdWrSlave #(`FR_AXIL_PRMS) s_axil;    // host MMIO
    (* always_ready *) method Bool             enable;   // CTRL[0] -> ingress
    (* always_ready *) method Maybe#(TableCmd) commit_cmd; // 1-cyc valid on commit
    (* always_ready, always_enabled *) method Action cnt_in (CntPulse p);
    (* always_ready *) method NotifyCfg        notify_cfg;
    (* always_ready, always_enabled *) method Action notify_head_in (Bit#(32) h);
    (* always_ready, always_enabled *) method Action status_in (Bool tbl_q_full,
                                                                Bool notify_ring_full);
endinterface

// Top-level shell-facing interface (implemented by mkVectorAvgNF, Phase 3).
interface IfcVectorAvgNF;
    interface NfAxisSlaveIfc                    s_axis_rpin;
    interface NfAxisMasterIfc                   m_axis_rpout;
    interface Axi4LRdWrSlave #(`FR_AXIL_PRMS)   s_axil;
    interface Vector#(3, HbmAxiMasterIfc)       hbm_axi;     // ch0, ch2, ch4
    interface NotifyAxiMasterIfc                m_axibr;
endinterface

endpackage : FlowReduceDefines
