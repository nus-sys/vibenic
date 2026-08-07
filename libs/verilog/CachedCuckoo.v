`timescale 1ns/1ps

module CachedCuckoo #(
    parameter KEY_WIDTH = 32,
    parameter VAL_WIDTH = 32,
    parameter CACHE_SIZE = 8,
    parameter NUM_VICTIM = 8,
    parameter NUM_HASHES = 2,
    parameter TABLE_SIZE = 1024,
    parameter RAM_NPIPE = 2,
    parameter MAX_TRIAL = 20,
    parameter DEL_VALMATCH = 0
) (
    input  wire                 clk,
    input  wire                 rstn,
    // Lookup: II=1, result ready in the next cycle
    // MSB of luRes indicates if the result is valid (found).
    input  wire [KEY_WIDTH-1:0]             luKey,
    input  wire                             luEna,
    output wire                             luRdy,
    output wire [VAL_WIDTH:0]               luRes,
    // Update: updReq := {del/~wr, key, val}
    input  wire [(KEY_WIDTH+VAL_WIDTH):0]   updReq,
    input  wire                             updEna,
    output wire                             updRdy,
    // Victim drain: vicKvp := {key, val}
    input  wire                             vicPop,
    output wire                             vicAvail,
    output wire [(KEY_WIDTH+VAL_WIDTH-1):0] vicKvp
);

reg [RAM_NPIPE+1:0] luEff;
assign luRdy = luEff[0];

integer i;
always @ (posedge clk) begin
    if (!rstn)
        luEff <= 0;
    else begin
        luEff[RAM_NPIPE+1] <= luEna;
        for (i = 0; i < RAM_NPIPE + 1; i = i + 1)
            luEff[i] <= luEff[i + 1];
    end
end

wire updBusy;
assign updRdy = ~updBusy;

wire luHit;
wire [VAL_WIDTH-1:0] luVal;
assign luRes = {luHit, luVal};

wire [KEY_WIDTH-1:0] vicKey;
wire [VAL_WIDTH-1:0] vicVal;
assign vicKvp = {vicKey, vicVal};

cached_cuckoo #(
    .KEY_WIDTH      (KEY_WIDTH),
    .VAL_WIDTH      (VAL_WIDTH),
    .CACHE_SIZE     (CACHE_SIZE),
    .NUM_VICTIM     (NUM_VICTIM),
    .NUM_HASHES     (NUM_HASHES),
    .TABLE_SIZE     (TABLE_SIZE),
    .RAM_NPIPE      (RAM_NPIPE),
    .MAX_TRIAL      (MAX_TRIAL),
    .DEL_VALMATCH   (DEL_VALMATCH)
) ccht_inst (
    .clk        (clk),
    .rst        (~rstn),
    .luKey      (luKey),
    .wrEn       (updEna & ~updReq[KEY_WIDTH+VAL_WIDTH]),
    .delEn      (updEna & updReq[KEY_WIDTH+VAL_WIDTH]),
    .updKey     (updReq[(KEY_WIDTH+VAL_WIDTH-1):VAL_WIDTH]),
    .updVal     (updReq[(VAL_WIDTH-1):0]),
    .vicPop     (vicPop),
    .busy       (updBusy),
    .luHit      (luHit),
    .luVal      (luVal),
    .vicAvail   (vicAvail),
    .vicKey     (vicKey),
    .vicVal     (vicVal)
);

endmodule