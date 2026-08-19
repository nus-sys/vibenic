// Copyright (c) 2025-2026 Yunfan Li
// SPDX-License-Identifier: Apache-2.0

package Axi4Utilities;

import FIFO::*;
import GetPut::*;
import Connectable::*;
import TLM3::*;
import Axi4::*;

export TLM3::*;
export Axi4::*;
export Axi4Utilities::*;

/* Master Side */

function Axi4RdWrMaster #(iw, aw, dw, lw, 0) getAxi4MstFromXtr (
    Axi4RdWrMasterXActorIFC #(_tlmreq_t, _tlmresp_t, iw, aw, dw, lw, 0) xtrifc
);
    return (interface Axi4RdWrMaster;
        interface Axi4RdMaster read = xtrifc.read.bus;
        interface Axi4WrMaster write = xtrifc.write.bus;
    endinterface);
endfunction

function TLMSendIFC #(tlmreq_t, tlmresp_t) getTlmSendFromFifoPair (
    FIFO #(tlmreq_t) reqf, FIFO #(tlmresp_t) respf
);
    return (interface TLMSendIFC;
        interface Get tx = toGet(reqf);
        interface Put rx = toPut(respf);
    endinterface);
endfunction

module mkAxi4MasterFromTlm #(
    TLMSendIFC #(tlmreq_t, tlmresp_t) tlm, Integer max_flight
) (
    Axi4RdWrMaster #(iw, aw, dw, lw, 0)
) provisos (
    Bits #(tlmreq_t, _reqw), Bits #(tlmresp_t, _respw),
    TLMRequestTC #(tlmreq_t, iw, aw, dw, lw, 0),
    TLMResponseTC #(tlmresp_t, iw, aw, dw, lw, 0)
);
    Axi4RdWrMasterXActorIFC #(tlmreq_t, tlmresp_t, iw, aw, dw, lw, 0) xtr
        <- mkAxi4RdWrMaster(fromInteger(max_flight), /*big_endian*/ False);
    mkConnection(tlm, xtr.tlm);
    return getAxi4MstFromXtr(xtr);
endmodule

module mkAxi4MasterFromFifoPair #(
    FIFO #(tlmreq_t) reqf, FIFO #(tlmresp_t) respf, Integer max_flight
) (
    Axi4RdWrMaster #(iw, aw, dw, lw, 0)
) provisos (
    Bits #(tlmreq_t, _reqw), Bits #(tlmresp_t, _respw),
    TLMRequestTC #(tlmreq_t, iw, aw, dw, lw, 0),
    TLMResponseTC #(tlmresp_t, iw, aw, dw, lw, 0)
);
    Axi4RdWrMaster #(iw, aw, dw, lw, 0) axi
        <- mkAxi4MasterFromTlm(getTlmSendFromFifoPair(reqf, respf), max_flight);
    return axi;
endmodule

/* Slave Side */

function Axi4RdWrSlave #(iw, aw, dw, lw, 0) getAxi4SlvFromXtr (
    Axi4RdWrSlaveXActorIFC #(_tlmreq_t, _tlmresp_t, iw, aw, dw, lw, 0) xtrifc
);
    return (interface Axi4RdWrSlave;
        interface Axi4RdSlave read = xtrifc.read.bus;
        interface Axi4WrSlave write = xtrifc.write.bus;
    endinterface);
endfunction

function TLMRecvIFC #(tlmreq_t, tlmresp_t) getTlmRecvFromFifoPair (
    FIFO #(tlmreq_t) reqf, FIFO #(tlmresp_t) respf
);
    return (interface TLMRecvIFC;
        interface Get tx = toGet(respf);
        interface Put rx = toPut(reqf);
    endinterface);
endfunction

module mkAxi4SlaveFromTlm #(
    TLMRecvIFC #(tlmreq_t, tlmresp_t) tlm
) (
    Axi4RdWrSlave #(iw, aw, dw, lw, 0)
) provisos (
    Bits #(tlmreq_t, _reqw), Bits #(tlmresp_t, _respw),
    TLMRequestTC #(tlmreq_t, iw, aw, dw, lw, 0),
    TLMResponseTC #(tlmresp_t, iw, aw, dw, lw, 0),
    Add#(_0, SizeOf#(TLMErrorCode), dw)
);
    function Bool addr_match_any (Bit#(aw) addr);
        return True;
    endfunction
    Axi4RdWrSlaveXActorIFC #(tlmreq_t, tlmresp_t, iw, aw, dw, lw, 0) xtr
        <- mkAxi4RdWrSlave(/*keep_bursts*/ True, addr_match_any);
    mkConnection(tlm, xtr.tlm);
    return getAxi4SlvFromXtr(xtr);
endmodule

module mkAxi4SlaveFromFifoPair #(
    FIFO #(tlmreq_t) reqf, FIFO #(tlmresp_t) respf
) (
    Axi4RdWrSlave #(iw, aw, dw, lw, 0)
) provisos (
    Bits #(tlmreq_t, _reqw), Bits #(tlmresp_t, _respw),
    TLMRequestTC #(tlmreq_t, iw, aw, dw, lw, 0),
    TLMResponseTC #(tlmresp_t, iw, aw, dw, lw, 0),
    Add#(_0, SizeOf#(TLMErrorCode), dw)
);
    Axi4RdWrSlave #(iw, aw, dw, lw, 0) axi
        <- mkAxi4SlaveFromTlm(getTlmRecvFromFifoPair(reqf, respf));
    return axi;
endmodule

module mkTLMBurstReadExpander #(
    TLMRecvIFC#(tlmreq_t, tlmresp_t) slvtlm,
    Integer max_axi_otf
) (
    TLMRecvIFC#(tlmreq_t, tlmresp_t)
) provisos (
    Bits #(tlmreq_t, _reqw), Bits #(tlmresp_t, _respw),
    TLMRequestTC #(tlmreq_t, iw, aw, dw, lw, 0),
    TLMResponseTC #(tlmresp_t, iw, aw, dw, lw, 0),
    Add#(_0, SizeOf#(TLMErrorCode), dw)
);
    FIFO #(tlmreq_t) reqf <- mkFIFO;
    FIFO #(tlmresp_t) respf <- mkFIFO;

    Reg #(UInt#(lw)) curr_exp_rem <- mkReg(0);
    Reg #(RequestDescriptor#(iw, aw, dw, lw, 0)) curr_rd_desc <- mkRegU;
    FIFO #(UInt#(lw)) rd_blen_rec <- mkSizedFIFO(max_axi_otf);
    Reg #(UInt#(lw)) rd_resp_rem <- mkReg(0);

    rule do_proc_req_desc (
        curr_exp_rem == 0 &&& 
        toTLMRequest(reqf.first) matches tagged Descriptor .desc
    );
        if (desc.command == READ) begin
            // Record burst length for READ so later we can pack the responses back
            rd_blen_rec.enq(desc.b_length);
            // Update states for generating expanded non-burst requests
            // For original non-burst requests, it shouldn't affect anything
            curr_exp_rem <= desc.b_length;
            let desc_nb = desc;
            desc_nb.b_length = 'd0;
            curr_rd_desc <= desc_nb;
            // $display("[READ COMMAND] <<< %d", desc_nb.b_length);
            // Submit (the 1st) non-burst request to the slave
            slvtlm.rx.put(fromTLMRequest(tagged Descriptor desc_nb));
        end else begin
            // We only expand bursty READ into multiple TLM requests
            // For others, we just pass them through
            slvtlm.rx.put(reqf.first);
        end
        reqf.deq;
    endrule

    rule do_proc_req_data (
        curr_exp_rem == 0 &&&
        toTLMRequest(reqf.first) matches tagged Data .dt
    );
        slvtlm.rx.put(reqf.first);
        reqf.deq;
    endrule

    rule do_exp_bursty_rd (curr_exp_rem > 0);
        // Generate the next request for a burst
        let desc = curr_rd_desc;
        desc.addr = desc.addr + fromInteger(valueOf(TDiv#(dw, 8))); // NOTE: Narrow burst not supported
        curr_exp_rem <= curr_exp_rem - 1;
        curr_rd_desc <= desc;
        slvtlm.rx.put(fromTLMRequest(tagged Descriptor desc));
    endrule

    (* aggressive_implicit_conditions *)
    rule do_proc_resp;
        let resp <- slvtlm.tx.get;
        let tlmresp = toTLMResponse(resp);
        if (tlmresp.command == READ) begin
            if (rd_resp_rem == 0) begin // Not in a read burst
                // Check READ response burst and assembles if needed
                let blen <- toGet(rd_blen_rec).get;
                if (blen > 0) tlmresp.is_last = False;
                rd_resp_rem <= blen;
            end else begin  // In a read burst
                if (rd_resp_rem > 1) tlmresp.is_last = False;
                rd_resp_rem <= rd_resp_rem - 1;
            end
        end
        respf.enq(fromTLMResponse(tlmresp));
    endrule

    return getTlmRecvFromFifoPair(reqf, respf);

endmodule

endpackage : Axi4Utilities