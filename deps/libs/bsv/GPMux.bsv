package GPMux;

import Arbitrate::*;
import GetPut::*;
import Vector::*;
import FIFOF::*;
import FIFO::*;

interface GPMux #(numeric type n, type t);
    interface Vector#(n, Put#(t)) din;
    interface Get#(t) dout;
endinterface

interface GPDemux #(numeric type n, type t);
    interface Put#(t) din;
    interface Vector#(n, Get#(t)) dout;
endinterface

// Generic Get-Put Multiplexer
module mkGPMux #(Arbitrate#(n) arb) (GPMux#(n, t))
        provisos (Add#(1, _0, n), Bits #(t, _wt));

    Vector #(n, FIFOF#(t)) inbuf <- replicateM(mkLFIFOF);
    FIFO#(t) outbuf <- mkLFIFO;

    (* fire_when_enabled, no_implicit_conditions *)
    rule req_arb (any(hasRequest, inbuf));
        arb.request(map(hasRequest, inbuf));
    endrule

    (* aggressive_implicit_conditions *)
    rule fwd_data (findElem(True, arb.grant) matches tagged Valid .gid);
        outbuf.enq(inbuf[gid].first);
        inbuf[gid].deq;
    endrule

    interface Vector din = map(toPut, inbuf);
    interface Get dout = toGet(outbuf);

endmodule

// Round-robin version
module mkGPMuxRR (GPMux#(n, t)) provisos (Add#(1, _0, n), Bits #(t, _wt));
    Arbitrate#(n) rrArb <- mkRoundRobin;
    GPMux#(n, t) mux <- mkGPMux(rrArb);
    return mux;
endmodule

// Fixed-priority version, port 0 has highest priority
module mkGPMuxFP (GPMux#(n, t)) provisos (Add#(1, _0, n), Bits #(t, _wt));
    Arbitrate#(n) fpArb <- mkFixedPriority;
    GPMux#(n, t) mux <- mkGPMux(fpArb);
    return mux;
endmodule


// Generic Get-Put Demultiplexer
module mkGPDemux #(Arbitrate#(n) arb) (GPDemux#(n, t))
        provisos (Add#(1, _0, n), Bits #(t, _wt));

    FIFOF#(t) inbuf <- mkLFIFOF;
    Vector #(n, FIFOF#(t)) outbuf <- replicateM(mkLFIFOF);

    function Bool hasSpace(FIFOF#(a) b);
        return b.notFull;
    endfunction

    (* fire_when_enabled, no_implicit_conditions *)
    rule req_arb (any(hasSpace, outbuf) && inbuf.notEmpty);
        arb.request(map(hasSpace, outbuf));
    endrule

    (* aggressive_implicit_conditions *)
    rule fwd_data (findElem(True, arb.grant) matches tagged Valid .gid);
        outbuf[gid].enq(inbuf.first);
        inbuf.deq;
    endrule

    interface Put din = toPut(inbuf);
    interface Vector dout = map(toGet, outbuf);

endmodule

// Round-robin version
module mkGPDemuxRR (GPDemux#(n, t)) provisos (Add#(1, _0, n), Bits #(t, _wt));
    Arbitrate#(n) rrArb <- mkRoundRobin;
    GPDemux#(n, t) demux <- mkGPDemux(rrArb);
    return demux;
endmodule

// Fixed-priority version, port 0 has highest priority
module mkGPDemuxFP (GPDemux#(n, t)) provisos (Add#(1, _0, n), Bits #(t, _wt));
    Arbitrate#(n) fpArb <- mkFixedPriority;
    GPDemux#(n, t) demux <- mkGPDemux(fpArb);
    return demux;
endmodule

endpackage : GPMux
