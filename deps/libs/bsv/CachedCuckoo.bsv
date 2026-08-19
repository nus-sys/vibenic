// Copyright (c) 2025-2026 Yunfan Li
// SPDX-License-Identifier: Apache-2.0

package CachedCuckoo;

import GetPut::*;
import FIFO::*;
import ClientServer::*;
import KvsDefines::*;

interface IfcCachedCuckooServer #(numeric type kw, numeric type vw);
    interface Server #(KvsReq #(kw, vw), KvsResp #(vw)) kvs_srv;
endinterface

interface IfcCachedCuckoo #(numeric type kw, numeric type vw);
    interface Put #(Bit#(kw)) lookup;
    interface Get #(Maybe#(Bit#(vw))) lookup_res;
    interface Put #(Tuple3#(Bool, Bit#(kw), Bit#(vw))) update;  // Bool: Del/~Wr
    interface Get #(Tuple2#(Bit#(kw), Bit#(vw))) drain;
endinterface

interface IfcCachedCuckooV #(numeric type kw, numeric type vw);
    (* always_ready *)
    method Action put_lookup (Bit#(kw) key);
    method Action put_update (Bit#(TAdd#(1, TAdd#(kw, vw))) updreq);
    method Bit#(TAdd#(1, vw)) get_lookup ();
    method Bit#(TAdd#(kw, vw)) get_victim ();
    method Action pop_victim ();
endinterface

import "BVI" CachedCuckoo =
    module mkCachedCuckooV #(
        Integer cacheSize,
        Integer numHashes,
        Integer htSize,
        Integer maxTrial,
        Bool delValMatch
    ) (
        IfcCachedCuckooV #(kw, vw)
    ) provisos (
        Add #(_k0, 1, kw), Add #(_v0, 1, vw)
    );
        default_clock clk (clk, (*unused*)CLK_GATE);
        default_reset rst (rstn);

        parameter KEY_WIDTH = valueOf(kw);
        parameter VAL_WIDTH = valueOf(vw);
        parameter CACHE_SIZE = cacheSize;
        parameter NUM_VICTIM = cacheSize;
        parameter NUM_HASHES = numHashes;
        parameter TABLE_SIZE = htSize;
        parameter RAM_NPIPE = 2;
        parameter MAX_TRIAL = maxTrial;
        parameter DEL_VALMATCH = delValMatch ? 1'b1 : 1'b0;

        method put_lookup (luKey) enable (luEna);
        method put_update (updReq) enable (updEna) ready (updRdy);
        method (*reg*)luRes get_lookup () ready (luRdy);
        method vicKvp get_victim ready (vicAvail);
        method pop_victim () enable (vicPop) ready (vicAvail);

        schedule (put_update, get_lookup, get_victim, pop_victim) CF (put_lookup);
        schedule (get_lookup, get_victim, pop_victim) CF (put_update);
        schedule (get_victim, pop_victim) CF (get_lookup);
        schedule get_victim SB (pop_victim);

        schedule (put_lookup) C (put_lookup);
        schedule (put_update) C (put_update);
        schedule (get_lookup) C (get_lookup);
        schedule (get_victim) C (get_victim);
        schedule (pop_victim) C (pop_victim);

    endmodule

module mkCachedCuckoo #(
    Integer cacheSize, Integer numHashes, Integer htSize, Integer maxTrial, Bool delValMatch
) (
    IfcCachedCuckoo #(kw, vw)
) provisos (
    Add #(_k0, 1, kw), Add #(_v0, 1, vw)
);

    IfcCachedCuckooV #(kw, vw) ccht_vl
        <- mkCachedCuckooV(cacheSize, numHashes, htSize, maxTrial, delValMatch);
    
    interface Put lookup;
        method Action put (Bit#(kw) key);
            ccht_vl.put_lookup(key);
        endmethod
    endinterface

    interface Get lookup_res;
        method ActionValue#(Maybe#(Bit#(vw))) get ();
            let res = ccht_vl.get_lookup;
            if (res[valueOf(vw)] == 1'b1)
                return tagged Valid res[valueOf(vw)-1:0];
            else
                return tagged Invalid;
        endmethod
    endinterface

    interface Put update;
        method Action put (Tuple3#(Bool, Bit#(kw), Bit#(vw)) req);
            let {isdel, key, val} = req;
            Bit#(TAdd#(1, TAdd#(kw, vw))) req_bits = 0;
            req_bits[valueOf(kw)+valueOf(vw)] = isdel ? 1'b1 : 1'b0;
            req_bits[valueOf(kw)+valueOf(vw)-1:valueOf(vw)] = key;
            req_bits[valueOf(vw)-1:0] = val;
            ccht_vl.put_update(req_bits);
        endmethod
    endinterface

    interface Get drain;
        method ActionValue#(Tuple2#(Bit#(kw), Bit#(vw))) get ();
            let kvp = ccht_vl.get_victim;
            Bit#(kw) key = kvp[valueOf(kw)+valueOf(vw)-1:valueOf(vw)];
            Bit#(vw) val = kvp[valueOf(vw)-1:0];
            ccht_vl.pop_victim;
            return tuple2(key, val);
        endmethod
    endinterface

endmodule

module mkCachedCuckooServer #(
    Integer cacheSize, Integer numHashes, Integer htSize, Integer maxTrial, Integer reinstThres
) (
    IfcCachedCuckooServer #(kw, vw)
) provisos (
    Add #(_k0, 1, kw), Add #(_v0, 1, vw)
);

    IfcCachedCuckoo #(kw, vw) ccht <-
        mkCachedCuckoo(cacheSize, numHashes, htSize, maxTrial, False);
    // Note: current KvsReq type does not support value-matched deletion

    FIFO #(KvsReq #(kw, vw)) kvsreq_ibuf <- mkLFIFO;
    FIFO #(KvsResp #(vw)) kvsresp_obuf <- mkLFIFO;
    FIFO #(Bool) proc_q <- mkSizedFIFO(8);  // LU takes 6 cycles when RAM_NPIPE=2
    Reg #(UInt#(16)) reinst_cooldown <- mkReg(fromInteger(reinstThres));

    (* preempts = "do_reinst, do_subm_req" *)

    rule do_subm_req;
        let req <- toGet(kvsreq_ibuf).get;
        case (req) matches
            tagged Lookup .k : begin
                ccht.lookup.put(k);
                proc_q.enq(True);
            end
            tagged Update .kv : begin
                ccht.update.put(tuple3(False, kv.key, kv.val));
                proc_q.enq(False);
            end
            tagged Remove .k : begin
                ccht.update.put(tuple3(True, k, 0));
                proc_q.enq(False);
            end
        endcase
    endrule

    rule do_reinst (reinst_cooldown == 0);
        let vickv <- ccht.drain.get;
        ccht.update.put(tuple3(False, tpl_1(vickv), tpl_2(vickv)));
        reinst_cooldown <= fromInteger(reinstThres);
    endrule

    rule do_reinst_cd (reinst_cooldown != 0);
        reinst_cooldown <= reinst_cooldown - 1;
    endrule

    rule do_resp_lu (proc_q.first == True);
        proc_q.deq;
        let lures <- ccht.lookup_res.get;
        if (lures matches tagged Valid .v)
            kvsresp_obuf.enq(tagged Found v);
        else
            kvsresp_obuf.enq(tagged Fail);
    endrule

    rule do_resp_wr (proc_q.first == False);
        proc_q.deq;
        kvsresp_obuf.enq(tagged Succ);
    endrule

    interface Server kvs_srv = toGPServer(kvsreq_ibuf, kvsresp_obuf);

endmodule

endpackage
