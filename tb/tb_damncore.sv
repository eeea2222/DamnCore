// ============================================================================
// tb_damncore -- top-level testbench. Loads an assembled program into the
// unified RAM, runs DamnCore to HALT, then dumps the RAM image and core state
// so the Python harness can diff it against the golden reference model.
//
// plusargs:  +PROG=<hex>   +RAMOUT=<file>   +STATEOUT=<file>   +DUMP=<n>
// ============================================================================
`timescale 1ns/1ps
module tb_damncore;
  import dc_pkg::*;

  logic clk = 0, rst = 1, halted;
  always #5 clk = ~clk;

  dc_top dut (
    .clk(clk), .rst(rst),
    .boot_hold(1'b0), .boot_we(1'b0),
    .boot_addr('0), .boot_wdata('0),
    .halted(halted)
  );

  string prog    = "build/prog.hex";
  string ramout  = "build/ram_out.hex";
  string stout   = "build/state_out.txt";
  int    dumplen = 768;
  integer fd, i, cyc;

  initial begin
    void'($value$plusargs("PROG=%s",     prog));
    void'($value$plusargs("RAMOUT=%s",   ramout));
    void'($value$plusargs("STATEOUT=%s", stout));
    void'($value$plusargs("DUMP=%d",     dumplen));

    // clear RAM, then load the program image
    for (i = 0; i < (1<<AW); i = i + 1) dut.u_ram.mem[i] = 32'h0;
    $readmemh(prog, dut.u_ram.mem);

    // reset
    rst = 1; repeat (4) @(posedge clk);
    rst = 0;

    // run to HALT (with a generous cycle guard)
    cyc = 0;
    while (!halted && cyc < 200000) begin
      @(posedge clk);
      cyc = cyc + 1;
    end

    if (!halted)
      $display("TB ERROR: core did not halt after %0d cycles", cyc);
    else
      $display("TB: core halted after %0d cycles", cyc);

    // dump RAM image
    fd = $fopen(ramout, "w");
    for (i = 0; i < dumplen; i = i + 1)
      $fwrite(fd, "%08x\n", dut.u_ram.mem[i]);
    $fclose(fd);

    // dump core state: 16 regs, reject_count, halted
    fd = $fopen(stout, "w");
    for (i = 0; i < 16; i = i + 1)
      $fwrite(fd, "r%0d %08x\n", i, dut.u_cm.rf[i]);
    $fwrite(fd, "reject %0d\n", dut.u_cm.reject_count);
    $fwrite(fd, "halted %0d\n", halted);
    $fclose(fd);

    $display("TB: wrote %s and %s", ramout, stout);
    $finish;
  end
endmodule
