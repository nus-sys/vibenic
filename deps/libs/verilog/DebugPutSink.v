// Copyright (c) 2025-2026 Yunfan Li
// SPDX-License-Identifier: Apache-2.0

module DebugPutSink #(
    parameter SINK_TAG = "Debug",
    parameter M_WIDTH = 32
) (
    input   CLK,
    input   DBG_MVALID,
    input   [M_WIDTH-1:0]   DBG_MESSAGE
);

(* mark_debug = "true" *)
reg [M_WIDTH-1:0] dbg_msg = 0;

(* mark_debug = "true" *)
reg dbg_vld = 1'b0;

always @ (posedge CLK) begin
    if (DBG_MVALID) begin
        dbg_vld <= 1'b1;
        dbg_msg <= DBG_MESSAGE;
        if (SINK_TAG != "")
            $display("[%s] Msg=0x%h", SINK_TAG, DBG_MESSAGE);
    end else begin
        dbg_vld <= 1'b0;
    end
end

endmodule