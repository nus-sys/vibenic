// Copyright (c) 2025-2026 Yunfan Li
// SPDX-License-Identifier: Apache-2.0

package KvsDefines;

typedef struct {
    Bit #(kw) key;
    Bit #(vw) val;
} KvPair #(numeric type kw, numeric type vw)
    deriving (Eq, Bits, Bounded);

typedef union tagged {
    KvPair #(kw, vw) Update;
    Bit #(kw)        Lookup;
    Bit #(kw)        Remove;
} KvsReq #(numeric type kw, numeric type vw)
    deriving (Eq, Bits, Bounded);

typedef union tagged {
    KvPair #(kw, vw) Update;
    Bit #(kw)        Lookup;
    Bit #(kw)        Remove;
    KvPair #(kw, vw) RemVal;
} KvsReqRV #(numeric type kw, numeric type vw)
    deriving (Eq, Bits, Bounded);

typedef union tagged {
    Bit #(vw)  Found;
    void       Succ;
    void       Fail;
} KvsResp #(numeric type vw)
    deriving (Eq, Bits, Bounded);

instance FShow#(KvPair #(kw, vw));
    function Fmt fshow (KvPair #(kw, vw) kv);
        return $format("KvPair <%h, %h>", kv.key, kv.val);
    endfunction
endinstance

instance FShow#(KvsReq #(kw, vw));
    function Fmt fshow (KvsReq #(kw, vw) req);
        case (req) matches
            tagged Update .kvp : return $format("KVS Update ") + fshow(kvp);
            tagged Lookup .k : return $format("KVS Lookup Key %h", k);
            tagged Remove .k : return $format("KVS Remove Key %h", k);
        endcase
    endfunction
endinstance

instance FShow#(KvsResp #(vw));
    function Fmt fshow (KvsResp #(vw) resp);
        case (resp) matches
            tagged Found .v : return $format("KVS Found Value %h", v);
            tagged Succ : return $format("KVS Op Success");
            tagged Fail : return $format("KVS Op Fail");
        endcase
    endfunction
endinstance

typedef 512     ValStr_w;
typedef 30      ValPtr_w;
typedef Maybe#(Bit#(ValPtr_w))  ValPtr_t;

endpackage : KvsDefines
