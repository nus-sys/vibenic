`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 17.12.2020 12:43:41
// Design Name: 
// Module Name: uram_infer
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


module uram_infer #(
    parameter AWIDTH = 12,  // Address Width
    parameter DWIDTH = 72,  // Data Width
    parameter NBPIPE = 1    // Pipeline Stages 
) (
    input wire clk,
    // Port A
    input wire rsta,                    // Reset
    input wire wea,                     // Write Enable
    input wire regcea,                  // Output Register Enable
    input wire mem_ena,                 // Memory Enable
    input wire [DWIDTH-1:0] dina,       // Data Input
    input wire [AWIDTH-1:0] addra,      // Address Input
    output reg [DWIDTH-1:0] douta,      // Data Output
    // Port B
    input wire rstb,                    // Reset
    input wire web,                     // Write Enable
    input wire regceb,                  // Output Register Enable
    input wire mem_enb,                 // Memory Enable
    input wire [DWIDTH-1:0] dinb,       // Data Input
    input wire [AWIDTH-1:0] addrb,      // Address Input
    output reg [DWIDTH-1:0] doutb       // Data Output
);

//  Xilinx UltraRAM True Dual Port Mode.  This code implements 
//  a parameterizable UltraRAM block with write/read on both ports in 
//  No change behavior on both the ports . The behavior of this RAM is 
//  when data is written, the output of RAM is unchanged w.r.t each port. 
//  Only when write is inactive data corresponding to the address is 
//  presented on the output port.

(* ram_style = "ultra" *)
reg [DWIDTH-1:0] mem[(1<<AWIDTH)-1:0];        // Memory Declaration

reg [DWIDTH-1:0] memrega;
reg [DWIDTH-1:0] mem_pipe_rega[NBPIPE-1:0];    // Pipelines for memory
reg mem_en_pipe_rega[NBPIPE:0];                // Pipelines for memory enable

reg [DWIDTH-1:0] memregb;
reg [DWIDTH-1:0] mem_pipe_regb[NBPIPE-1:0];    // Pipelines for memory
reg mem_en_pipe_regb[NBPIPE:0];                // Pipelines for memory enable
integer i;

// RAM : Both READ and WRITE have a latency of one
always @ (posedge clk) begin
    if (mem_ena) begin
        if (wea)
            mem[addra] <= dina;
        else
            memrega <= mem[addra];
    end
end

// The enable of the RAM goes through a pipeline to produce a
// series of pipelined enable signals required to control the data
// pipeline.
always @ (posedge clk) begin
    mem_en_pipe_rega[0] <= mem_ena;
    for (i=0; i<NBPIPE; i=i+1)
        mem_en_pipe_rega[i+1] <= mem_en_pipe_rega[i];
end

// RAM output data goes through a pipeline.
always @ (posedge clk) begin
    if (mem_en_pipe_rega[0])
        mem_pipe_rega[0] <= memrega;
end

always @ (posedge clk) begin
    for (i = 0; i < NBPIPE-1; i = i+1)
        if (mem_en_pipe_rega[i+1])
            mem_pipe_rega[i+1] <= mem_pipe_rega[i];
end

// Final output register gives user the option to add a reset and
// an additional enable signal just for the data ouptut
always @ (posedge clk) begin
    if (rsta)
        douta <= 0;
    else if (mem_en_pipe_rega[NBPIPE] && regcea)
        douta <= mem_pipe_rega[NBPIPE-1];
end

always @ (posedge clk) begin
    if (mem_enb) begin
        if (web)
            mem[addrb] <= dinb;
        else
            memregb <= mem[addrb];
    end
end

// The enable of the RAM goes through a pipeline to produce a
// series of pipelined enable signals required to control the data
// pipeline.
always @ (posedge clk) begin
    mem_en_pipe_regb[0] <= mem_enb;
    for (i=0; i<NBPIPE; i=i+1)
        mem_en_pipe_regb[i+1] <= mem_en_pipe_regb[i];
end

// RAM output data goes through a pipeline.
always @ (posedge clk) begin
    if (mem_en_pipe_regb[0])
        mem_pipe_regb[0] <= memregb;
end    

always @ (posedge clk) begin
    for (i = 0; i < NBPIPE-1; i = i+1)
        if (mem_en_pipe_regb[i+1])
            mem_pipe_regb[i+1] <= mem_pipe_regb[i];
end      

// Final output register gives user the option to add a reset and
// an additional enable signal just for the data ouptut
always @ (posedge clk) begin
    if (rstb)
        doutb <= 0;
    else if (mem_en_pipe_regb[NBPIPE] && regceb)
        doutb <= mem_pipe_regb[NBPIPE-1];
end

endmodule
