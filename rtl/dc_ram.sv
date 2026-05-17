// ============================================================================
// dc_ram -- unified RAM model. One physical 32-bit word-addressed memory that
// holds code, data, image/tensor/weight tiles, framebuffer and tile metadata.
// Synchronous, single port, 1-cycle read latency.
// ============================================================================
module dc_ram #(
  parameter int AW = 16,
  parameter int DW = 32
)(
  input  logic            clk,
  input  logic            en,
  input  logic            we,
  input  logic [AW-1:0]   addr,
  input  logic [DW-1:0]   wdata,
  output logic [DW-1:0]   rdata
);
  logic [DW-1:0] mem [0:(1<<AW)-1];

  always_ff @(posedge clk) begin
    if (en) begin
      if (we) mem[addr] <= wdata;
      rdata <= mem[addr];          // old value on a write; writers ignore it
    end
  end

  // load helper for the testbench
  task automatic load_hex(input string path);
    $readmemh(path, mem);
  endtask
  task automatic dump_word(input int unsigned a, output logic [DW-1:0] d);
    d = mem[a];
  endtask
endmodule
