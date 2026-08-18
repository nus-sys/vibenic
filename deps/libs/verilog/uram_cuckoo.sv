`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 16.12.2020 19:56:12
// Design Name: 
// Module Name: uram_cuckoo
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


module uram_cuckoo #(
    parameter KEY_WIDTH = 32,
    parameter VAL_WIDTH = 32,
    parameter NUM_HASHES = 2,
    parameter TABLE_SIZE = 1024,
    parameter RAM_NPIPE = 2,
    parameter MAX_TRIAL = 2 * $clog2(TABLE_SIZE),
    parameter DEL_VALMATCH = 0
) (
    input  logic clk,
    input  logic rst,
    input  logic [KEY_WIDTH-1:0] luKey,
    input  logic [KEY_WIDTH-1:0] updKey,
    input  logic [VAL_WIDTH-1:0] updVal,
    input  logic wena,
    input  logic dena,
    input  logic drainReady,
    output logic updReady,
    output logic luHit,
    output logic [VAL_WIDTH-1:0] luVal,
    output logic drainValid,
    output logic [KEY_WIDTH-1:0] drainKey,
    output logic [VAL_WIDTH-1:0] drainVal
);

localparam ADDR_WIDTH = $clog2(TABLE_SIZE);

reg  [KEY_WIDTH-1:0] lu_hashedKey;
reg  [KEY_WIDTH-1:0] lu_queriedKey [0:RAM_NPIPE];
wire [ADDR_WIDTH-1:0] lu_addr [0:NUM_HASHES-1];
wire [(KEY_WIDTH+VAL_WIDTH)-1:0] lu_data [0:NUM_HASHES-1];
wire [NUM_HASHES-1:0] lu_valids;
wire [NUM_HASHES-1:0] lu_hits;
wire [$clog2(NUM_HASHES)-1:0] lu_tableSel;
wire lu_anyHit;
reg  lu_scratchHit [0:RAM_NPIPE];
reg  lu_scratchDel [0:RAM_NPIPE];
reg  lu_drainHit [0:RAM_NPIPE];

reg  [KEY_WIDTH-1:0] upd_queriedKey;
wire [ADDR_WIDTH-1:0] upd_addr [0:NUM_HASHES-1];
wire [(KEY_WIDTH+VAL_WIDTH)-1:0] upd_dataOut [0:NUM_HASHES-1];
reg  [(KEY_WIDTH+VAL_WIDTH)-1:0] upd_dataIn;
wire [(KEY_WIDTH+VAL_WIDTH)-1:0] upd_dataInExt [0:NUM_HASHES-1];
wire [KEY_WIDTH-1:0] upd_hashKey;
reg  [NUM_HASHES-1:0] upd_wrEn, upd_delEn;
wire [NUM_HASHES-1:0] upd_valids;
wire [NUM_HASHES-1:0] upd_hits;
wire [$clog2(NUM_HASHES)-1:0] upd_dataSel, upd_spaceSel;
wire upd_anyHit, upd_anySpace;

reg [KEY_WIDTH-1:0] scratch_key;
reg [VAL_WIDTH-1:0] scratch_val;
reg [VAL_WIDTH-1:0] scratch_prevVal [0:RAM_NPIPE];
reg [VAL_WIDTH-1:0] drain_prevVal [0:RAM_NPIPE];
reg scratch_valid;

reg [$clog2(NUM_HASHES)-1:0] replace_tableSel;
reg [$clog2(MAX_TRIAL):0] replace_count;

enum {IDLE, KICK, QUERY, ACT, GIVEUP} upd_state;
enum {NONE, INS, DEL} upd_op;
reg [$clog2(RAM_NPIPE):0] upd_queryStage;

uram_bank #(
    .DWIDTH(KEY_WIDTH+VAL_WIDTH),
    .AWIDTH(ADDR_WIDTH),
    .NUM_BANKS(NUM_HASHES),
    .NBPIPE(RAM_NPIPE - 1)  // 1 stage of uram inherent latency 
) uram_inst (
    .clk(clk),
    .rst(rst),
    .dataInA(upd_dataInExt),
    .addrA(upd_addr),
    .addrB(lu_addr),
    .wrenA(upd_wrEn),
    .delenA(upd_delEn),
    .dataOutA(upd_dataOut),
    .dataOutB(lu_data),
    .validOutA(upd_valids),
    .validOutB(lu_valids)
);

genvar g;
generate
    for (g = 0; g < NUM_HASHES; g++) begin : hfn_gen_bank
        hash_func #(KEY_WIDTH, ADDR_WIDTH, g) hfn_lu (clk, luKey, lu_addr[g]);
        hash_func #(KEY_WIDTH, ADDR_WIDTH, g) hfn_upd (clk, upd_hashKey, upd_addr[g]);
    end
    for (g = 0; g < NUM_HASHES; g++) begin : query_key_check
        assign lu_hits[g] = (
            lu_data[g][(KEY_WIDTH+VAL_WIDTH)-1:VAL_WIDTH] == lu_queriedKey[RAM_NPIPE]
            && lu_valids[g]) ? 1'b1 : 1'b0;
        assign upd_hits[g] = (
            upd_dataOut[g][(KEY_WIDTH+VAL_WIDTH)-1:VAL_WIDTH] == upd_queriedKey
            && upd_valids[g]) ? 1'b1 : 1'b0;
    end
    for (g = 0; g < NUM_HASHES; g++)
        assign upd_dataInExt[g] = upd_dataIn;
endgenerate

priority_encoder #(NUM_HASHES) pe_lu_mux (lu_hits, lu_tableSel, lu_anyHit);
assign luVal = lu_scratchHit[RAM_NPIPE] ? scratch_prevVal[RAM_NPIPE] : 
    lu_anyHit ? lu_data[lu_tableSel][VAL_WIDTH-1:0] : drain_prevVal[RAM_NPIPE];
assign luHit = lu_scratchDel[RAM_NPIPE] ? 1'b0 : 
    (lu_scratchHit[RAM_NPIPE] || lu_anyHit || lu_drainHit[RAM_NPIPE]);

// Key pipeline corresponding to hash function and BRAM
int i;
always_ff @ (posedge clk) begin : op_key_ppl
    lu_hashedKey <= luKey;
    lu_queriedKey[0] <= lu_hashedKey;
    lu_scratchHit[0] <= scratch_valid && (scratch_key == lu_hashedKey) ?
        DEL_VALMATCH == 0 || (DEL_VALMATCH == 1 && upd_op != DEL) : 1'b0;
    lu_scratchDel[0] <= scratch_valid && (scratch_key == lu_hashedKey) ? upd_op == DEL 
        && (DEL_VALMATCH == 0 || (DEL_VALMATCH == 1 && upd_delEn != '0)) : 1'b0;
    lu_drainHit[0] <= drainValid && (drainKey == lu_hashedKey);
    scratch_prevVal[0] <= scratch_val;
    drain_prevVal[0] <= drainVal;
    for (i = 1; i <= RAM_NPIPE; i++) begin
        lu_queriedKey[i] <= lu_queriedKey[i-1];
        lu_scratchHit[i] <= lu_scratchHit[i-1];
        lu_scratchDel[i] <= lu_scratchDel[i-1];
        lu_drainHit[i] <= lu_drainHit[i-1];
        scratch_prevVal[i] <= scratch_prevVal[i-1];
        drain_prevVal[i] <= drain_prevVal[i-1];
    end
end

// Update state-machine
always @ (posedge clk) begin : upd_sm_logic
    if (upd_state == IDLE && (wena || dena)) begin
        // The hash function completes h(updKey) in this cycle as well
        scratch_key <= updKey;
        scratch_val <= updVal;
        scratch_valid <= 1'b1;
        upd_wrEn <= '0;
        upd_delEn <= '0;
        replace_tableSel <= '0;
        replace_count <= '0;
        upd_state <= QUERY;
        upd_queryStage <= 0;
        if (wena) upd_op <= INS;
        else upd_op <= DEL;
    end else if (upd_state == QUERY) begin
        upd_queryStage <= upd_queryStage + 1;
        if (upd_queryStage == RAM_NPIPE) begin
            upd_queriedKey <= scratch_key;
            upd_state <= ACT;
        end
    end else if (upd_state == ACT && upd_op == INS) begin
        if (upd_anyHit) begin   // The key is already in HT, Updates value
            upd_wrEn[upd_dataSel] <= 1'b1;
            upd_dataIn <= {scratch_key, scratch_val};
            upd_state <= IDLE;
        end else if (upd_anySpace) begin    // The key is not in HT but can be inserted
            upd_wrEn[upd_spaceSel] <= 1'b1;
            upd_dataIn <= {scratch_key, scratch_val};
            upd_state <= IDLE;
        end else begin  // The key is not in HT AND cannot be inserted, perform kick
            upd_wrEn[replace_tableSel] <= 1'b1;
            upd_dataIn <= {scratch_key, scratch_val};
            upd_state <= KICK;
        end
    end else if (upd_state == ACT && upd_op == DEL) begin
        if (upd_anyHit && (DEL_VALMATCH == 0 ||
                (DEL_VALMATCH == 1 && upd_dataOut[upd_dataSel][VAL_WIDTH-1:0] == scratch_val))) begin
            upd_delEn[upd_dataSel] <= 1'b1;
        end
        upd_state <= IDLE;
    end else if (upd_state == KICK) begin
        upd_wrEn <= '0;
        upd_delEn <= '0;
        scratch_key <= upd_dataOut[replace_tableSel][(KEY_WIDTH+VAL_WIDTH)-1:VAL_WIDTH];
        scratch_val <= upd_dataOut[replace_tableSel][VAL_WIDTH-1:0];
        scratch_valid <= 1'b1;
        replace_tableSel <= (replace_tableSel == NUM_HASHES - 1) ? '0 : replace_tableSel + 1;
        replace_count <= replace_count + 1;
        if (replace_count >= MAX_TRIAL)
            upd_state <= GIVEUP;
        else
            upd_state <= QUERY;
    end else if (upd_state == GIVEUP) begin
        drainKey <= scratch_key;    // Overwrite the drain - upper design should ensure reading in time
        drainVal <= scratch_val;
        upd_state <= IDLE;
    end else begin  // The other case: (idle, !wena, !dena) => no op.
        upd_wrEn <= '0;
        upd_delEn <= '0;
        replace_tableSel <= '0;
        replace_count <= '0;
        scratch_valid <= 1'b0;
        upd_state <= IDLE;
        upd_op <= NONE;
    end
    if (upd_state == GIVEUP)
        drainValid <= 1'b1;
    else if (drainReady && drainValid)
        drainValid <= 1'b0;
end

initial begin
    upd_state = IDLE;
    scratch_valid = 1'b0;
    replace_count = '0;
    replace_tableSel = '0;
    drainValid = 1'b0;
end

priority_encoder #(NUM_HASHES) pe_upd_data (upd_hits, upd_dataSel, upd_anyHit);
priority_encoder #(NUM_HASHES) pe_upd_space (~upd_valids, upd_spaceSel, upd_anySpace);
assign upd_hashKey = (upd_state == KICK) ? upd_dataOut[replace_tableSel][(KEY_WIDTH+VAL_WIDTH)-1:VAL_WIDTH] :
                     (upd_state == IDLE && (wena || dena)) ? updKey : scratch_key;
assign updReady = (upd_state == IDLE) ? 1'b1 : 1'b0;

endmodule
