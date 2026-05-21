// ============================================================================
// tb_uart_boot -- exercises the board UART boot path with a one-word HALT image.
// ============================================================================
`timescale 1ns/1ps
module tb_uart_boot;
  localparam int CLK_HZ = 1_000_000;
  localparam int BAUD   = 100_000;
  localparam int BIT_CYCLES = CLK_HZ / BAUD;

  logic clk = 0;
  logic rst_btn = 1;
  logic uart_rx = 1;
  logic uart_tx;
  logic led_boot, led_halted, led_error;

  always #5 clk = ~clk;

  dc_board_uart_top #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) dut (
    .clk_50mhz(clk), .rst_btn(rst_btn), .uart_rx(uart_rx), .uart_tx(uart_tx),
    .led_boot(led_boot), .led_halted(led_halted), .led_error(led_error)
  );

  task automatic bit_wait;
    repeat (BIT_CYCLES) @(posedge clk);
  endtask

  task automatic send_byte(input logic [7:0] b);
    int i;
    begin
      uart_rx = 1'b0;
      bit_wait();
      for (i = 0; i < 8; i = i + 1) begin
        uart_rx = b[i];
        bit_wait();
      end
      uart_rx = 1'b1;
      bit_wait();
      bit_wait();
    end
  endtask

  initial begin
    repeat (12) @(posedge clk);
    rst_btn = 1'b0;
    repeat (12) @(posedge clk);

    send_byte(8'h44); // D
    send_byte(8'h43); // C
    send_byte(8'h01); // one word
    send_byte(8'h00);
    send_byte(8'h00); // HALT = 0x38000000, little-endian
    send_byte(8'h00);
    send_byte(8'h00);
    send_byte(8'h38);

    repeat (200) @(posedge clk);
    if (!led_boot) begin
      $display("TB ERROR: UART boot did not complete");
      $finish;
    end
    if (led_error) begin
      $display("TB ERROR: UART boot reported protocol error");
      $finish;
    end
    if (dut.u_core.u_ram.mem[0] !== 32'h38000000) begin
      $display("TB ERROR: RAM[0] = %08x, expected HALT", dut.u_core.u_ram.mem[0]);
      $finish;
    end
    if (!led_halted) begin
      $display("TB ERROR: core did not run the UART-loaded HALT image");
      $finish;
    end
    $display("TB: UART boot loaded HALT image and core halted");
    $finish;
  end
endmodule
