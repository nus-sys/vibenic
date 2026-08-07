package DebugPutSink;

import GetPut::*;

export mkDebugPutSink;
export mkGetWithDebugProbe, mkPutWithDebugProbe;

import "BVI" DebugPutSink = 
    module mkDebugPutSink #(String sinkTag) (Put#(m)) provisos (Bits#(m, sm));
        default_clock clk(CLK, (*unused*)CLK_GATE);
        default_reset no_reset;
        parameter SINK_TAG = sinkTag;
        parameter M_WIDTH = valueOf(sm);
        method put (DBG_MESSAGE) enable (DBG_MVALID);
        schedule (put) C (put);
    endmodule

module mkPutWithDebugProbe #(Put#(t) orig, String prbTag) (Put#(t)) provisos (Bits#(t, st));
    Put #(t) dbgprb <- mkDebugPutSink(prbTag);
    method Action put (t v);
        orig.put(v);
        dbgprb.put(v);
    endmethod
endmodule

module mkGetWithDebugProbe #(Get#(t) orig, String prbTag) (Get#(t)) provisos (Bits#(t, st));
    Put #(t) dbgprb <- mkDebugPutSink(prbTag);
    method ActionValue #(t) get ();
        let v <- orig.get();
        dbgprb.put(v);
        return v;
    endmethod
endmodule

endpackage : DebugPutSink