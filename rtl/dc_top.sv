// ============================================================================
// dc_top -- "DamnCore" SoC top level.
// One Core Manager, one scalar unit, one graphics unit, one tensor unit, one
// tile descriptor table, all sharing a single unified RAM through a 5-port
// arbiter. There is no separate VRAM and no separate TPU memory: every unit
// addresses the same physical memory.
// ============================================================================
module dc_top import dc_pkg::*; (
  input  logic clk,
  input  logic rst,
  input  logic boot_hold,
  input  logic boot_we,
  input  logic [AW-1:0] boot_addr,
  input  logic [DW-1:0] boot_wdata,
  output logic halted
);
  logic core_rst;
  assign core_rst = rst | boot_hold;

  // ---- arbiter <-> RAM ----
  logic [4:0]        req, we_in, gnt;
  logic [5*AW-1:0]   addr_in;
  logic [5*DW-1:0]   wdata_in;
  logic              ram_en, ram_we;
  logic [AW-1:0]     ram_addr;
  logic [DW-1:0]     ram_wdata, ram_rdata;
  // ---- pipelined RAM input stage (registered between arbiter and RAM) ----
  // Breaks the long combinational path: priority encoder + 5:1 mux of 32-bit
  // wdata + 5:1 mux of 16-bit addr was the post-mult bottleneck. Registering
  // these adds one cycle to write commit and two-cycle total read latency.
  // `keep` prevents synth from absorbing these flops into the BRAM input
  // register; we want the *external* break.
  (* keep = "true" *) logic              ram_en_q, ram_we_q;
  (* keep = "true" *) logic [AW-1:0]     ram_addr_q;
  (* keep = "true" *) logic [DW-1:0]     ram_wdata_q;

  // ---- per-unit RAM port signals ----
  logic              if_req, if_we;     logic [AW-1:0] if_addr;  logic [31:0] if_wdata;
  logic              sc_req, sc_we;     logic [AW-1:0] sc_addr;  logic [31:0] sc_wdata;
  logic              cm_req, cm_we;     logic [AW-1:0] cm_addr;  logic [31:0] cm_wdata;
  logic              gx_req, gx_we;     logic [AW-1:0] gx_addr;  logic [31:0] gx_wdata;
  logic              tp_req, tp_we;     logic [AW-1:0] tp_addr;  logic [31:0] tp_wdata;

  assign req      = {tp_req, gx_req, cm_req, sc_req, if_req};
  assign we_in    = {tp_we,  gx_we,  cm_we,  sc_we,  if_we};
  assign addr_in  = {tp_addr, gx_addr, cm_addr, sc_addr, if_addr};
  assign wdata_in = {tp_wdata,gx_wdata,cm_wdata,sc_wdata,if_wdata};

  // ---- CM <-> units ----
  logic        sc_start; logic [5:0] sc_op; logic [31:0] sc_a, sc_b;
  logic [13:0] sc_imm;   logic sc_done; logic [31:0] sc_result;
  logic        sc_wr_en, sc_br_taken; logic [AW-1:0] sc_br_target;

  logic        gx_start; logic [5:0] gx_op;
  logic [AW-1:0] gx_dbase, gx_sbase;
  logic [7:0]  gx_drows, gx_dcols, gx_srows, gx_scols;
  logic [13:0] gx_imm;   logic gx_done;

  logic        tp_start; logic [5:0] tp_op;
  logic [AW-1:0] tp_wbase, tp_abase, tp_dbase;
  logic [13:0] tp_imm;   logic tp_done;

  // ---- CM <-> tile table ----
  logic        tt_we; logic [3:0] tt_widx;
  logic [AW-1:0] tt_w_base; logic [15:0] tt_w_rows, tt_w_cols;
  logic [3:0]  tt_w_fam; logic [7:0] tt_w_fmt;
  logic [2:0]  tt_w_owner; logic [1:0] tt_w_state;
  logic [3:0]  tt_ridx_a, tt_ridx_b;
  logic [AW-1:0] tt_a_base, tt_b_base;
  logic [15:0] tt_a_rows, tt_a_cols, tt_b_rows, tt_b_cols;
  logic [3:0]  tt_a_fam, tt_b_fam; logic [7:0] tt_a_fmt, tt_b_fmt;
  logic [2:0]  tt_a_owner, tt_b_owner; logic [1:0] tt_a_state, tt_b_state;

  logic [31:0] reject_count;

  // ========================================================================
  dc_arbiter #(.AW(AW), .DW(DW)) u_arb (
    .req(req), .we_in(we_in), .addr_in(addr_in), .wdata_in(wdata_in),
    .gnt(gnt), .ram_en(ram_en), .ram_we(ram_we),
    .ram_addr(ram_addr), .ram_wdata(ram_wdata)
  );

  // Registered RAM input stage. RAM sees signals 1 cycle after the arbiter
  // selects them. Reset to 0 keeps unintended writes from firing during rst.
  always_ff @(posedge clk) begin
    if (core_rst) begin
      ram_en_q    <= 1'b0;
      ram_we_q    <= 1'b0;
      ram_addr_q  <= '0;
      ram_wdata_q <= '0;
    end else begin
      ram_en_q    <= ram_en;
      ram_we_q    <= ram_we;
      ram_addr_q  <= ram_addr;
      ram_wdata_q <= ram_wdata;
    end
  end

  dc_ram #(.AW(AW), .DW(DW)) u_ram (
    .clk(clk),
    .en(boot_hold ? boot_we    : ram_en_q),
    .we(boot_hold ? 1'b1       : ram_we_q),
    .addr(boot_hold ? boot_addr  : ram_addr_q),
    .wdata(boot_hold ? boot_wdata : ram_wdata_q),
    .rdata(ram_rdata)
  );

  dc_tile_table u_tt (
    .clk(clk), .rst(core_rst),
    .we(tt_we), .widx(tt_widx),
    .w_base(tt_w_base), .w_rows(tt_w_rows), .w_cols(tt_w_cols),
    .w_fam(tt_w_fam), .w_fmt(tt_w_fmt),
    .w_owner(tt_w_owner), .w_state(tt_w_state),
    .ridx_a(tt_ridx_a),
    .a_base(tt_a_base), .a_rows(tt_a_rows), .a_cols(tt_a_cols),
    .a_fam(tt_a_fam), .a_fmt(tt_a_fmt),
    .a_owner(tt_a_owner), .a_state(tt_a_state),
    .ridx_b(tt_ridx_b),
    .b_base(tt_b_base), .b_rows(tt_b_rows), .b_cols(tt_b_cols),
    .b_fam(tt_b_fam), .b_fmt(tt_b_fmt),
    .b_owner(tt_b_owner), .b_state(tt_b_state)
  );

  dc_core_manager u_cm (
    .clk(clk), .rst(core_rst),
    .if_req(if_req), .if_we(if_we), .if_addr(if_addr), .if_wdata(if_wdata),
    .if_gnt(gnt[P_IFETCH]), .if_rdata(ram_rdata),
    .cm_req(cm_req), .cm_we(cm_we), .cm_addr(cm_addr), .cm_wdata(cm_wdata),
    .cm_gnt(gnt[P_CM]), .cm_rdata(ram_rdata),
    .sc_start(sc_start), .sc_op(sc_op), .sc_a(sc_a), .sc_b(sc_b),
    .sc_imm(sc_imm), .sc_done(sc_done), .sc_result(sc_result),
    .sc_wr_en(sc_wr_en), .sc_br_taken(sc_br_taken), .sc_br_target(sc_br_target),
    .gx_start(gx_start), .gx_op(gx_op),
    .gx_dbase(gx_dbase), .gx_sbase(gx_sbase),
    .gx_drows(gx_drows), .gx_dcols(gx_dcols),
    .gx_srows(gx_srows), .gx_scols(gx_scols),
    .gx_imm(gx_imm), .gx_done(gx_done),
    .tp_start(tp_start), .tp_op(tp_op),
    .tp_wbase(tp_wbase), .tp_abase(tp_abase), .tp_dbase(tp_dbase),
    .tp_imm(tp_imm), .tp_done(tp_done),
    .tt_we(tt_we), .tt_widx(tt_widx),
    .tt_w_base(tt_w_base), .tt_w_rows(tt_w_rows), .tt_w_cols(tt_w_cols),
    .tt_w_fam(tt_w_fam), .tt_w_fmt(tt_w_fmt),
    .tt_w_owner(tt_w_owner), .tt_w_state(tt_w_state),
    .tt_ridx_a(tt_ridx_a),
    .tt_a_base(tt_a_base), .tt_a_rows(tt_a_rows), .tt_a_cols(tt_a_cols),
    .tt_a_fam(tt_a_fam), .tt_a_fmt(tt_a_fmt),
    .tt_a_owner(tt_a_owner), .tt_a_state(tt_a_state),
    .tt_ridx_b(tt_ridx_b),
    .tt_b_base(tt_b_base), .tt_b_rows(tt_b_rows), .tt_b_cols(tt_b_cols),
    .tt_b_fam(tt_b_fam), .tt_b_fmt(tt_b_fmt),
    .tt_b_owner(tt_b_owner), .tt_b_state(tt_b_state),
    .halted(halted), .reject_count(reject_count)
  );

  dc_scalar_unit u_scalar (
    .clk(clk), .rst(core_rst),
    .start(sc_start), .op(sc_op), .a(sc_a), .b(sc_b), .imm(sc_imm),
    .busy(), .done(sc_done), .result(sc_result), .wr_en(sc_wr_en),
    .br_taken(sc_br_taken), .br_target(sc_br_target),
    .m_req(sc_req), .m_we(sc_we), .m_addr(sc_addr), .m_wdata(sc_wdata),
    .m_gnt(gnt[P_SCALAR]), .m_rdata(ram_rdata)
  );

  dc_gfx_unit u_gfx (
    .clk(clk), .rst(core_rst),
    .start(gx_start), .op(gx_op),
    .dbase(gx_dbase), .sbase(gx_sbase),
    .drows(gx_drows), .dcols(gx_dcols),
    .srows(gx_srows), .scols(gx_scols), .imm(gx_imm),
    .busy(), .done(gx_done),
    .m_req(gx_req), .m_we(gx_we), .m_addr(gx_addr), .m_wdata(gx_wdata),
    .m_gnt(gnt[P_GFX]), .m_rdata(ram_rdata)
  );

  dc_tpu_unit u_tpu (
    .clk(clk), .rst(core_rst),
    .start(tp_start), .op(tp_op),
    .wbase(tp_wbase), .abase(tp_abase), .dbase(tp_dbase), .imm(tp_imm),
    .busy(), .done(tp_done),
    .m_req(tp_req), .m_we(tp_we), .m_addr(tp_addr), .m_wdata(tp_wdata),
    .m_gnt(gnt[P_TPU]), .m_rdata(ram_rdata)
  );
endmodule
