`timescale 1ns / 1ps

module uram_bank #(
    parameter AWIDTH = 10,
    parameter DWIDTH = 64,
    parameter NUM_BANKS = 2,
    parameter NBPIPE = 1
) (
    input  logic clk,
    input  logic rst,
    input  logic [DWIDTH-1:0] dataInA [0:NUM_BANKS-1],
    input  logic [AWIDTH-1:0] addrA [0:NUM_BANKS-1],
    input  logic [AWIDTH-1:0] addrB [0:NUM_BANKS-1],
    input  logic [NUM_BANKS-1:0] wrenA,
    input  logic [NUM_BANKS-1:0] delenA,
    output logic [DWIDTH-1:0] dataOutA [0:NUM_BANKS-1],
    output logic [DWIDTH-1:0] dataOutB [0:NUM_BANKS-1],
    output logic [NUM_BANKS-1:0] validOutA,
    output logic [NUM_BANKS-1:0] validOutB
);

localparam NUM_ENTRIES = 2**AWIDTH;

genvar g;
generate
    for (g = 0; g < NUM_BANKS; g++) begin : uram_gen_blk
        uram_infer #(AWIDTH, DWIDTH, NBPIPE) uram_inst (
            .clk(clk),
            // Port A
            .rsta(rst),             // Reset
            .wea(wrenA[g]),         // Write Enable
            .regcea(1'b1),          // Output Register Enable
            .mem_ena(1'b1),         // Memory Enable
            .dina(dataInA[g]),      // Data Input
            .addra(addrA[g]),       // Address Input
            .douta(dataOutA[g]),    // Data Output
            // Port B
            .rstb(rst),             // Reset
            .web(1'b0),             // Write Enable
            .regceb(1'b1),          // Output Register Enable
            .mem_enb(1'b1),         // Memory Enable
            .dinb('0),              // Data Input
            .addrb(addrB[g]),       // Address Input
            .doutb(dataOutB[g])     // Data Output
        );
    end

    for (g = 0; g < NUM_BANKS; g++) begin : valid_gen_blk
        (* ram_style = "block" *) reg valid [NUM_ENTRIES-1:0];
        reg vra, vrb;
        reg vpa [NBPIPE-1:0];
        reg vpb [NBPIPE-1:0];
        reg wiping, wiped;
        reg [$clog2(NUM_ENTRIES):0] wiping_cnt;
        int i;
        initial for (i = 0; i < NUM_ENTRIES; i++) valid[i] = 1'b0;
        initial begin
            wiping = 1'b0;
            wiped = 1'b0;
            wiping_cnt = 0;
        end
        // Valid marking operations
        always @ (posedge clk) begin
            if (rst && !wiped) begin
                wiping <= 1;
                wiped <= 1;
            end else if (wiping) begin
                valid[wiping_cnt] <= 1'b0;
                wiping_cnt <= wiping_cnt + 1;
                wiping <= wiping_cnt >= NUM_ENTRIES - 1 ? 0 : 1;
            end else begin
                if (wrenA[g])
                    valid[addrA[g]] <= 1'b1;
                else if (delenA[g])
                    valid[addrA[g]] <= 1'b0;
                else
                    vra <= valid[addrA[g]];
                vrb <= valid[addrB[g]];
            end
        end
        // Output valid pipeline
        always @ (posedge clk) begin
            vpa[0] <= vra;
            vpb[0] <= vrb;
            for (i = 0; i < NBPIPE - 1; i++) begin
                vpa[i+1] <= vpa[i];
                vpb[i+1] <= vpb[i];
            end
            if (rst) begin
                validOutA[g] <= '0;
                validOutB[g] <= '0;
            end else begin
                validOutA[g] <= vpa[NBPIPE-1];
                validOutB[g] <= vpb[NBPIPE-1];
            end
        end
    end
endgenerate

endmodule
