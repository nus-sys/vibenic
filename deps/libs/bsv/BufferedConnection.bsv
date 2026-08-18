package BufferedConnection;

import FIFO::*;
import GetPut::*;
import ClientServer::*;
import Connectable::*;

export Get, Put;
export Client, Server;
export mkBufGPConnection;
export mkBufCSConnection;
export mkCountedBufGPConnection;

module mkBufGPConnection #(Get#(t) upif, Put#(t) downif, Integer stage)
    (Empty) provisos (Bits#(t, wt));

    Put#(t) up[stage];
    Get#(t) down[stage];
    FIFO#(t) bufs[stage];

    for (Integer i = 0; i < stage; i = i + 1) begin
        bufs[i] <- mkFIFO;
        up[i] = toPut(bufs[i]);
        down[i] = toGet(bufs[i]);
    end

    for (Integer i = 0; i < stage - 1; i = i + 1)
        mkConnection(down[i], up[i + 1]);
    
    mkConnection(upif, up[0]);
    mkConnection(downif, down[stage - 1]);

endmodule

module mkCountedBufGPConnection #(Get#(t) upif, Put#(t) downif, Integer stage, Reg#(nt) cntreg)
    (Empty) provisos (Bits#(t, wt), Bits#(nt, wnt), Arith#(nt));

    Put#(t) up[stage];
    Get#(t) down[stage];
    FIFO#(t) bufs[stage];

    for (Integer i = 0; i < stage; i = i + 1) begin
        bufs[i] <- mkFIFO;
        up[i] = toPut(bufs[i]);
        down[i] = toGet(bufs[i]);
    end

    for (Integer i = 0; i < stage - 1; i = i + 1)
        mkConnection(down[i], up[i + 1]);

    mkConnection(downif, down[stage - 1]);

    rule do_put_count;
        let elem <- upif.get;
        up[0].put(elem);
        cntreg <= cntreg + 1;
    endrule

endmodule

module mkBufCSConnection #(Client#(req, resp) cli, Server#(req, resp) srv, Integer stage)
    (Empty) provisos (Bits#(req, wreq), Bits#(resp, wresp));

    mkBufGPConnection(cli.request, srv.request, stage);
    mkBufGPConnection(srv.response, cli.response, stage);

endmodule

module mkBufferedConnection();  // Unit Test
    FIFO #(int) in <- mkLFIFO;
    FIFO #(int) lb <- mkLFIFO;
    FIFO #(int) out <- mkLFIFO;
    Reg #(int) cyc <- mkReg(0);
    mkBufCSConnection(toGPClient(in, out), toGPServer(lb, lb), 3);
    rule do_wr (cyc < 10); in.enq(cyc); endrule
    rule do_tick; cyc <= cyc + 1; endrule
    rule do_rd; $display(cyc, toGet(out).get()); endrule
endmodule

endpackage : BufferedConnection