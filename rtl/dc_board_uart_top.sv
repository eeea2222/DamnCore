// ============================================================================
// dc_board_uart_top -- board-facing UART-bootable DamnCore wrapper.
//
// This wrapper is intentionally pin-agnostic: connect clk_50mhz, reset button,
// UART RX/TX, and LEDs in the board constraint file for the target FPGA.
// ============================================================================
module dc_board_uart_top import dc_pkg::*; #(
  parameter int CLK_HZ = 50_000_000,
  parameter int BAUD   = 115_200
)(
  input  logic clk_50mhz,
  input  logic rst_btn,
  input  logic uart_rx,
  output logic uart_tx,
  output logic led_boot,
  output logic led_halted,
  output logic led_error
);
  logic [7:0] rst_shift;
  logic       rst_sync;

  always_ff @(posedge clk_50mhz) begin
    if (rst_btn)
      rst_shift <= 8'hff;
    else
      rst_shift <= {rst_shift[6:0], 1'b0};
  end
  assign rst_sync = rst_shift[7];

  logic          boot_hold, boot_we, boot_done, boot_error;
  logic [AW-1:0] boot_addr;
  logic [DW-1:0] boot_wdata;
  logic          halted;

  dc_uart_boot #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_boot (
    .clk(clk_50mhz), .rst(rst_sync), .uart_rx(uart_rx), .uart_tx(uart_tx),
    .boot_hold(boot_hold), .boot_we(boot_we),
    .boot_addr(boot_addr), .boot_wdata(boot_wdata),
    .boot_done(boot_done), .boot_error(boot_error)
  );

  dc_top u_core (
    .clk(clk_50mhz), .rst(rst_sync),
    .boot_hold(boot_hold), .boot_we(boot_we),
    .boot_addr(boot_addr), .boot_wdata(boot_wdata),
    .halted(halted)
  );

  assign led_boot   = boot_done;
  assign led_halted = halted;
  assign led_error  = boot_error;
endmodule
