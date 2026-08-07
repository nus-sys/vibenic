package AxisGetPut;

import AXI4_Stream::*;
import Semi_FIFOF::*;
import FIFO::*;
import GetPut::*;
import Connectable::*;
import DefaultValue::*;

// Re-exporting AXI4_Stream ifaces
export AXI4_Stream_Master_IFC(..);
export AXI4_Stream_Slave_IFC(..);
// Aliases of AXIS
export IfcAxisMst(..), IfcAxisSlv(..);

export AxisBeatS(..);
export AxisMasterAdapterS(..), AxisSlaveAdapterS(..), AxisFIFOS(..);
export mkAxisMasterAdapterS, mkAxisSlaveAdapterS, mkAxisFIFOS;
export axis_mask_keep;

export AxisBeatC(..);
export AxisMasterAdapterC(..), AxisSlaveAdapterC(..), AxisFIFOC(..);
export mkAxisMasterAdapterC, mkAxisSlaveAdapterC, mkAxisFIFOC;
export axis_beatc_mask_keep;

// Simple AXIS Beat, has no tdest/tuser
typedef struct {
    Bit#(data_w) data;
    Bit#(TDiv#(data_w, 8)) keep;
    Bool last;
} AxisBeatS #(numeric type data_w)
    deriving (Bits, Eq, FShow, Bounded);
instance DefaultValue#(AxisBeatS#(dw));
    defaultValue = AxisBeatS {data: '0, keep: '1, last: False};
endinstance

typedef AXI4_Stream_Master_IFC#(0,0,dw,0) IfcAxisMst#(numeric type dw);
typedef AXI4_Stream_Slave_IFC#(0,0,dw,0) IfcAxisSlv#(numeric type dw);

interface AxisMasterAdapterS #(numeric type data_w);
    interface AXI4_Stream_Master_IFC #(0, 0, data_w, 0) m_axis;
    interface Put #(AxisBeatS#(data_w)) din;
endinterface

interface AxisSlaveAdapterS #(numeric type data_w);
    interface AXI4_Stream_Slave_IFC #(0, 0, data_w, 0) s_axis;
    interface Get #(AxisBeatS#(data_w)) dout;
endinterface

interface AxisFIFOS #(numeric type data_w);
    interface AXI4_Stream_Slave_IFC #(0, 0, data_w, 0) s_axis;
    interface AXI4_Stream_Master_IFC #(0, 0, data_w, 0) m_axis;
endinterface

module mkAxisMasterAdapterS (AxisMasterAdapterS #(data_w))
        provisos (Div#(data_w, 8, TDiv#(data_w, 8)));

    AXI4_Stream_Master_Xactor_IFC #(0, 0, data_w, 0) xatr <- mkAXI4_Stream_Master_Xactor;
    FIFO #(AxisBeatS#(data_w)) sbuf <- mkLFIFO;

    rule wr_ifc (xatr.i_stream.notFull);
        let ub = sbuf.first;
        sbuf.deq;
        let xb = AXI4_Stream {
            tid: 0,
            tdata: ub.data,
            tstrb: ub.keep,
            tkeep: ub.keep,
            tlast: ub.last,
            tdest: 0,
            tuser: 0
        };
        xatr.i_stream.enq(xb);
    endrule

    interface AXI4_Stream_Master_IFC m_axis = xatr.axi_side;
    interface Put din = toPut(sbuf);

endmodule

module mkAxisSlaveAdapterS (AxisSlaveAdapterS #(data_w))
        provisos (Div#(data_w, 8, TDiv#(data_w, 8)));

    AXI4_Stream_Slave_Xactor_IFC #(0, 0, data_w, 0) xatr <- mkAXI4_Stream_Slave_Xactor;
    FIFO #(AxisBeatS#(data_w)) sbuf <- mkLFIFO;

    rule rd_ifc (xatr.o_stream.notEmpty);
        let xb = xatr.o_stream.first;
        xatr.o_stream.deq;
        let ub = AxisBeatS {
            data: xb.tdata,
            keep: xb.tkeep & xb.tstrb,
            last: xb.tlast
        };
        sbuf.enq(ub);
    endrule

    interface AXI4_Stream_Master_IFC s_axis = xatr.axi_side;
    interface Get dout = toGet(sbuf);

endmodule

module mkAxisFIFOS #(Integer depth) (AxisFIFOS #(data_w))
        provisos (Div#(data_w, 8, TDiv#(data_w, 8)));

    AxisMasterAdapterS #(data_w) m_adpt <- mkAxisMasterAdapterS;
    AxisSlaveAdapterS #(data_w) s_adpt <- mkAxisSlaveAdapterS;
    FIFO #(AxisBeatS#(data_w)) buff <- mkSizedFIFO(depth);
    mkConnection(s_adpt.dout, toPut(buff));
    mkConnection(toGet(buff), m_adpt.din);

    interface AXI4_Stream_Master_IFC m_axis = m_adpt.m_axis;
    interface AXI4_Stream_Slave_IFC s_axis = s_adpt.s_axis;

endmodule

function AxisBeatS #(dw) axis_mask_keep (AxisBeatS #(dw) b) provisos (Add#(_dw0, 8, dw));
    Bit#(dw) data = b.data;
    Bit#(TDiv#(dw, 8)) keep = b.keep;
    for (Integer i = 0; i < valueOf(TDiv#(dw, 8)); i = i + 1)
        data[i*8+7:i*8] = keep[i] == 1'b1 ? data[i*8+7:i*8] : 8'h0;
    return AxisBeatS {data: data, keep: keep, last: b.last};
endfunction

// Full AXI4-Stream interface

// Complete AXIS Beat, has tdest, tuser, tid
typedef struct {
    Bit#(data_w) data;
    Bit#(TDiv#(data_w, 8)) keep;
    UInt#(id_w) id;
    Bit#(dest_w) dest;
    Bit#(user_w) user_data;
    Bool last;
} AxisBeatC #(numeric type id_w, numeric type dest_w, numeric type data_w, numeric type user_w)
    deriving (Bits, Eq, FShow);

interface AxisMasterAdapterC #(
    numeric type id_w, numeric type dest_w, numeric type data_w, numeric type user_w
);
    interface AXI4_Stream_Master_IFC #(id_w, dest_w, data_w, user_w) m_axis;
    interface Put #(AxisBeatC#(id_w, dest_w, data_w, user_w)) din;
endinterface

interface AxisSlaveAdapterC #(
    numeric type id_w, numeric type dest_w, numeric type data_w, numeric type user_w
);
    interface AXI4_Stream_Slave_IFC #(id_w, dest_w, data_w, user_w) s_axis;
    interface Get #(AxisBeatC#(id_w, dest_w, data_w, user_w)) dout;
endinterface

interface AxisFIFOC #(
    numeric type id_w, numeric type dest_w, numeric type data_w, numeric type user_w
);
    interface AXI4_Stream_Slave_IFC #(id_w, dest_w, data_w, user_w) s_axis;
    interface AXI4_Stream_Master_IFC #(id_w, dest_w, data_w, user_w) m_axis;
endinterface

module mkAxisMasterAdapterC (AxisMasterAdapterC #(id_w, dest_w, data_w, user_w))
        provisos (Div#(data_w, 8, TDiv#(data_w, 8)));

    AXI4_Stream_Master_Xactor_IFC #(id_w, dest_w, data_w, user_w) xatr <- mkAXI4_Stream_Master_Xactor;
    FIFO #(AxisBeatC#(id_w, dest_w, data_w, user_w)) sbuf <- mkLFIFO;

    rule wr_ifc (xatr.i_stream.notFull);
        let ub = sbuf.first;
        sbuf.deq;
        let xb = AXI4_Stream {
            tid: pack(ub.id),
            tdata: ub.data,
            tstrb: ub.keep,
            tkeep: ub.keep,
            tlast: ub.last,
            tdest: ub.dest,
            tuser: ub.user_data
        };
        xatr.i_stream.enq(xb);
    endrule

    interface AXI4_Stream_Master_IFC m_axis = xatr.axi_side;
    interface Put din = toPut(sbuf);

endmodule

module mkAxisSlaveAdapterC (AxisSlaveAdapterC #(id_w, dest_w, data_w, user_w))
        provisos (Div#(data_w, 8, TDiv#(data_w, 8)));

    AXI4_Stream_Slave_Xactor_IFC #(id_w, dest_w, data_w, user_w) xatr <- mkAXI4_Stream_Slave_Xactor;
    FIFO #(AxisBeatC#(id_w, dest_w, data_w, user_w)) sbuf <- mkLFIFO;

    rule rd_ifc (xatr.o_stream.notEmpty);
        let xb = xatr.o_stream.first;
        xatr.o_stream.deq;
        let ub = AxisBeatC {
            data: xb.tdata,
            keep: xb.tkeep & xb.tstrb,
            last: xb.tlast,
            id: unpack(xb.tid),
            dest: xb.tdest,
            user_data: xb.tuser
        };
        sbuf.enq(ub);
    endrule

    interface AXI4_Stream_Master_IFC s_axis = xatr.axi_side;
    interface Get dout = toGet(sbuf);

endmodule

module mkAxisFIFOC #(Integer depth) (AxisFIFOC #(id_w, dest_w, data_w, user_w))
        provisos (Div#(data_w, 8, TDiv#(data_w, 8)));

    AxisMasterAdapterC #(id_w, dest_w, data_w, user_w) m_adpt <- mkAxisMasterAdapterC;
    AxisSlaveAdapterC #(id_w, dest_w, data_w, user_w) s_adpt <- mkAxisSlaveAdapterC;
    FIFO #(AxisBeatC#(id_w, dest_w, data_w, user_w)) buff <- mkSizedFIFO(depth);
    mkConnection(s_adpt.dout, toPut(buff));
    mkConnection(toGet(buff), m_adpt.din);

    interface AXI4_Stream_Master_IFC m_axis = m_adpt.m_axis;
    interface AXI4_Stream_Slave_IFC s_axis = s_adpt.s_axis;

endmodule

function AxisBeatC #(idw,dstw,dw,uw) axis_beatc_mask_keep (AxisBeatC #(idw,dstw,dw,uw) b) provisos (Add#(_dw0, 8, dw));
    Bit#(dw) data = b.data;
    Bit#(TDiv#(dw, 8)) keep = b.keep;
    for (Integer i = 0; i < valueOf(TDiv#(dw, 8)); i = i + 1)
        data[i*8+7:i*8] = keep[i] == 1'b1 ? data[i*8+7:i*8] : 8'h0;
    return AxisBeatC {data: data, keep: keep, last: b.last, id: b.id, dest: b.dest, user_data: b.user_data};
endfunction

endpackage : AxisGetPut