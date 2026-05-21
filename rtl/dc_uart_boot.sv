// ============================================================================
// dc_uart_boot -- UART RAM image loader for on-board boot.
//
// Protocol, 8N1 at BAUD:
//   byte 0: 0x44 ('D')
//   byte 1: 0x43 ('C')
//   byte 2: word count[7:0]
//   byte 3: word count[15:8]
//   data  : count little-endian 32-bit words, loaded at RAM word address 0
//
// The loader holds the core in reset through boot_hold until the final write has
// reached RAM. uart_tx is held idle-high; the protocol is intentionally RX-only
// so it works with the simplest USB-UART adapters.
// ============================================================================
module dc_uart_boot import dc_pkg::*; #(
  parameter int CLK_HZ = 50_000_000,
  parameter int BAUD   = 115_200
)(
  input  logic          clk,
  input  logic          rst,
  input  logic          uart_rx,
  output logic          uart_tx,
  output logic          boot_hold,
  output logic          boot_we,
  output logic [AW-1:0] boot_addr,
  output logic [DW-1:0] boot_wdata,
  output logic          boot_done,
  output logic          boot_error
);
  localparam int CLKS_PER_BIT = (CLK_HZ + (BAUD / 2)) / BAUD;
  localparam int RX_CNT_W = (CLKS_PER_BIT <= 2) ? 1 : $clog2(CLKS_PER_BIT);

  typedef enum logic [2:0] {RX_IDLE, RX_START, RX_DATA, RX_STOP} rx_state_t;
  rx_state_t rx_st;
  logic [RX_CNT_W-1:0] rx_cnt;
  logic [2:0]          rx_bit;
  logic [7:0]          rx_shift;
  logic [7:0]          rx_byte;
  logic                rx_valid;
  logic                rx_meta, rx_sync;

  always_ff @(posedge clk) begin
    if (rst) begin
      rx_meta <= 1'b1;
      rx_sync <= 1'b1;
    end else begin
      rx_meta <= uart_rx;
      rx_sync <= rx_meta;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      rx_st    <= RX_IDLE;
      rx_cnt   <= '0;
      rx_bit   <= 3'b0;
      rx_shift <= 8'b0;
      rx_byte  <= 8'b0;
      rx_valid <= 1'b0;
    end else begin
      rx_valid <= 1'b0;
      case (rx_st)
        RX_IDLE: begin
          rx_cnt <= '0;
          rx_bit <= 3'b0;
          if (!rx_sync)
            rx_st <= RX_START;
        end
        RX_START: begin
          if (rx_cnt == (CLKS_PER_BIT / 2)) begin
            if (!rx_sync) begin
              rx_cnt <= '0;
              rx_st  <= RX_DATA;
            end else begin
              rx_st <= RX_IDLE;
            end
          end else begin
            rx_cnt <= rx_cnt + 1'b1;
          end
        end
        RX_DATA: begin
          if (rx_cnt == CLKS_PER_BIT - 1) begin
            rx_cnt <= '0;
            rx_shift <= {rx_sync, rx_shift[7:1]};
            if (rx_bit == 3'd7)
              rx_st <= RX_STOP;
            else
              rx_bit <= rx_bit + 1'b1;
          end else begin
            rx_cnt <= rx_cnt + 1'b1;
          end
        end
        RX_STOP: begin
          if (rx_cnt == CLKS_PER_BIT - 1) begin
            rx_cnt <= '0;
            rx_st  <= RX_IDLE;
            if (rx_sync) begin
              rx_byte  <= rx_shift;
              rx_valid <= 1'b1;
            end
          end else begin
            rx_cnt <= rx_cnt + 1'b1;
          end
        end
        default: rx_st <= RX_IDLE;
      endcase
    end
  end

  typedef enum logic [2:0] {B_MAGIC0, B_MAGIC1, B_COUNT0, B_COUNT1,
                            B_DATA, B_FLUSH, B_RUN, B_ERROR} boot_state_t;
  boot_state_t boot_st;
  logic [15:0] word_count, word_index;
  logic [1:0]  byte_index;
  logic [31:0] word_shift;

  assign uart_tx    = 1'b1;
  assign boot_hold  = (boot_st != B_RUN);
  assign boot_done  = (boot_st == B_RUN);
  assign boot_error = (boot_st == B_ERROR);

  always_ff @(posedge clk) begin
    if (rst) begin
      boot_st     <= B_MAGIC0;
      boot_we     <= 1'b0;
      boot_addr   <= '0;
      boot_wdata  <= '0;
      word_count  <= 16'b0;
      word_index  <= 16'b0;
      byte_index  <= 2'b0;
      word_shift  <= 32'b0;
    end else begin
      boot_we <= 1'b0;
      case (boot_st)
        B_MAGIC0: if (rx_valid) begin
          if (rx_byte == 8'h44) boot_st <= B_MAGIC1;
          else                  boot_st <= B_ERROR;
        end
        B_MAGIC1: if (rx_valid) begin
          if (rx_byte == 8'h43) boot_st <= B_COUNT0;
          else                  boot_st <= B_ERROR;
        end
        B_COUNT0: if (rx_valid) begin
          word_count[7:0] <= rx_byte;
          boot_st         <= B_COUNT1;
        end
        B_COUNT1: if (rx_valid) begin
          word_count[15:8] <= rx_byte;
          word_index       <= 16'b0;
          byte_index       <= 2'b0;
          word_shift       <= 32'b0;
          boot_addr        <= '0;
          boot_st          <= ({rx_byte, word_count[7:0]} == 16'b0) ?
                              B_RUN : B_DATA;
        end
        B_DATA: if (rx_valid) begin
          case (byte_index)
            2'd0: word_shift[7:0]   <= rx_byte;
            2'd1: word_shift[15:8]  <= rx_byte;
            2'd2: word_shift[23:16] <= rx_byte;
            default: begin
              boot_wdata <= {rx_byte, word_shift[23:0]};
              boot_addr  <= word_index[AW-1:0];
              boot_we    <= 1'b1;
              word_index <= word_index + 1'b1;
              if (word_index + 1'b1 == word_count)
                boot_st <= B_FLUSH;
            end
          endcase
          byte_index <= byte_index + 1'b1;
        end
        B_FLUSH: boot_st <= B_RUN;
        B_RUN:   boot_st <= B_RUN;
        B_ERROR: boot_st <= B_ERROR;
        default: boot_st <= B_ERROR;
      endcase
    end
  end
endmodule
