// =============================================================================
// SimCtrlRegs — Bluesim testbench for mkCtrlRegs (spec §7 control plane).
//
// Drives the DUT s_axil with an AXI-Lite master transactor built exactly as
// mds-fpga/kvs_cuckoo test/SimTop.bsv mkSimAxilCfg does:
//   Axi4LRdWrMasterXActorIFC#(...) <- mkAxi4LRdWrMaster(id, False);
//   mkConnection(xatr.read.bus,  dut.s_axil.read);
//   mkConnection(xatr.write.bus, dut.s_axil.write);
//   requests pushed via xatr.tlm.rx.put(tagged Descriptor d);
//   responses drained via xatr.tlm.tx.get.
//
// The slave returns exactly one TLMResponse per request in order, so a tiny
// request/response handshake (issue, then block until the response FIFO has
// the word) gives a clean blocking read/write API for a StmtFSM program. A
// free-running cycle counter arms a timeout guard so a stuck AXI-Lite
// transaction fails the run instead of hanging Bluesim.
//
// Coverage (test plan §3.5 + task spec):
//   1. write then read-back every RW register;
//   2. RO counter: read, pulse cnt_in for K cycles, read again -> +K;
//   3. TBL_CMD commit op=0 -> commit_cmd Valid exactly one cycle, packed
//      key/val correct, is_delete False; op=1 -> is_delete True;
//   4. writing TBL_CMD leaves no commit/soft_reset bit set on read-back;
//   5. status_in / notify_head_in reflected in STATUS / NOTIFY_HEAD reads.
// =============================================================================
package SimCtrlRegs;

import GetPut::*;
import FIFO::*;
import Connectable::*;
import StmtFSM::*;
import DefaultValue::*;
import TLM3::*;
import Axi4::*;

import FlowReduceDefines::*;
import CtrlRegs::*;

`define FR_AXIL_PRMS  1, 32, 32, 1, 0
`define FR_AXIL_TLM_RR \
    TLMRequest#(`FR_AXIL_PRMS), TLMResponse#(`FR_AXIL_PRMS)
`define FR_AXIL_XATR_PRMS  `FR_AXIL_TLM_RR, `FR_AXIL_PRMS

(* synthesize *)
module mkSimCtrlRegs ();

    IfcCtrlRegs dut <- mkCtrlRegs;

    Axi4LRdWrMasterXActorIFC#(`FR_AXIL_XATR_PRMS)
        mst <- mkAxi4LRdWrMaster(1, False);
    mkConnection(mst.read.bus,  dut.s_axil.read);
    mkConnection(mst.write.bus, dut.s_axil.write);

    // Free-running cycle counter + global timeout guard.
    Reg#(Bit#(32)) cyc      <- mkReg(0);
    rule do_tick; cyc <= cyc + 1; endrule
    rule do_timeout (cyc > 20000);
        $display("FAIL: global timeout at cycle %0d", cyc);
        $finish(1);
    endrule

    // Captured last read word + a response-pending handshake.
    Reg#(Bit#(32)) rd_data    <- mkReg(0);
    Reg#(Bool)     resp_seen  <- mkReg(False);

    rule do_collect_resp;
        let r <- mst.tlm.tx.get;
        rd_data   <= r.data;
        resp_seen <= True;
    endrule

    // Capture commit_cmd every cycle: how many Valid cycles, and the last one.
    Reg#(Bit#(32))     commit_valid_cnt <- mkReg(0);
    Reg#(TableCmd)     last_commit      <- mkReg(unpack(0));
    rule do_watch_commit;
        if (dut.commit_cmd matches tagged Valid .c) begin
            commit_valid_cnt <= commit_valid_cnt + 1;
            last_commit      <= c;
        end
    endrule

    // status_in / notify_head_in stimulus (always_enabled ports).
    Reg#(Bool)     st_tblqf  <- mkReg(False);
    Reg#(Bool)     st_rfull  <- mkReg(False);
    Reg#(Bit#(32)) nh_val    <- mkReg(0);
    (* fire_when_enabled, no_implicit_conditions *)
    rule do_drive_status;
        dut.status_in(st_tblqf, st_rfull);
        dut.notify_head_in(nh_val);
    endrule

    // cnt_in stimulus (always_enabled). While cnt_arm is set, drive p.rx and
    // count exactly how many pulses we injected so the check is deterministic
    // regardless of StmtFSM/rule cycle alignment.
    Reg#(Bool)     cnt_arm      <- mkReg(False);
    Reg#(Bit#(32)) cnt_injected <- mkReg(0);   // monotone: only the rule writes
    (* fire_when_enabled, no_implicit_conditions *)
    rule do_drive_cnt;
        CntPulse p = defaultValue;
        p.rx = cnt_arm;
        dut.cnt_in(p);
        if (cnt_arm) cnt_injected <= cnt_injected + 1;
    endrule

    Reg#(Bit#(32)) fails <- mkReg(0);

    function Action chk (Bool ok, String msg);
        action
            if (!ok) begin
                fails <= fails + 1;
                $display("FAIL: %s", msg);
            end else
                $display("  ok: %s", msg);
        endaction
    endfunction

    // Blocking AXI-Lite write: issue descriptor, wait for the response.
    function Stmt axi_wr (Bit#(32) addr, Bit#(32) val);
        return seq
            action
                RequestDescriptor#(`FR_AXIL_PRMS) d = defaultValue;
                d.command = WRITE; d.addr = addr; d.data = val;
                resp_seen <= False;
                mst.tlm.rx.put(tagged Descriptor d);
            endaction
            await(resp_seen);
        endseq;
    endfunction

    // Blocking AXI-Lite read: result lands in rd_data.
    function Stmt axi_rd (Bit#(32) addr);
        return seq
            action
                RequestDescriptor#(`FR_AXIL_PRMS) d = defaultValue;
                d.command = READ; d.addr = addr; d.data = 0;
                resp_seen <= False;
                mst.tlm.rx.put(tagged Descriptor d);
            endaction
            await(resp_seen);
        endseq;
    endfunction

    // Reference packed key/val for the commit test.
    Bit#(32) k0 = 32'hC0A8_0101;   // src_ip
    Bit#(32) k1 = 32'h0A00_0002;   // dst_ip
    Bit#(32) k2 = 32'h1F90_2710;   // {src_port=0x1F90, dst_port=0x2710}
    Bit#(32) k3 = 32'h1100_0000;   // {proto=0x11, rsv}
    Bit#(32) vc0 = 32'h1111_1111;
    Bit#(32) vc2 = 32'h2222_2222;
    Bit#(32) vc4 = 32'h3333_3333;
    Bit#(32) vfi = 32'hABCD_0001;

    function Bit#(FlowKey_w) refKey =
        packFlowKey(FlowKey { src_ip:k0, dst_ip:k1,
                              src_port:k2[31:16], dst_port:k2[15:0],
                              proto:k3[31:24] });
    function Bit#(FlowVal_w) refVal =
        packFlowVal(FlowVal { flow_ident:vfi, off_ch0:vc0,
                              off_ch2:vc2, off_ch4:vc4 });

    Reg#(Bit#(32)) base_cnt   <- mkReg(0);
    Reg#(Bit#(32)) base_inj   <- mkReg(0);

    Stmt prog = seq
        $display("==== SimCtrlRegs ====");

        // ---- (1) write then read-back every RW register --------------------
        axi_wr(regCTRL, 32'h1);            // enable=1, soft_reset=0
        axi_rd(regCTRL);
        chk(rd_data == 32'h1, "CTRL readback enable=1");
        chk(dut.enable, "enable method True after CTRL[0]=1");

        axi_wr(regTBL_KEY_0, k0); axi_rd(regTBL_KEY_0);
        chk(rd_data == k0, "TBL_KEY_0 rw");
        axi_wr(regTBL_KEY_1, k1); axi_rd(regTBL_KEY_1);
        chk(rd_data == k1, "TBL_KEY_1 rw");
        axi_wr(regTBL_KEY_2, k2); axi_rd(regTBL_KEY_2);
        chk(rd_data == k2, "TBL_KEY_2 rw");
        axi_wr(regTBL_KEY_3, k3); axi_rd(regTBL_KEY_3);
        chk(rd_data == k3, "TBL_KEY_3 rw");
        axi_wr(regTBL_VAL_CH0, vc0); axi_rd(regTBL_VAL_CH0);
        chk(rd_data == vc0, "TBL_VAL_CH0 rw");
        axi_wr(regTBL_VAL_CH2, vc2); axi_rd(regTBL_VAL_CH2);
        chk(rd_data == vc2, "TBL_VAL_CH2 rw");
        axi_wr(regTBL_VAL_CH4, vc4); axi_rd(regTBL_VAL_CH4);
        chk(rd_data == vc4, "TBL_VAL_CH4 rw");
        axi_wr(regTBL_VAL_FLOW_ID, vfi); axi_rd(regTBL_VAL_FLOW_ID);
        chk(rd_data == vfi, "TBL_VAL_FLOW_ID rw");

        axi_wr(regNOTIFY_BASE_LO, 32'hDEAD_0000); axi_rd(regNOTIFY_BASE_LO);
        chk(rd_data == 32'hDEAD_0000, "NOTIFY_BASE_LO rw");
        axi_wr(regNOTIFY_BASE_HI, 32'h0000_BEEF); axi_rd(regNOTIFY_BASE_HI);
        chk(rd_data == 32'h0000_BEEF, "NOTIFY_BASE_HI rw");
        axi_wr(regNOTIFY_SIZE_LOG2, 32'h0000_000C); axi_rd(regNOTIFY_SIZE_LOG2);
        chk(rd_data == 32'h0000_000C, "NOTIFY_SIZE_LOG2 rw");
        axi_wr(regNOTIFY_TAIL, 32'h0000_0042); axi_rd(regNOTIFY_TAIL);
        chk(rd_data == 32'h0000_0042, "NOTIFY_TAIL rw");
        chk(dut.notify_cfg.base == 64'h0000_BEEF_DEAD_0000,
            "notify_cfg.base = {HI,LO}");
        chk(dut.notify_cfg.size_log2 == 5'h0C, "notify_cfg.size_log2");
        chk(dut.notify_cfg.tail == 32'h42, "notify_cfg.tail");

        // ---- (2) RO counter: read, pulse cnt_in for a window, read -> +K ---
        axi_rd(regCNT_RX);
        action base_cnt <= rd_data; base_inj <= cnt_injected; endaction
        action cnt_arm <= True; endaction
        delay(5);                    // arm window (exact count is measured)
        action cnt_arm <= False; endaction
        delay(2);                    // let the last increment retire
        axi_rd(regCNT_RX);
        chk((rd_data - base_cnt) == (cnt_injected - base_inj),
            "CNT_RX increased by exactly the number of pulses injected");
        chk((cnt_injected - base_inj) > 0, "cnt_in injected >=1 pulse");

        // RO write is ignored.
        axi_wr(regCNT_RX, 32'hFFFF_FFFF);
        axi_rd(regCNT_RX);
        chk((rd_data - base_cnt) == (cnt_injected - base_inj),
            "CNT_RX write ignored (RO)");

        // ---- (3a) TBL_CMD commit op=0 (upsert) -----------------------------
        // Scratch regs already hold k0..k3 / vc0..vc4 / vfi from step (1).
        commit_valid_cnt <= 0;
        axi_wr(regTBL_CMD, 32'h8000_0000);   // commit=1, op=00 (upsert)
        delay(4);
        chk(commit_valid_cnt == 1,
            "commit_cmd Valid exactly 1 cycle (upsert)");
        chk(last_commit.is_delete == False, "upsert is_delete False");
        chk(last_commit.key == refKey, "upsert key packed correctly");
        chk(last_commit.val == refVal, "upsert val packed correctly");

        // ---- (3b) TBL_CMD commit op=1 (delete) -----------------------------
        commit_valid_cnt <= 0;
        axi_wr(regTBL_CMD, 32'h8000_0001);   // commit=1, op=01 (delete)
        delay(4);
        chk(commit_valid_cnt == 1,
            "commit_cmd Valid exactly 1 cycle (delete)");
        chk(last_commit.is_delete == True, "delete is_delete True");
        chk(last_commit.key == refKey, "delete key packed correctly");

        // ---- (4) TBL_CMD / soft_reset leave no W1 bit set ------------------
        axi_rd(regTBL_CMD);
        chk(rd_data == 32'h1, "TBL_CMD readback op=1, commit bit cleared");
        // soft_reset W1SC: write CTRL with bit1=1, must read back 0 (bit0=1).
        axi_wr(regCTRL, 32'h3);              // enable=1, soft_reset=1
        axi_rd(regCTRL);
        chk(rd_data == 32'h1, "CTRL soft_reset self-cleared (reads 0x1)");

        // ---- (5) status_in / notify_head_in -> STATUS / NOTIFY_HEAD --------
        action st_tblqf <= False; st_rfull <= False; endaction
        delay(1);
        axi_rd(regSTATUS);
        chk(rd_data == 32'h1, "STATUS ready=1, others 0");
        action st_tblqf <= True; st_rfull <= True; endaction
        delay(1);
        axi_rd(regSTATUS);
        chk(rd_data == 32'h7, "STATUS ready|tbl_q_full|notify_ring_full");

        action nh_val <= 32'h0000_1234; endaction
        delay(1);
        axi_rd(regNOTIFY_HEAD);
        chk(rd_data == 32'h0000_1234, "NOTIFY_HEAD reflects notify_head_in");
        // NOTIFY_HEAD is RO.
        axi_wr(regNOTIFY_HEAD, 32'hFFFF_FFFF);
        axi_rd(regNOTIFY_HEAD);
        chk(rd_data == 32'h0000_1234, "NOTIFY_HEAD write ignored (RO)");

        // ---- Verdict -------------------------------------------------------
        delay(2);
        action
            if (fails == 0) begin
                $display("PASS: all SimCtrlRegs checks succeeded");
                $finish(0);
            end else begin
                $display("FAIL: %0d check(s) failed", fails);
                $finish(1);
            end
        endaction
    endseq;

    mkAutoFSM(prog);

endmodule : mkSimCtrlRegs

endpackage : SimCtrlRegs
