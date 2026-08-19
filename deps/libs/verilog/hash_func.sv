// Copyright (c) 2020-2026 Yunfan Li
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 25.11.2020 16:44:54
// Design Name: 
// Module Name: hash_func
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


module hash_func #(
    parameter IN_WIDTH = 32,
    parameter OUT_WIDTH = 5,
    parameter HASH_ID = 0
) (
    input  logic clk,
    input  logic [IN_WIDTH-1:0] vecIn,
    output logic [OUT_WIDTH-1:0] vecOut
);

// Vanilla implementation, consider using randomized table
always_ff @ (posedge clk) begin
    localparam EXT_WIDTH = OUT_WIDTH - (IN_WIDTH % OUT_WIDTH);
    localparam RATIO = IN_WIDTH / OUT_WIDTH;
    logic [EXT_WIDTH-1:0] ext_zero;
    logic [OUT_WIDTH*RATIO-1:0] ext_in;
    logic [OUT_WIDTH-1:0] base, salt;
    int i;
    ext_zero = '0;
    ext_in = {ext_zero, vecIn};
    base = '0;
    salt = '0;
    for (i = 0; i < 3 * OUT_WIDTH; i++)
        salt[i % OUT_WIDTH] ^= 
            vecIn[(7 * (HASH_ID + 2) * i) % IN_WIDTH] ^ 
            vecIn[(11 * (HASH_ID + 1) * i) % IN_WIDTH];
    for (i = 0; i < RATIO; i++)
        base ^= ext_in[i * OUT_WIDTH +: OUT_WIDTH];
//    vecOut = salt ^ base + HASH_ID;
    // Test collision set
    // if (vecIn == 'hb1)
    //     vecOut = (HASH_ID == 0) ? 'h1 : 'h2;
    // else if (vecIn == 'hb2)
    //     vecOut = (HASH_ID == 0) ? 'h1 : 'h3;
    // else if (vecIn == 'hb3)
    //     vecOut = (HASH_ID == 0) ? 'h2 : 'h5;
    // else if (vecIn == 'hb4)
    //     vecOut = (HASH_ID == 0) ? 'h2 : 'h3;
    // else if (vecIn == 'hb5)
    //     vecOut = (HASH_ID == 0) ? 'h4 : 'h5;
    // else if (vecIn == 'hb6)
    //     vecOut = (HASH_ID == 0) ? 'h4 : 'h3;
    // else
        vecOut = salt ^ base + HASH_ID;
end

endmodule
