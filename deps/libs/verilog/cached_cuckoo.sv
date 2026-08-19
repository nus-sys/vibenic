// Copyright (c) 2020-2026 Yunfan Li
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 20.11.2020 16:09:14
// Design Name: 
// Module Name: cached_cuckoo
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module cached_cuckoo #(
    parameter KEY_WIDTH = 32,
    parameter VAL_WIDTH = 32,
    parameter CACHE_SIZE = 8,
    parameter NUM_VICTIM = 8,
    parameter NUM_HASHES = 2,
    parameter TABLE_SIZE = 1024,
    parameter RAM_NPIPE = 2,
    parameter MAX_TRIAL = 2 * $clog2(TABLE_SIZE),
    parameter DEL_VALMATCH = 0
) (
    input  logic clk,
    input  logic rst,
    input  logic [KEY_WIDTH-1:0] luKey,
    input  logic wrEn,
    input  logic delEn,
    input  logic [KEY_WIDTH-1:0] updKey,
    input  logic [VAL_WIDTH-1:0] updVal,
    input  logic vicPop,
    output logic busy,
    output logic luHit,
    output logic [VAL_WIDTH-1:0] luVal,
    output logic vicAvail,
    output logic [KEY_WIDTH-1:0] vicKey,
    output logic [VAL_WIDTH-1:0] vicVal
);

(* ram_style = "block" *)
reg  [VAL_WIDTH-1:0] upd_valMem [0:CACHE_SIZE-1];
wire [VAL_WIDTH-1:0] upd_popVal, upd_luVal;
wire [KEY_WIDTH-1:0] upd_popKey;
wire [$clog2(CACHE_SIZE)-1:0] upd_luId, upd_wrId, upd_popId;
wire upd_luHit, upd_popValid, upd_wrEn, upd_full;

reg  buff_updHit [0:RAM_NPIPE];
reg  buff_delHit [0:RAM_NPIPE];
reg  buff_vicHit [0:RAM_NPIPE];
reg  [KEY_WIDTH-1:0] buff_luKey;
reg  [VAL_WIDTH-1:0] buff_luVal [0:RAM_NPIPE];
reg  [VAL_WIDTH-1:0] buff_vicLuVal [0:RAM_NPIPE];

wire [KEY_WIDTH-1:0] delmask_popKey;
wire [$clog2(CACHE_SIZE)-1:0] delmask_wrId, delmask_popId;
wire delmask_hit, delmask_popValid, delmask_wrEn, delmask_full;
wire upd_pop, delmask_pop;

wire [KEY_WIDTH-1:0] ht_updKey;
wire [VAL_WIDTH-1:0] ht_updVal;
wire ht_wena, ht_dena, ht_drainReady;
wire ht_updReady, ht_luHit, ht_drainValid;
wire [VAL_WIDTH-1:0] ht_luVal, ht_drainVal;
wire [KEY_WIDTH-1:0] ht_drainKey;

(* ram_style = "block" *)
reg  [VAL_WIDTH-1:0] vic_valMem [0:NUM_VICTIM-1];
wire [VAL_WIDTH-1:0] vic_luVal;
wire [KEY_WIDTH-1:0] vic_updKey;
wire [$clog2(NUM_VICTIM)-1:0] vic_luId, vic_wrId, vic_popId;
wire vic_luHit, vic_wrEn, vic_full, vic_wena, vic_dena;

(* ram_style = "block" *)
reg  [VAL_WIDTH-1:0] del_valMem [0:CACHE_SIZE-1];
generate if (DEL_VALMATCH == 1)
    always_ff @ (posedge clk) if (delmask_wrEn)
        del_valMem[delmask_wrId] <= updVal;
endgenerate

// Delay lookup by one stage to sync with HT
// Lookup inside HT uses the state immediately after lookup request
// but result takes one more cycle to go out. Hence results in the
// caches are also buffered for one cycle.
int i;
always_ff @ (posedge clk) begin : lu_ppl_blk
    buff_luKey <= luKey;
    buff_updHit[0] <= upd_luHit;
    if (DEL_VALMATCH == 1) buff_delHit[0] <= 1'b0;  // Do not mask LU if delete when value matched
    else buff_delHit[0] <= delmask_hit;
    buff_luVal[0] <= upd_luVal;
    buff_vicHit[0] <= vic_luHit;
    buff_vicLuVal[0] <= vic_luVal;
    for (i = 1; i <= RAM_NPIPE; i++) begin
        buff_updHit[i] <= buff_updHit[i-1];
        buff_delHit[i] <= buff_delHit[i-1];
        buff_luVal[i] <= buff_luVal[i-1];
        buff_vicHit[i] <= buff_vicHit[i-1];
        buff_vicLuVal[i] <= buff_vicLuVal[i-1];
    end
end

// Write insert/update value into cache
always_ff @ (posedge clk) begin : valmem_wr_blk
    if (upd_wrEn) upd_valMem[upd_wrId] <= updVal;
    if (vic_wrEn) vic_valMem[vic_wrId] <= ht_drainVal;
end

// Cuckoo HT update arbitration
assign ht_updKey = delmask_popValid ? delmask_popKey : upd_popKey;
generate
if (DEL_VALMATCH == 1)
    assign ht_updVal = delmask_popValid ? del_valMem[delmask_popId] : upd_popVal;
else assign ht_updVal = upd_popVal;
endgenerate
assign ht_wena = upd_popValid && !delmask_popValid && !ht_drainValid;
assign ht_dena = delmask_popValid;
assign upd_pop = ht_updReady && upd_popValid && !delmask_popValid && !ht_drainValid;
assign delmask_pop = ht_updReady && delmask_popValid;

// Victim Cache update arbitration
assign vic_dena = (delEn || wrEn) ? 
    ((ht_drainValid && updKey == ht_drainKey) ? 1'b0 : 1'b1) : 1'b0;
assign vic_wena = ht_drainValid && !(delEn || wrEn);
assign vic_updKey = (delEn || wrEn) ? updKey : ht_drainKey;
assign ht_drainReady = ht_drainValid && 
    (!(delEn || wrEn) || updKey == ht_drainKey);

// Wiring outputs
assign upd_luVal = upd_valMem[upd_luId];
assign upd_popVal = upd_valMem[upd_popId];
assign vic_luVal = vic_valMem[vic_luId];
assign vicVal = vic_valMem[vic_popId];
assign luHit = buff_delHit[RAM_NPIPE] ? 1'b0 :
    (buff_updHit[RAM_NPIPE] || ht_luHit || buff_vicHit[RAM_NPIPE]);
assign luVal = buff_updHit[RAM_NPIPE] ? buff_luVal[RAM_NPIPE] : 
    (ht_luHit ? ht_luVal : buff_vicLuVal[RAM_NPIPE]);
assign busy = upd_full || delmask_full || vic_full;

cam_cache #(
    .DATA_WIDTH(KEY_WIDTH),
    .CACHE_SIZE(CACHE_SIZE)
) upd_cache_inst (
    .clk(clk),
    .rst(rst),
    .luData(buff_luKey),
    .wena(wrEn),
    .dena(delEn),
    .updData(updKey),
    .pop(upd_pop),
    .full(upd_full),
    .luHit(upd_luHit),
    .luId(upd_luId),
    .updHit(upd_wrEn),
    .updId(upd_wrId),
    .hasEntry(upd_popValid),
    .popId(upd_popId),
    .popData(upd_popKey)
);

cam_cache #(
    .DATA_WIDTH(KEY_WIDTH),
    .CACHE_SIZE(CACHE_SIZE)
) delmask_cache_inst (
    .clk(clk),
    .rst(rst),
    .luData(buff_luKey),
    .wena(delEn),
    .dena(wrEn),
    .updData(updKey),
    .pop(delmask_pop),
    .full(delmask_full),
    .luHit(delmask_hit),
    .luId(),
    .updHit(delmask_wrEn),
    .updId(delmask_wrId),
    .hasEntry(delmask_popValid),
    .popId(delmask_popId),
    .popData(delmask_popKey)
);

cam_cache #(
    .DATA_WIDTH(KEY_WIDTH),
    .CACHE_SIZE(NUM_VICTIM)
) victim_cache_inst (
    .clk(clk),
    .rst(rst),
    .luData(buff_luKey),
    .wena(vic_wena),
    .dena(vic_dena),
    .updData(vic_updKey),
    .pop(vicPop),
    .full(vic_full),
    .luHit(vic_luHit),
    .luId(vic_luId),
    .updHit(vic_wrEn),
    .updId(vic_wrId),
    .hasEntry(vicAvail),
    .popId(vic_popId),
    .popData(vicKey)
);

uram_cuckoo #(
    .KEY_WIDTH(KEY_WIDTH),
    .VAL_WIDTH(VAL_WIDTH),
    .NUM_HASHES(NUM_HASHES),
    .TABLE_SIZE(TABLE_SIZE),
    .RAM_NPIPE(RAM_NPIPE),
    .MAX_TRIAL(MAX_TRIAL),
    .DEL_VALMATCH(DEL_VALMATCH)
) cuc_ht_inst (
    .clk(clk),
    .rst(rst),
    .luKey(luKey),
    .updKey(ht_updKey),
    .updVal(ht_updVal),
    .wena(ht_wena),
    .dena(ht_dena),
    .drainReady(ht_drainReady),
    .updReady(ht_updReady),
    .luHit(ht_luHit),
    .luVal(ht_luVal),
    .drainValid(ht_drainValid),
    .drainKey(ht_drainKey),
    .drainVal(ht_drainVal)
);

endmodule
