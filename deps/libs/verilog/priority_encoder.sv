`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 24.11.2020 23:48:09
// Design Name: 
// Module Name: priority_encoder
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


module priority_encoder #(
    parameter VEC_WIDTH = 16
) (
    input  logic [VEC_WIDTH-1:0] matchVec,
    output logic [$clog2(VEC_WIDTH)-1:0] index,
    output logic valid
);

assign valid = |matchVec;

function logic [1:0] pri4 (input logic [3:0] vec);
    casez (vec)
        4'b???1: pri4 = 2'd0;
        4'b??10: pri4 = 2'd1;
        4'b?100: pri4 = 2'd2;
        4'b1000: pri4 = 2'd3;
        default: pri4 = 2'd0;
    endcase
endfunction

function logic [2:0] pri8 (input logic [7:0] vec);
    casez (vec)
        8'b????_???1: pri8 = 3'd0;
        8'b????_??10: pri8 = 3'd1;
        8'b????_?100: pri8 = 3'd2;
        8'b????_1000: pri8 = 3'd3;
        8'b???1_0000: pri8 = 3'd4;
        8'b??10_0000: pri8 = 3'd5;
        8'b?100_0000: pri8 = 3'd6;
        8'b1000_0000: pri8 = 3'd7;
        default: pri8 = 3'd0;
    endcase
endfunction

generate
    if (VEC_WIDTH == 2)
        always_comb index = ~matchVec[0];
    else if (VEC_WIDTH == 4)
        always_comb index = pri4(matchVec);
    else if (VEC_WIDTH == 8)
        always_comb index = pri8(matchVec);
    else if (VEC_WIDTH == 16)
        always_comb index =
            (|matchVec[7:0]) ? {1'b0, pri8(matchVec[7:0])} : {1'b1, pri8(matchVec[15:8])};
    else if (VEC_WIDTH == 32) 
        always_comb begin
            logic [1:0] msb;
            msb = pri4({|matchVec[31:24], |matchVec[23:16], |matchVec[15:8], |matchVec[7:0]});
            index = (msb == 2'd0) ? {msb, pri8(matchVec[7:0])} :
                    (msb == 2'd1) ? {msb, pri8(matchVec[15:8])} :
                    (msb == 2'd2) ? {msb, pri8(matchVec[23:16])} : {msb, pri8(matchVec[31:24])};
        end
    else $error("Vector width not supported.");
endgenerate

endmodule
