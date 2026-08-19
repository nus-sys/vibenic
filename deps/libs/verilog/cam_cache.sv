// Copyright (c) 2020-2026 Yunfan Li
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 04.12.2020 00:40:08
// Design Name: 
// Module Name: cam_cache
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


module cam_cache #(
    parameter DATA_WIDTH = 32,
    parameter CACHE_SIZE = 4
) (
    input  logic clk,
    input  logic rst,
    input  logic [DATA_WIDTH-1:0] luData,
    input  logic wena,
    input  logic dena,
    input  logic [DATA_WIDTH-1:0] updData,
    input  logic pop,
    output logic full,
    output logic luHit,
    output logic [$clog2(CACHE_SIZE)-1:0] luId,
    output logic updHit,
    output logic [$clog2(CACHE_SIZE)-1:0] updId,
    output logic hasEntry,
    output logic [$clog2(CACHE_SIZE)-1:0] popId,
    output logic [DATA_WIDTH-1:0] popData
);

reg [DATA_WIDTH-1:0] mem [0:CACHE_SIZE-1];
reg [CACHE_SIZE-1:0] valid;

logic hit_upd, hit_lu, has_space, has_entry;
logic [$clog2(CACHE_SIZE)-1:0] id_upd, id_lu, id_space, id_pop;
logic [CACHE_SIZE-1:0] match_upd, match_lu;
logic [CACHE_SIZE-1:0] mask_wr, mask_del;

// Construct the match vectors
always_comb begin
    int i;
    for (i = 0; i < CACHE_SIZE; i++) begin
        match_upd[i] = (valid[i] && updData == mem[i]) ? 1'b1 : 1'b0;
        match_lu[i] = (valid[i] && luData == mem[i]) ? 1'b1 : 1'b0;
    end
end

priority_encoder #(CACHE_SIZE) pe_upd (match_upd, id_upd, hit_upd);
priority_encoder #(CACHE_SIZE) pe_lu (match_lu, id_lu, hit_lu);
priority_encoder #(CACHE_SIZE) pe_sp (~valid, id_space, has_space);
priority_encoder #(CACHE_SIZE) pe_pop (valid, id_pop, has_entry);

// Pre-update logic (to avoid blocking assignment in always_ff)
// Mixed non-/blocking assignment may cause verilator to wrongly
// advance a sync result before its clock edge, as if combinational
always_comb begin
    // Update (insert/delete)
    mask_wr = '0;
    mask_del = '0;
    if (wena) begin
        if (hit_upd) begin  // Entry is found, overrides potential deletion
            mask_wr[id_upd] = 1'b1;
        end else if (has_space) begin   // Key is not found, find a place to put in
            mask_wr[id_space] = 1'b1;
        end
        // Else: not found and no space, do nothing
    end else if (dena && hit_upd) begin
        mask_del = match_upd;   // Delete every matched entry
    end
    // The paired ("value") memory takes updHit and updId as write input, if any
    // However it has nothing to do for deletion as the valid marker is maintained here

    // Pop (i.e. delete) the first valid entry
    if (has_entry && pop)
        mask_del[id_pop] = 1'b1;
end

always_ff @ (posedge clk) begin
    // Update memory content when needed
    if (wena && !hit_upd && has_space)
        mem[id_space] <= updData;
    // Merge insertion and deletion, or clear for reset
    // Insertion's mask overrides deletion as deletion is for the old KV-pair
    if (rst) valid <= '0;
    else valid <= valid & (~mask_del) | mask_wr;
end

// Wiring the outputs
assign full = !has_space;
assign luHit = hit_lu;
assign luId = id_lu;
assign updHit = wena && (hit_upd || has_space);
assign updId = hit_upd ? id_upd : id_space;
assign hasEntry = has_entry;
assign popId = id_pop;
assign popData = mem[popId];

endmodule
