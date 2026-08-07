// =============================================================================
// FlowTable — spec §5.1 step 2, §6, §7 (the on-chip flow table front-end).
//
// Wraps the CachedCuckoo IP (IfcCachedCuckooServer#(104,128)) and presents the
// NF's flow-table contract: a Put/Get lookup port (5-tuple key in, Found/Fail
// out) plus an always_ready AXI-L command port (upsert/delete) backed by a
// depth-16 internal FIFO that self-drops on overflow.
//
// Dataflow style per docs/10-bsv-dataflow-handshaking.md: every hop is a rule over
// FIFOs; the cuckoo server is a Server#, so its request Put and response Get
// inject the handshake for free. No hand-wired ready/valid anywhere.
//
//   * cmd/lookup arbitration: two submit rules feed the single cuckoo request
//     Put. They structurally conflict (one shared method), so priority is
//     pinned with (* descending_urgency = "do_submit_cmd, do_submit_lookup" *):
//     a queued command always wins the cycle it is ready. Commands are rare
//     (host control plane), lookups dominate (line-rate datapath); giving the
//     command the higher urgency means a backed-up datapath can never starve
//     the control plane, while in steady state (cmdF empty) lookups flow
//     unimpeded.
//
//   * Succ-vs-Found routing: the cuckoo Server returns responses in request
//     order. A Lookup yields `Found v` / `Fail`; an Update/Remove yields
//     `Succ`. `Succ` is unambiguous for a command ack and never produced by a
//     lookup, so the response router discriminates purely on the KvsResp
//     variant — no parallel tag FIFO is needed. `Found`/`Fail` are forwarded
//     to lookup_resp; `Succ` is dropped (the command ack is not a lookup
//     result and the AXI-L host polls counters/status instead).
// =============================================================================
package FlowTable;

import FIFO::*;
import FIFOF::*;
import GetPut::*;
import ClientServer::*;
import DefaultValue::*;

import FlowReduceDefines::*;   // shared types + IfcFlowTable
import CachedCuckoo::*;        // mkCachedCuckooServer / IfcCachedCuckooServer
import KvsDefines::*;          // KvsReq / KvsResp / KvPair

(* synthesize *)
module mkFlowTable (IfcFlowTable);

    // The cuckoo IP. kw = FlowKey_w (104), vw = FlowVal_w (128).
    //   cacheSize=8, numHashes=4, htSize=1024 (-> 4*1024 = 4096 entries),
    //   maxTrial=32, reinstThres=8.
    IfcCachedCuckooServer#(FlowKey_w, FlowVal_w) cc <-
        mkCachedCuckooServer(8, 4, 1024, 32, 8);

    // Lookup ingress: keys arrive on the lookup_req Put. mkFIFO 2-elem so an
    // upstream producer is not back-pressured a cycle early when do_submit_*
    // momentarily yields to a command.
    FIFO#(Bit#(FlowKey_w))  luReqF  <- mkFIFO;

    // AXI-L table-command queue (spec §7 depth 16). Unguarded FIFOF: its enq /
    // deq / first carry NO implicit conditions, so the always_ready enq_cmd
    // method is genuinely always-ready (its explicit `if (cmdF.notFull)` fully
    // controls the enq) and do_submit_cmd guards deq with an explicit notEmpty.
    FIFOF#(TableCmd)        cmdF    <- mkUGSizedFIFOF(16);

    // Lookup result egress (Found / Fail only). mkLFIFO at the interface
    // boundary so a combinational consumer can drain it the same cycle.
    FIFO#(FlowKvsResp)      luRespF <- mkLFIFO;

    // One-cycle pulse: a command was dropped this cycle (cmdF was full when
    // enq_cmd fired). mkDWire so it self-clears and is readable combinationally
    // by the always_ready cntPulse method.
    Wire#(Bool)             dropPulse <- mkDWire(False);

    // ---- Submit path: feed cc.kvs_srv.request -------------------------------
    // Two rules share the single cuckoo request Put (a structural conflict).
    // Pin command priority so the rare control-plane command is never starved
    // by the line-rate lookup stream.
    (* descending_urgency = "do_submit_cmd, do_submit_lookup" *)

    rule do_submit_cmd (cmdF.notEmpty);
        let c = cmdF.first; cmdF.deq;
        FlowKvsReq r = c.is_delete
            ? tagged Remove c.key
            : tagged Update KvPair { key: c.key, val: c.val };
        cc.kvs_srv.request.put(r);
    endrule

    rule do_submit_lookup;
        let k <- toGet(luReqF).get;
        cc.kvs_srv.request.put(tagged Lookup k);
    endrule

    // ---- Response routing ---------------------------------------------------
    // Responses come back in request order. Discriminate purely by variant:
    //   Found v / Fail -> a lookup result, forward to lookup_resp
    //   Succ           -> a command ack, drop it (not a lookup result)
    rule do_route_resp;
        let resp <- cc.kvs_srv.response.get;
        case (resp) matches
            tagged Found .v : luRespF.enq(tagged Found v);
            tagged Fail     : luRespF.enq(tagged Fail);
            tagged Succ     : noAction;            // command ack — drop
        endcase
    endrule

    // ---- Interface ----------------------------------------------------------
    interface lookup_req  = toPut(luReqF);
    interface lookup_resp = toGet(luRespF);

    // always_ready: enqueue if the depth-16 queue has room, else drop and
    // pulse tbl_q_drop this cycle (spec §7 overflow behaviour).
    method Action enq_cmd (TableCmd c);
        if (cmdF.notFull)
            cmdF.enq(c);
        else
            dropPulse <= True;
    endmethod

    method Bool cmd_full = !cmdF.notFull;

    method CntPulse cntPulse;
        CntPulse p = defaultValue;
        p.tbl_q_drop = dropPulse;
        return p;
    endmethod

endmodule : mkFlowTable

endpackage : FlowTable
