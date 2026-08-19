// Copyright (c) 2020 Bluespec, Inc. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause
//
// Bluespec compiler primitive, redistributed verbatim from the bsc
// Verilog primitive library so that a Verilator or Vivado run can
// resolve the primitive closure from a single -y directory.


`ifdef BSV_ASSIGNMENT_DELAY
`else
`define BSV_ASSIGNMENT_DELAY
`endif

module RevertReg(CLK, Q_OUT, D_IN, EN);

   parameter width = 1;
   parameter init  = { width {1'b0} } ;

   input     CLK;
   input     EN;
   input [width - 1 : 0] D_IN;
   output [width - 1 : 0] Q_OUT;

   assign Q_OUT = init;
endmodule
