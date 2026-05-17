// ============================================================================
// tb_arbiter -- stress test for the unified-memory arbiter + RAM.
// All five ports request access at the same time, every cycle, until each has
// been granted. Checks: (1) the arbiter never grants two ports in one cycle,
// (2) every port's write lands at its own address with no cross-corruption.
// This proves shared RAM access is safe under contention.
// ============================================================================
`timescale 1ns/1ps
module tb_arbiter;
  import dc_pkg::*;

  logic clk = 0;
  always #5 clk = ~clk;

  logic [4:0]      req, we_in, gnt;
  logic [5*AW-1:0] addr_in;
  logic [5*DW-1:0] wdata_in;
  logic            ram_en, ram_we;
  logic [AW-1:0]   ram_addr;
  logic [DW-1:0]   ram_wdata, ram_rdata;

  dc_arbiter #(.AW(AW), .DW(DW)) u_arb (
    .req(req), .we_in(we_in), .addr_in(addr_in), .wdata_in(wdata_in),
    .gnt(gnt), .ram_en(ram_en), .ram_we(ram_we),
    .ram_addr(ram_addr), .ram_wdata(ram_wdata));

  dc_ram #(.AW(AW), .DW(DW)) u_ram (
    .clk(clk), .en(ram_en), .we(ram_we),
    .addr(ram_addr), .wdata(ram_wdata), .rdata(ram_rdata));

  logic [4:0]    done;
  logic [AW-1:0] paddr [0:4];
  logic [DW-1:0] pdata [0:4];
  integer i, errors;

  initial begin
    errors = 0;
    for (i = 0; i < 5; i = i + 1) begin
      paddr[i] = 16'h0100 + i[15:0];
      pdata[i] = 32'hCAFE_0000 + i;
    end
    done = 5'b0;

    // every port hammers the bus until it has been granted once
    while (done != 5'b11111) begin
      for (i = 0; i < 5; i = i + 1) begin
        req[i]                  = ~done[i];
        we_in[i]                = ~done[i];
        addr_in [i*AW +: AW]    = paddr[i];
        wdata_in[i*DW +: DW]    = pdata[i];
      end
      @(posedge clk);
      // exactly one grant per active cycle, never two
      if (gnt != 5'b0 && (gnt & (gnt - 1)) != 5'b0) begin
        $display("FAIL: multiple grants %b", gnt); errors = errors + 1;
      end
      for (i = 0; i < 5; i = i + 1)
        if (gnt[i]) done[i] = 1'b1;
    end
    req = 5'b0; we_in = 5'b0;

    // read every word back and verify -- no port clobbered another
    for (i = 0; i < 5; i = i + 1) begin
      req = 5'b00001; we_in = 5'b0;
      addr_in[0*AW +: AW] = paddr[i];
      @(posedge clk);            // grant + RAM read issued
      @(posedge clk);            // rdata valid
      if (ram_rdata !== pdata[i]) begin
        $display("FAIL: addr %h got %h expected %h",
                 paddr[i], ram_rdata, pdata[i]);
        errors = errors + 1;
      end
    end

    if (errors == 0) $display("tb_arbiter: PASS (no corruption, grants safe)");
    else             $display("tb_arbiter: FAIL (%0d errors)", errors);
    $finish;
  end
endmodule
