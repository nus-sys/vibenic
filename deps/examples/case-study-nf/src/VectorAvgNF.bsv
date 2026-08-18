// =============================================================================
// VectorAvgNF — top of the UDP Vector-Averaging NF (spec §6).
//
// Wires the eight submodules into the straight producer/consumer chain and
// owns the HBM-RRESP error-drain coordination (spec §5.3): the per-packet
// error verdict (OR of the three channels' err tokens) gates whether a hit
// packet's header/flow_ident/averaged-vector reach the egress or are dropped
// (with CNT_HBM_ERR pulsed) — kept as one atomic per-packet decision here
// because this level owns all the post-dispatch endpoints.
//
//   ingress ─key→ flowtable ─resp→ dispatcher
//   ingress ─hdr/payload/keyecho→ dispatcher
//   dispatcher ─hbmcmd0/2/4→ hbmread ─data0/2/4→ averager ←payload─ dispatcher
//   {dispatcher.hdr_post, dispatcher.flowident_post, averager.avg_out}
//       ── error-gate ──→ egress ──→ m_axis_rpout
//   dispatcher ─notify→ notifyengine ──→ m_axibr
//   ctrlregs ↔ {flowtable cmd/full, notify cfg/head/full}, enable, counters
// =============================================================================
package VectorAvgNF;

import GetPut::*;
import ClientServer::*;
import Connectable::*;
import Vector::*;
import DefaultValue::*;

import FlowReduceDefines::*;
import PacketIngress::*;
import FlowTable::*;
import LookupDispatcher::*;
import HBMReadEngine::*;
import FourWayAverager::*;
import ResultEgress::*;
import NotifyEngine::*;
import CtrlRegs::*;

// Field-wise OR of two counter-pulse buses.
function CntPulse cpOr (CntPulse a, CntPulse b);
    return CntPulse {
        rx:          a.rx          || b.rx,
        drop_filter: a.drop_filter || b.drop_filter,
        hit:         a.hit         || b.hit,
        miss:        a.miss        || b.miss,
        processed:   a.processed   || b.processed,
        hbm_err:     a.hbm_err     || b.hbm_err,
        notify_drop: a.notify_drop || b.notify_drop,
        tbl_q_drop:  a.tbl_q_drop  || b.tbl_q_drop
    };
endfunction

typedef enum { G_IDLE, G_FWD, G_DROP } GateState deriving (Bits, Eq, FShow);

(* synthesize *)
module mkVectorAvgNF (IfcVectorAvgNF);

    IfcPacketIngress    ingress <- mkPacketIngress;
    IfcFlowTable        ft      <- mkFlowTable;
    IfcLookupDispatcher disp    <- mkLookupDispatcher;
    IfcHBMReadEngine    hbm     <- mkHBMReadEngine;
    IfcFourWayAverager  avg     <- mkFourWayAverager;
    IfcResultEgress     egr     <- mkResultEgress;
    IfcNotifyEngine     ntf     <- mkNotifyEngine;
    IfcCtrlRegs         ctrl    <- mkCtrlRegs;

    // ---- straight dataflow connections (Get -> Put) -------------------------
    mkConnection(ingress.lookup_key_out, ft.lookup_req);
    mkConnection(ingress.hdr_out,        disp.hdr_in);
    mkConnection(ingress.payload_out,    disp.payload_in);
    mkConnection(ingress.key_echo_out,   disp.key_echo_in);
    mkConnection(ft.lookup_resp,         disp.lookup_resp_in);

    mkConnection(disp.hbm_cmd0, hbm.cmd_ch0);
    mkConnection(disp.hbm_cmd2, hbm.cmd_ch2);
    mkConnection(disp.hbm_cmd4, hbm.cmd_ch4);

    mkConnection(disp.payload_post, avg.payload_in);
    mkConnection(hbm.data_ch0,      avg.v0_in);
    mkConnection(hbm.data_ch2,      avg.v2_in);
    mkConnection(hbm.data_ch4,      avg.v4_in);

    mkConnection(disp.notify_out, ntf.notify_in);

    // ---- HBM-RRESP error-drain gate (spec §5.3) -----------------------------
    // hit packets only: dispatcher emits exactly one hdr_post + flowident_post
    // and three HBM bursts; hbmread emits one err token per channel per burst;
    // averager emits 8 beats. All strictly in packet order, so the Nth err
    // triple lines up with the Nth hdr/flowident and the Nth 8-beat group.
    Reg#(GateState)   gst   <- mkReg(G_IDLE);
    Reg#(UInt#(4))    gcnt  <- mkReg(0);
    PulseWire         hbmErrP <- mkPulseWire;

    (* aggressive_implicit_conditions *)
    rule do_gate_decide (gst == G_IDLE);
        let e0 <- hbm.err_ch0.get;
        let e2 <- hbm.err_ch2.get;
        let e4 <- hbm.err_ch4.get;
        let h  <- disp.hdr_post.get;
        let f  <- disp.flowident_post.get;
        gcnt <= 0;
        if (e0 || e2 || e4) begin
            hbmErrP.send;                 // CNT_HBM_ERR; drop this packet
            gst <= G_DROP;
        end else begin
            egr.hdr_in.put(h);
            egr.flowident_in.put(f);
            gst <= G_FWD;
        end
    endrule

    rule do_gate_fwd (gst == G_FWD);
        let b <- avg.avg_out.get;
        egr.avg_in.put(b);
        if (gcnt == 7) gst <= G_IDLE; else gcnt <= gcnt + 1;
    endrule

    rule do_gate_drop (gst == G_DROP);
        let b <- avg.avg_out.get;         // discard the errored packet's vector
        if (gcnt == 7) gst <= G_IDLE; else gcnt <= gcnt + 1;
    endrule

    // ---- control-plane glue (always_ready method wiring) --------------------
    (* fire_when_enabled, no_implicit_conditions *)
    rule do_enable;
        ingress.set_enable(ctrl.enable);
    endrule

    (* fire_when_enabled, no_implicit_conditions *)
    rule do_commit;
        if (ctrl.commit_cmd matches tagged Valid .c)
            ft.enq_cmd(c);
    endrule

    (* fire_when_enabled, no_implicit_conditions *)
    rule do_notify_cfg;
        ntf.set_cfg(ctrl.notify_cfg);
    endrule

    (* fire_when_enabled, no_implicit_conditions *)
    rule do_status;
        ctrl.status_in(ft.cmd_full, ntf.ring_full);
        ctrl.notify_head_in(ntf.head);
    endrule

    // ---- counter pulse aggregation ------------------------------------------
    (* fire_when_enabled, no_implicit_conditions *)
    rule do_counters;
        CntPulse hb = defaultValue; hb.hbm_err = hbmErrP;
        let p = cpOr(ingress.cntPulse,
                  cpOr(ft.cntPulse,
                    cpOr(disp.cntPulse,
                      cpOr(egr.cntPulse,
                        cpOr(ntf.cntPulse, hb)))));
        ctrl.cnt_in(p);
    endrule

    // ---- shell-facing interfaces --------------------------------------------
    interface s_axis_rpin  = ingress.s_axis;
    interface m_axis_rpout = egr.m_axis;
    interface s_axil       = ctrl.s_axil;
    interface hbm_axi      = hbm.hbm_axi;
    interface m_axibr      = ntf.m_axibr;

endmodule : mkVectorAvgNF

endpackage : VectorAvgNF
