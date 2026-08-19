// Copyright (c) 2025-2026 Yunfan Li
// SPDX-License-Identifier: Apache-2.0

// ============================================================================
// cuckoo_hash8_16_ultra_dsp_final.v
// 8 orthogonal 16-bit hashes from a 256-bit input (UltraScale+ tuned).
// - Two SPN rounds (A0,B0,A1,B1) with 4-bit S-boxes + GF(16) MDS
// - Final stage uses 1 DSP48E2 per output: P = (lane * const) + addend
// - Latency: 5 cycles, Throughput: 1/cycle
// ============================================================================

module cuckoo_hash8_16_ultra_dsp_final #(
    // keep 2 rounds, 5 stages
    parameter bit PIPE_A0 = 1,
    parameter bit PIPE_B0 = 1,
    parameter bit PIPE_A1 = 1,
    parameter bit PIPE_B1 = 1,
    parameter bit PIPE_F  = 1
)(
    input  logic         clk,
    input  logic         rst_n,     // sync active-low reset
    input  logic         valid_in,
    input  logic [255:0] din,
    output logic         valid_out,
    output logic [15:0]  h0, h1, h2, h3, h4, h5, h6, h7,
    output logic [127:0] hvec       // concatenation of h0-7
);

    // ------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------
    function automatic logic [15:0] rol16(input logic [15:0] x, input int unsigned r);
        logic [4:0] rr;
        begin
            rr    = r & 5'd15;
            rol16 = ((x << rr) | (x >> (16 - rr)));
        end
    endfunction

    // PRESENT S-box (4-bit)
    function automatic logic [3:0] sbox4(input logic [3:0] a);
        case (a)
            4'h0: sbox4 = 4'hC; 4'h1: sbox4 = 4'h5; 4'h2: sbox4 = 4'h6; 4'h3: sbox4 = 4'hB;
            4'h4: sbox4 = 4'h9; 4'h5: sbox4 = 4'h0; 4'h6: sbox4 = 4'hA; 4'h7: sbox4 = 4'hD;
            4'h8: sbox4 = 4'h3; 4'h9: sbox4 = 4'hE; 4'hA: sbox4 = 4'hF; 4'hB: sbox4 = 4'h8;
            4'hC: sbox4 = 4'h4; 4'hD: sbox4 = 4'h7; 4'hE: sbox4 = 4'h1; 4'hF: sbox4 = 4'h2;
        endcase
    endfunction
    function automatic logic [15:0] sbox16(input logic [15:0] x);
        sbox16 = { sbox4(x[15:12]), sbox4(x[11:8]), sbox4(x[7:4]), sbox4(x[3:0]) };
    endfunction

    // GF(16) multiply helpers (poly x^4 + x + 1)
    function automatic logic [3:0] gf16_xtime2(input logic [3:0] a);
        gf16_xtime2 = {a[2], a[1], a[0]^a[3], a[3]};
    endfunction
    function automatic logic [3:0] gf16_mul4 (input logic [3:0] a); gf16_mul4  = gf16_xtime2(gf16_xtime2(a)); endfunction
    function automatic logic [3:0] gf16_mul8 (input logic [3:0] a); gf16_mul8  = gf16_xtime2(gf16_mul4(a));  endfunction
    function automatic logic [3:0] gf16_mul9 (input logic [3:0] a); gf16_mul9  = gf16_mul8(a) ^ a;          endfunction
    function automatic logic [3:0] gf16_mul13(input logic [3:0] a); gf16_mul13 = gf16_mul8(a) ^ gf16_mul4(a) ^ a; endfunction
    function automatic logic [15:0] mds16(input logic [15:0] x);
        logic [3:0] n0,n1,n2,n3, o0,o1,o2,o3;
        begin
            n0 = x[ 3: 0]; n1 = x[ 7: 4]; n2 = x[11: 8]; n3 = x[15:12];
            o0 = n0 ^ gf16_mul4(n1) ^ gf16_mul9(n2) ^ gf16_mul13(n3);
            o1 = gf16_mul13(n0) ^ n1 ^ gf16_mul4(n2) ^ gf16_mul9(n3);
            o2 = gf16_mul9(n0)  ^ gf16_mul13(n1) ^ n2 ^ gf16_mul4(n3);
            o3 = gf16_mul4(n0)  ^ gf16_mul9(n1)  ^ gf16_mul13(n2) ^ n3;
            mds16 = {o3,o2,o1,o0};
        end
    endfunction

    // salts / rotates
    localparam logic [15:0] K  [0:7] = '{16'h9E37,16'h85EB,16'hC2B2,16'h27D4,16'h1657,16'hDEAD,16'hBEEF,16'hA5A5};
    localparam int  unsigned R  [0:7] = '{1,3,6,10,15,7,12,4};
    // DSP multiplier constants (odd, distinct)
    localparam logic [15:0] M  [0:8] = '{16'hD251,16'h9E37,16'h85EB,16'hC2B3,16'h27D5,16'h94D0,16'h3C6F,16'hBB67,16'hA54F};

    // ------------------------------------------------------------------------
    // Slice input into 16x16-bit words
    // ------------------------------------------------------------------------
    logic [15:0] w0 [0:15];
    for (genvar gi=0; gi<16; gi++) begin : SLICE
        assign w0[gi] = din[gi*16 +: 16];
    end

    // ------------------------------------------------------------------------
    // Round 0: A0 (premix + sbox), B0 (mds)
    // ------------------------------------------------------------------------
    logic [15:0] a0 [0:15], r_a0 [0:15];
    logic        v_a0;
    always_comb begin
        for (int i=0;i<16;i++) begin
            logic [15:0] mix = w0[i]
                             ^ rol16(w0[(i+5)  & 15], 1)
                             ^ rol16(w0[(i+9)  & 15], 8)
                             ^ rol16(w0[(i+13) & 15], 3);
            a0[i] = sbox16(mix);
        end
    end
    generate
        if (PIPE_A0) begin : PA0
            always_ff @(posedge clk) begin
                if (!rst_n) begin v_a0<=1'b0; for (int i=0;i<16;i++) r_a0[i]<='0; end
                else begin v_a0<=valid_in;     for (int i=0;i<16;i++) r_a0[i]<=a0[i]; end
            end
        end else begin : PA0B
            always_comb v_a0 = valid_in;
            for (genvar j=0;j<16;j++) assign r_a0[j] = a0[j];
        end
    endgenerate

    logic [15:0] b0 [0:15], r_b0 [0:15];
    logic        v_b0;
    always_comb begin
        for (int i=0;i<16;i++) b0[i] = mds16(r_a0[i]);
    end
    generate
        if (PIPE_B0) begin : PB0
            always_ff @(posedge clk) begin
                if (!rst_n) begin v_b0<=1'b0; for (int i=0;i<16;i++) r_b0[i]<='0; end
                else begin v_b0<=v_a0;        for (int i=0;i<16;i++) r_b0[i]<=b0[i]; end
            end
        end else begin : PB0B
            always_comb v_b0 = v_a0;
            for (genvar j=0;j<16;j++) assign r_b0[j] = b0[j];
        end
    endgenerate

    // ------------------------------------------------------------------------
    // Round 1: A1 (premix + sbox), B1 (mds)
    // ------------------------------------------------------------------------
    logic [15:0] a1 [0:15], r_a1 [0:15];
    logic        v_a1;
    always_comb begin
        for (int i=0;i<16;i++) begin
            logic [15:0] mix = r_b0[i]
                             ^ rol16(r_b0[(i+7)  & 15], 2)
                             ^ rol16(r_b0[(i+10) & 15], 9)
                             ^ rol16(r_b0[(i+14) & 15], 5);
            a1[i] = sbox16(mix);
        end
    end
    generate
        if (PIPE_A1) begin : PA1
            always_ff @(posedge clk) begin
                if (!rst_n) begin v_a1<=1'b0; for (int i=0;i<16;i++) r_a1[i]<='0; end
                else begin v_a1<=v_b0;        for (int i=0;i<16;i++) r_a1[i]<=a1[i]; end
            end
        end else begin : PA1B
            always_comb v_a1 = v_b0;
            for (genvar j=0;j<16;j++) assign r_a1[j] = a1[j];
        end
    endgenerate
    logic [15:0] b1 [0:15], r_b1 [0:15];
    logic        v_b1;
    always_comb begin
        for (int i=0;i<16;i++) b1[i] = mds16(r_a1[i]);
    end
    generate
        if (PIPE_B1) begin : PB1
            always_ff @(posedge clk) begin
                if (!rst_n) begin v_b1<=1'b0; for (int i=0;i<16;i++) r_b1[i]<='0; end
                else begin v_b1<=v_a1;        for (int i=0;i<16;i++) r_b1[i]<=b1[i]; end
            end
        end else begin : PB1B
            always_comb v_b1 = v_a1;
            for (genvar j=0;j<16;j++) assign r_b1[j] = b1[j];
        end
    endgenerate

    // ------------------------------------------------------------------------
    // Final (DSP): h[i] = fold( (r_b1[i] * M[i]) + {0, rol16(r_b1[i+8],R[i])} )
    // Fold to 16 bits + small avalanche.
    // ------------------------------------------------------------------------
    logic [15:0] hout [0:7];
    logic        v_f;

    always_comb begin
        for (int i=0;i<8;i++) begin
            logic [31:0] prod;
            logic [31:0] addend;
            logic [31:0] p;
            logic [15:0] t16;

            // Prepare addend (zero-extend rotated cross-lane)
            addend = {16'h0000, rol16(r_b1[i+8], R[i])};

            // Inference hint for DSP: multiply-add
            (* use_dsp = "yes" *) prod = (r_b1[i] * M[i]); // 16x16 -> 32
            (* use_dsp = "yes" *) p    = prod + addend;    // use DSP adder

            // Fold 32 -> 16 (xor high & low) and add a small salt
            t16 = (p[31:16] ^ p[15:0]) ^ K[i];

            // Tiny xorshift avalanche in 16 bits (wiring + XOR)
            t16 ^= (t16 >> 7);
            t16 ^= (t16 << 9);
            t16 ^= (t16 >> 3);

            hout[i] = t16;
        end
    end

    generate
        if (PIPE_F) begin : PF
            always_ff @(posedge clk) begin
                if (!rst_n) begin
                    {h0,h1,h2,h3,h4,h5,h6,h7} <= '0; v_f <= 1'b0;
                end else begin
                    h0<=hout[0]; h1<=hout[1]; h2<=hout[2]; h3<=hout[3];
                    h4<=hout[4]; h5<=hout[5]; h6<=hout[6]; h7<=hout[7];
                    v_f <= v_b1;
                end
            end
        end else begin : PFB
            always_comb begin
                h0=hout[0]; h1=hout[1]; h2=hout[2]; h3=hout[3];
                h4=hout[4]; h5=hout[5]; h6=hout[6]; h7=hout[7];
            end
            always_comb v_f = v_b1;
        end
    endgenerate

    assign valid_out = v_f;
    assign hvec = {h7,h6,h5,h4,h3,h2,h1,h0};

endmodule
