// Copyright (c) 2020 Bluespec, Inc. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause
//
// Bluespec compiler primitive from the bsc Verilog primitive library,
// redistributed with local modifications.
//
// Modifications Copyright (c) 2025-2026 Yunfan Li, licensed under the
// same BSD-3-Clause terms:
//   generate-select RAM_STYLE = "ULTRA" when MEMSIZE > 1024.


`ifdef BSV_ASSIGNMENT_DELAY
`else
 `define BSV_ASSIGNMENT_DELAY
`endif

// Dual-Ported BRAM (WRITE FIRST)
module BRAM2(CLKA,
             ENA,
             WEA,
             ADDRA,
             DIA,
             DOA,
             CLKB,
             ENB,
             WEB,
             ADDRB,
             DIB,
             DOB
             );

   parameter                      PIPELINED  = 0;
   parameter                      ADDR_WIDTH = 1;
   parameter                      DATA_WIDTH = 1;
   parameter                      MEMSIZE    = 1;

   input                          CLKA;
   input                          ENA;
   input                          WEA;
   input [ADDR_WIDTH-1:0]         ADDRA;
   input [DATA_WIDTH-1:0]         DIA;
   output [DATA_WIDTH-1:0]        DOA;

   input                          CLKB;
   input                          ENB;
   input                          WEB;
   input [ADDR_WIDTH-1:0]         ADDRB;
   input [DATA_WIDTH-1:0]         DIB;
   output [DATA_WIDTH-1:0]        DOB;

generate
if (PIPELINED == 2) begin
   // URAM generation for Xilinx devices
   // True Dual-Port URAM needs 2 stages of internal buffer which is
   // beyond the normal design of BSV's stock BRAM
   // This case will not be hit by normal BSV's generation as they
   // passes either 0 or 1 for PIPELINED parameter. 
   // Only the URAM2 package will fall into this case.

   (* ram_style = "ultra" *)
   reg [DATA_WIDTH-1:0]           URAM[0:MEMSIZE-1] /* synthesis syn_ramstyle="no_rw_check" */ ;
   reg [DATA_WIDTH-1:0]           DOA_R, DOA_PR, DOA_OUTR;
   reg [DATA_WIDTH-1:0]           DOB_R, DOB_PR, DOB_OUTR;
   reg                            PIPE_ENA[1:0];
   reg                            PIPE_ENB[1:0];

   // Promoting it to an UltraRAM. However, UltraRAM does not support independent clock.
   wire clk;
`ifndef SYNTHESIS
   always @ (CLKA or CLKB)
      assert (CLKA == CLKB) else $error("UltraRAM does not support indpendent clocks.");
`endif
   assign clk = CLKA;
   assign DOA = DOA_OUTR;
   assign DOB = DOB_OUTR;

   // RAM : Both READ and WRITE have a latency of one
   always @ (posedge clk) begin
      if (ENA) begin
         if (WEA) URAM[ADDRA] <= DIA;
         else DOA_R <= URAM[ADDRA];
      end
      // The enable of the RAM goes through a pipeline to produce a series
      // of pipelined enable signals required to control the data pipeline.
      PIPE_ENA[0] <= ENA;
      PIPE_ENA[1] <= PIPE_ENA[0];
      // RAM output data goes through a pipeline.
      if (PIPE_ENA[0]) DOA_PR <= DOA_R;
      // Final output register gives user the option to add a reset and
      // an additional enable signal just for the data ouptut
      if (PIPE_ENA[1]) DOA_OUTR <= DOA_PR;
   end

   always @ (posedge clk) begin
      if (ENB) begin
         if (WEB) URAM[ADDRB] <= DIB;
         else DOB_R <= URAM[ADDRB];
      end
      // The enable of the RAM goes through a pipeline to produce a series
      // of pipelined enable signals required to control the data pipeline.
      PIPE_ENB[0] <= ENB;
      PIPE_ENB[1] <= PIPE_ENB[0];
      // RAM output data goes through a pipeline.
      if (PIPE_ENB[0]) DOB_PR <= DOB_R;
      // Final output register gives user the option to add a reset and
      // an additional enable signal just for the data ouptut
      if (PIPE_ENB[1]) DOB_OUTR <= DOB_PR;
   end

end else begin // Normal block RAM with 0/1 stage of pipeline

   reg [DATA_WIDTH-1:0]           RAM[0:MEMSIZE-1] /* synthesis syn_ramstyle="no_rw_check" */ ;
   reg [DATA_WIDTH-1:0]           DOA_R;
   reg [DATA_WIDTH-1:0]           DOB_R;
   reg [DATA_WIDTH-1:0]           DOA_R2;
   reg [DATA_WIDTH-1:0]           DOB_R2;

`ifdef BSV_NO_INITIAL_BLOCKS
`else
   // synopsys translate_off
   integer                        i;
   initial
   begin : init_block
      for (i = 0; i < MEMSIZE; i = i + 1) begin
         RAM[i] = { ((DATA_WIDTH+1)/2) { 2'b10 } };
      end
      DOA_R = { ((DATA_WIDTH+1)/2) { 2'b10 } };
      DOB_R = { ((DATA_WIDTH+1)/2) { 2'b10 } };
      DOA_R2 = { ((DATA_WIDTH+1)/2) { 2'b10 } };
      DOB_R2 = { ((DATA_WIDTH+1)/2) { 2'b10 } };
   end
   // synopsys translate_on
`endif // !`ifdef BSV_NO_INITIAL_BLOCKS

   always @(posedge CLKA) begin
      if (ENA) begin
         if (WEA) begin
            RAM[ADDRA] <= `BSV_ASSIGNMENT_DELAY DIA;
            DOA_R <= `BSV_ASSIGNMENT_DELAY DIA;
         end
         else begin
            DOA_R <= `BSV_ASSIGNMENT_DELAY RAM[ADDRA];
         end
      end
      DOA_R2 <= `BSV_ASSIGNMENT_DELAY DOA_R;
   end

   always @(posedge CLKB) begin
      if (ENB) begin
         if (WEB) begin
            RAM[ADDRB] <= `BSV_ASSIGNMENT_DELAY DIB;
            DOB_R <= `BSV_ASSIGNMENT_DELAY DIB;
         end
         else begin
            DOB_R <= `BSV_ASSIGNMENT_DELAY RAM[ADDRB];
         end
      end
      DOB_R2 <= `BSV_ASSIGNMENT_DELAY DOB_R;
   end

   // Output drivers
   assign DOA = (PIPELINED) ? DOA_R2 : DOA_R;
   assign DOB = (PIPELINED) ? DOB_R2 : DOB_R;

end
endgenerate

endmodule // BRAM2
