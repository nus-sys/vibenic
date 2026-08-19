// Copyright (c) 2025-2026 Yunfan Li
// SPDX-License-Identifier: Apache-2.0

package CAM;

// Content-Addressable Memory

import FIFO::*;
import Vector::*;
import RegFile::*;
import ConfigReg::*;

`define DEBUG True

typedef union tagged {
    Tuple2#(k, v) Update;
    k Delete;
} BCAM_Op #(type k, type v) deriving (Bits, Eq);

// Binary CAM (Combinational Lookup): num_entry, key_type, val_type
interface BCAMCL #(numeric type n, type k, type v);
    method Action update (BCAM_Op#(k, v) op);
    method Maybe#(v) lookup (k key);
    method Bool is_full ();
endinterface

// Make a simple combinational binary CAM
// Same-cycle same-key behaviour is undefined
module mkBCAMCL (BCAMCL#(n, k, v)) provisos (
    Bits#(k, _wk), Bits#(v, _wv), Eq#(k), Add#(2, _0, n)
);
    Vector #(n, Reg#(Maybe#(k))) kvec <- replicateM(mkConfigReg(tagged Invalid));
    RegFile #(UInt#(TLog#(n)), v) vals <- mkRegFileWCF(0, fromInteger(valueOf(n) - 1));
    Wire #(Maybe#(UInt#(TLog#(n)))) first_free <- mkWire;

    function Maybe#(UInt#(TLog#(n))) get_first_free ();
        Maybe#(UInt#(TLog#(n))) ret = tagged Invalid;
        for (Integer i = 0; i < valueOf(n); i = i + 1)
            if (ret matches tagged Invalid &&& kvec[i] matches tagged Invalid)
                ret = tagged Valid fromInteger(i);
        return ret;
    endfunction

    function Maybe#(UInt#(TLog#(n))) get_first_match (k tgtkey);
        Maybe#(UInt#(TLog#(n))) ret = tagged Invalid;
        for (Integer i = 0; i < valueOf(n); i = i + 1)
            if (ret matches tagged Invalid &&&
                    kvec[i] matches tagged Valid .key &&& key == tgtkey)
                ret = tagged Valid fromInteger(i);
        return ret;
    endfunction

    (* fire_when_enabled *)
    rule alw_check_full (True);
        first_free <= get_first_free;
    endrule

    method Action update (BCAM_Op#(k, v) op);
        (* split *)
        if (op matches tagged Update {.key, .val}) begin
            let luIdx = get_first_match(key);
            if (luIdx matches tagged Valid .idx) begin
                // Update value for a existing key
                vals.upd(idx, val);
            end else begin
                // Got a new key that is not in CAM
                if (first_free matches tagged Valid .idx) begin
                    kvec[idx] <= tagged Valid key;
                    vals.upd(idx, val);
                end else if (`DEBUG)
                    $display("[BCAMCL] ERR: update fails when full");
                // Fails silently when no space and no existing entry of key
                // User is responsible for checking fulleness
            end
        end else if (op matches tagged Delete .key) begin
            let luIdx = get_first_match(key);
            if (luIdx matches tagged Valid .idx)
                // Delete by marking key as invalid
                kvec[idx] <= tagged Invalid;
            else if (`DEBUG)
                $display("[BCAMCL] ERR: delete nonexist entry");
        end
    endmethod

    method Maybe#(v) lookup (k key);
        let luIdx = get_first_match(key);
        if (luIdx matches tagged Valid .idx)
            return tagged Valid vals.sub(idx);
        else return tagged Invalid;
    endmethod

    method Bool is_full ();
        if (first_free matches tagged Invalid) return True;
        else return False;
    endmethod

endmodule

endpackage : CAM