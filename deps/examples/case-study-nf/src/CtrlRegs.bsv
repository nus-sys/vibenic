// =============================================================================
// CtrlRegs — spec §7 AXI-Lite control/status register block.
//
// Host MMIO front-end for the UDP Vector-Averaging NF. Presents the §7
// register map over a 32-bit AXI-Lite slave and exports the decoded knobs to
// the rest of the design via the IfcCtrlRegs methods.
//
// AXI-Lite slave construction mirrors mds-fpga/kvs_cuckoo PrstKvsAxilCfg.bsv
// EXACTLY: a single Axi4LRdWrSlaveXActorIFC transactor created with
// mkAxi4LRdWrSlave(addr_match); one do_proc_axil rule pops a TLMRequest, builds
// a TLMResponse (defaultValue + command/status/is_last), decodes desc.addr[31:2]
// as a word index, services the read/write against the register file, and puts
// the response back. s_axil re-exposes axil_xatr.read.bus / .write.bus.
//
// Per docs/10-bsv-dataflow-handshaking.md the eight CNT_* counters are mkConfigReg so
// an AXI-Lite read in do_proc_axil does not conflict with the same-cycle
// increment driven combinationally by the always_enabled cnt_in port.
//
// W1-self-clearing semantics (CTRL.soft_reset bit1, TBL_CMD.commit bit31):
// these are never stored set. soft_reset is surfaced for exactly one cycle on
// an internal pulse wire then auto-clears; commit is decoded inside the write
// rule, the TableCmd snapshot is published on a mkDWire#(Maybe#(TableCmd))
// defaulting Invalid, so commit_cmd is tagged Valid for exactly one cycle and
// the persisted CTRL/TBL_CMD register never retains the W1 bit.
// =============================================================================
package CtrlRegs;

import GetPut::*;
import ConfigReg::*;
import Vector::*;
import TLM3::*;
import Axi4::*;
import DefaultValue::*;

import FlowReduceDefines::*;   // shared types + IfcCtrlRegs

// AXI-Lite transactor parameter family. ``define`` macros are file-scoped (not
// package-exported), so re-declare FR_AXIL_PRMS here with the same value used
// by FlowReduceDefines / PrstKvsAxilCfg AXIL_TLM_PRMS (id,addr,data,len,user).
`define FR_AXIL_PRMS  1, 32, 32, 1, 0
`define FR_AXIL_TLM_RR \
    TLMRequest#(`FR_AXIL_PRMS), TLMResponse#(`FR_AXIL_PRMS)
`define FR_AXIL_XATR_PRMS  `FR_AXIL_TLM_RR, `FR_AXIL_PRMS

(* synthesize *)
module mkCtrlRegs (IfcCtrlRegs);

    // Whole §7 map is below 0xA0; accept the full word-aligned 32-bit space
    // (writes to RO offsets are decoded then ignored, reads of holes return 0).
    function Bool axil_addr_match (Bit#(32) addr);
        return True;
    endfunction
    Axi4LRdWrSlaveXActorIFC#(`FR_AXIL_XATR_PRMS)
        axil_xatr <- mkAxi4LRdWrSlave(axil_addr_match);
    let axil_req  = axil_xatr.tlm.tx;
    let axil_resp = axil_xatr.tlm.rx;

    // ---- Register state -----------------------------------------------------
    // CTRL: only bit0 (enable) is persistent; bit1 (soft_reset) is W1SC.
    Reg#(Bool)            ctrl_enable   <- mkReg(False);

    // TBL scratch: KEY_0..3, VAL_CH0/CH2/CH4, VAL_FLOW_ID, plus TBL_CMD.op.
    Reg#(Bit#(32))        tbl_key_0     <- mkReg(0);   // src_ip
    Reg#(Bit#(32))        tbl_key_1     <- mkReg(0);   // dst_ip
    Reg#(Bit#(32))        tbl_key_2     <- mkReg(0);   // {src_port,dst_port}
    Reg#(Bit#(32))        tbl_key_3     <- mkReg(0);   // {proto,rsv}
    Reg#(Bit#(32))        tbl_val_ch0   <- mkReg(0);
    Reg#(Bit#(32))        tbl_val_ch2   <- mkReg(0);
    Reg#(Bit#(32))        tbl_val_ch4   <- mkReg(0);
    Reg#(Bit#(32))        tbl_val_fid   <- mkReg(0);
    Reg#(Bit#(2))         tbl_cmd_op    <- mkReg(0);   // persisted [1:0] of TBL_CMD

    // NOTIFY ring geometry (HEAD is RO, driven from notify_head_in).
    Reg#(Bit#(32))        notify_base_lo  <- mkReg(0);
    Reg#(Bit#(32))        notify_base_hi  <- mkReg(0);
    Reg#(Bit#(32))        notify_size_l2  <- mkReg(0);
    Reg#(Bit#(32))        notify_tail     <- mkReg(0);

    // RO inputs latched combinationally each cycle from always_enabled ports.
    Wire#(Bit#(32))       notify_head_w     <- mkBypassWire;
    Wire#(Bool)           tbl_q_full_w      <- mkBypassWire;
    Wire#(Bool)           notify_rfull_w    <- mkBypassWire;
    Wire#(CntPulse)       cnt_pulse_w       <- mkBypassWire;

    // CNT_* counters. ConfigReg so an AXI-Lite read in do_proc_axil does not
    // conflict with the do_count increment in the same cycle.
    Reg#(Bit#(32)) cnt_rx          <- mkConfigReg(0);
    Reg#(Bit#(32)) cnt_drop_filter <- mkConfigReg(0);
    Reg#(Bit#(32)) cnt_hit         <- mkConfigReg(0);
    Reg#(Bit#(32)) cnt_miss        <- mkConfigReg(0);
    Reg#(Bit#(32)) cnt_processed   <- mkConfigReg(0);
    Reg#(Bit#(32)) cnt_hbm_err     <- mkConfigReg(0);
    Reg#(Bit#(32)) cnt_notify_drop <- mkConfigReg(0);
    Reg#(Bit#(32)) cnt_tbl_q_drop  <- mkConfigReg(0);

    // W1SC commit output: Invalid unless set by the write rule this cycle.
    Wire#(Maybe#(TableCmd)) commit_w   <- mkDWire(tagged Invalid);

    // ---- Counter increment (always-enabled monitor tap) ---------------------
    // Each cycle bump counter i by 1 if its pulse bit is set. ConfigReg makes
    // this safe against a concurrent read.
    (* fire_when_enabled, no_implicit_conditions *)
    rule do_count;
        let p = cnt_pulse_w;
        if (p.rx)          cnt_rx          <= cnt_rx          + 1;
        if (p.drop_filter) cnt_drop_filter <= cnt_drop_filter + 1;
        if (p.hit)         cnt_hit         <= cnt_hit         + 1;
        if (p.miss)        cnt_miss        <= cnt_miss        + 1;
        if (p.processed)   cnt_processed   <= cnt_processed   + 1;
        if (p.hbm_err)     cnt_hbm_err     <= cnt_hbm_err     + 1;
        if (p.notify_drop) cnt_notify_drop <= cnt_notify_drop + 1;
        if (p.tbl_q_drop)  cnt_tbl_q_drop  <= cnt_tbl_q_drop  + 1;
    endrule

    // ---- AXI-Lite servicing rule (mirrors PrstKvsAxilCfg do_proc_axil) ------
    (* aggressive_implicit_conditions *)
    rule do_proc_axil;
        let tlmreq <- axil_req.get;
        if (tlmreq matches tagged Descriptor .desc) begin
            TLMResponse#(`FR_AXIL_PRMS) tlmresp = defaultValue;
            tlmresp.command = desc.command;
            tlmresp.status  = SUCCESS;
            tlmresp.is_last = True;

            // Word index = byte addr[31:2]; only low offsets are used.
            Bit#(32) word = desc.addr & 32'hFFFF_FFFC;   // align to 4

            if (desc.command == WRITE) begin
                let d = desc.data;
                if      (word == regCTRL) begin
                    ctrl_enable <= (d[0] == 1'b1);
                    // d[1] = soft_reset is W1-self-clearing: never persisted,
                    // so it always reads back 0 (no internal observer needed).
                end
                else if (word == regTBL_KEY_0)       tbl_key_0   <= d;
                else if (word == regTBL_KEY_1)       tbl_key_1   <= d;
                else if (word == regTBL_KEY_2)       tbl_key_2   <= d;
                else if (word == regTBL_KEY_3)       tbl_key_3   <= d;
                else if (word == regTBL_VAL_CH0)     tbl_val_ch0 <= d;
                else if (word == regTBL_VAL_CH2)     tbl_val_ch2 <= d;
                else if (word == regTBL_VAL_CH4)     tbl_val_ch4 <= d;
                else if (word == regTBL_VAL_FLOW_ID) tbl_val_fid <= d;
                else if (word == regTBL_CMD) begin
                    tbl_cmd_op <= d[1:0];               // persist op bits only
                    if (d[31] == 1'b1) begin           // commit W1SC
                        FlowKey k = FlowKey {
                            src_ip:   tbl_key_0,
                            dst_ip:   tbl_key_1,
                            src_port: tbl_key_2[31:16],
                            dst_port: tbl_key_2[15:0],
                            proto:    tbl_key_3[31:24] };
                        FlowVal v = FlowVal {
                            flow_ident: tbl_val_fid,
                            off_ch0:    tbl_val_ch0,
                            off_ch2:    tbl_val_ch2,
                            off_ch4:    tbl_val_ch4 };
                        commit_w <= tagged Valid TableCmd {
                            is_delete: (d[1:0] == 2'b01),
                            key:       packFlowKey(k),
                            val:       packFlowVal(v) };
                    end
                end
                else if (word == regNOTIFY_BASE_LO)   notify_base_lo <= d;
                else if (word == regNOTIFY_BASE_HI)   notify_base_hi <= d;
                else if (word == regNOTIFY_SIZE_LOG2) notify_size_l2 <= d;
                else if (word == regNOTIFY_TAIL)      notify_tail    <= d;
                // STATUS, NOTIFY_HEAD, CNT_* and holes: writes ignored (RO).
            end
            else begin   // READ
                Bit#(32) rd = 32'h0;
                if      (word == regCTRL)
                    rd = zeroExtend(pack(ctrl_enable));   // bit0; bit1 reads 0
                else if (word == regSTATUS)
                    rd = { 29'h0,
                           pack(notify_rfull_w),          // [2]
                           pack(tbl_q_full_w),            // [1]
                           1'b1 };                        // [0] ready
                else if (word == regTBL_KEY_0)       rd = tbl_key_0;
                else if (word == regTBL_KEY_1)       rd = tbl_key_1;
                else if (word == regTBL_KEY_2)       rd = tbl_key_2;
                else if (word == regTBL_KEY_3)       rd = tbl_key_3;
                else if (word == regTBL_VAL_CH0)     rd = tbl_val_ch0;
                else if (word == regTBL_VAL_CH2)     rd = tbl_val_ch2;
                else if (word == regTBL_VAL_CH4)     rd = tbl_val_ch4;
                else if (word == regTBL_VAL_FLOW_ID) rd = tbl_val_fid;
                else if (word == regTBL_CMD)
                    rd = zeroExtend(tbl_cmd_op);          // commit reads 0
                else if (word == regNOTIFY_BASE_LO)   rd = notify_base_lo;
                else if (word == regNOTIFY_BASE_HI)   rd = notify_base_hi;
                else if (word == regNOTIFY_SIZE_LOG2) rd = notify_size_l2;
                else if (word == regNOTIFY_HEAD)      rd = notify_head_w;
                else if (word == regNOTIFY_TAIL)      rd = notify_tail;
                else if (word == regCNT_RX)           rd = cnt_rx;
                else if (word == regCNT_DROP_FILTER)  rd = cnt_drop_filter;
                else if (word == regCNT_HIT)          rd = cnt_hit;
                else if (word == regCNT_MISS)         rd = cnt_miss;
                else if (word == regCNT_PROCESSED)    rd = cnt_processed;
                else if (word == regCNT_HBM_ERR)      rd = cnt_hbm_err;
                else if (word == regCNT_NOTIFY_DROP)  rd = cnt_notify_drop;
                else if (word == regCNT_TBL_Q_DROP)   rd = cnt_tbl_q_drop;
                // else: reserved hole reads as zero.
                tlmresp.data = rd;
            end
            axil_resp.put(tlmresp);
        end
        else
            $display("ERROR: unexpected data transaction on AXIL bus.");
    endrule

    // ---- Interface ----------------------------------------------------------
    interface Axi4LRdWrSlave s_axil;
        interface read  = axil_xatr.read.bus;
        interface write = axil_xatr.write.bus;
    endinterface

    method Bool enable = ctrl_enable;

    method Maybe#(TableCmd) commit_cmd = commit_w;

    method Action cnt_in (CntPulse p);
        cnt_pulse_w <= p;
    endmethod

    method NotifyCfg notify_cfg;
        return NotifyCfg {
            base:      { notify_base_hi, notify_base_lo },
            size_log2: notify_size_l2[4:0],
            tail:      notify_tail };
    endmethod

    method Action notify_head_in (Bit#(32) h);
        notify_head_w <= h;
    endmethod

    method Action status_in (Bool tbl_q_full, Bool notify_ring_full);
        tbl_q_full_w   <= tbl_q_full;
        notify_rfull_w <= notify_ring_full;
    endmethod

endmodule : mkCtrlRegs

endpackage : CtrlRegs
