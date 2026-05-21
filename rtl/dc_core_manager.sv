// ============================================================================
// dc_core_manager -- the central brain of DamnCore.
// Fetches and decodes DCN instructions, owns the PC and the scalar register
// file, dispatches work to the scalar / graphics / tensor units, drives the
// tile descriptor table and enforces tile-ownership safety: a unit may only
// touch a tile it owns, in a legal state. Unsafe ops are rejected, counted,
// and skipped -- never silently allowed.
// ============================================================================
module dc_core_manager import dc_pkg::*; (
  input  logic              clk,
  input  logic              rst,

  // instruction-fetch RAM port (arbiter slot 0)
  output logic              if_req,
  output logic              if_we,
  output logic [AW-1:0]     if_addr,
  output logic [31:0]       if_wdata,
  input  logic              if_gnt,
  input  logic [31:0]       if_rdata,

  // core-manager RAM port for descriptor loads (arbiter slot 2)
  output logic              cm_req,
  output logic              cm_we,
  output logic [AW-1:0]     cm_addr,
  output logic [31:0]       cm_wdata,
  input  logic              cm_gnt,
  input  logic [31:0]       cm_rdata,

  // scalar unit
  output logic              sc_start,
  output logic [5:0]        sc_op,
  output logic [31:0]       sc_a,
  output logic [31:0]       sc_b,
  output logic [13:0]       sc_imm,
  input  logic              sc_done,
  input  logic [31:0]       sc_result,
  input  logic              sc_wr_en,
  input  logic              sc_br_taken,
  input  logic [AW-1:0]     sc_br_target,

  // graphics unit
  output logic              gx_start,
  output logic [5:0]        gx_op,
  output logic [AW-1:0]     gx_dbase,
  output logic [AW-1:0]     gx_sbase,
  output logic [7:0]        gx_drows,
  output logic [7:0]        gx_dcols,
  output logic [7:0]        gx_srows,
  output logic [7:0]        gx_scols,
  output logic [13:0]       gx_imm,
  input  logic              gx_done,

  // tensor unit
  output logic              tp_start,
  output logic [5:0]        tp_op,
  output logic [AW-1:0]     tp_wbase,
  output logic [AW-1:0]     tp_abase,
  output logic [AW-1:0]     tp_dbase,
  output logic [13:0]       tp_imm,
  input  logic              tp_done,

  // tile table
  output logic              tt_we,
  output logic [3:0]        tt_widx,
  output logic [AW-1:0]     tt_w_base,
  output logic [15:0]       tt_w_rows,
  output logic [15:0]       tt_w_cols,
  output logic [3:0]        tt_w_fam,
  output logic [7:0]        tt_w_fmt,
  output logic [2:0]        tt_w_owner,
  output logic [1:0]        tt_w_state,
  output logic [3:0]        tt_ridx_a,
  input  logic [AW-1:0]     tt_a_base,
  input  logic [15:0]       tt_a_rows,
  input  logic [15:0]       tt_a_cols,
  input  logic [3:0]        tt_a_fam,
  input  logic [7:0]        tt_a_fmt,
  input  logic [2:0]        tt_a_owner,
  input  logic [1:0]        tt_a_state,
  output logic [3:0]        tt_ridx_b,
  input  logic [AW-1:0]     tt_b_base,
  input  logic [15:0]       tt_b_rows,
  input  logic [15:0]       tt_b_cols,
  input  logic [3:0]        tt_b_fam,
  input  logic [7:0]        tt_b_fmt,
  input  logic [2:0]        tt_b_owner,
  input  logic [1:0]        tt_b_state,

  // visible status
  output logic              halted,
  output logic [31:0]       reject_count
);
  // FETCHW1 and TDEF_RW1 are extra latency cycles introduced by the
  // registered arbiter->RAM pipeline (rdata now arrives 2 cycles after gnt).
  typedef enum logic [4:0] {
    RST, FETCH, FETCHW1, FETCHW, DECODE,
    SC_RUN,
    GFX_PRE, GFX_RUN,
    TPU_PRE, TPU_RUN,
    TDEF_R, TDEF_RW1, TDEF_RW, TDEF_WR,
    TILEOP, SYNC, COMMIT, HALTED
  } state_t;
  state_t st;

  logic [31:0]  rf [0:15];
  logic [AW-1:0]pc;
  logic [31:0]  ir;
  logic [1:0]   dr_idx;
  logic [31:0]  dsc [0:2];
  logic [13:0]  wait_cnt;

  // ---- instruction field decode ----
  wire [5:0]  op  = ir[31:26];
  wire [3:0]  rd  = ir[25:22];
  wire [3:0]  rs1 = ir[21:18];
  wire [3:0]  rs2 = ir[17:14];
  wire [13:0] imm = ir[13:0];

  // Opcode classes use the high bits in dc_pkg.sv. Decode those directly
  // instead of building wider range comparators on the control path.
  wire is_scalar = (op[5:4]==2'b00) && (op[3:0] >= OP_ADD[3:0]) &&
                                      (op[3:0] <= OP_BNE[3:0]);
  wire is_gfx    = (op[5:4]==2'b10) && (op[3:0] <= OP_GFILT[3:0]);
  wire is_tpu    = (op[5:4]==2'b11) && (op[3:0] <= OP_TSTORE[3:0]);
  wire is_tileop = (op[5:4]==2'b01) && (op[3:0] >= OP_TOWN[3:0]) &&
                                      (op[3:0] <= OP_TFREE[3:0]);

  // ---- tile table read indices ----
  assign tt_ridx_a = (op==OP_TLOAD) ? rs1 : rd;
  assign tt_ridx_b = (op==OP_TLOAD) ? rs2 : rs1;

  // ---- ownership pre-checks ----
  wire dst_ok = (tt_a_owner==U_GFX) && (tt_a_state!=S_BUSY)
                                    && (tt_a_state!=S_FREE);
  wire src_ok = (op==OP_GFILL) ||
                ((tt_b_owner==U_GFX) &&
                 (tt_b_state==S_OWNED || tt_b_state==S_READY));
  wire gfx_ok = dst_ok && src_ok;

  wire tl_a_ok = (tt_a_owner==U_TPU) &&
                 (tt_a_state==S_OWNED || tt_a_state==S_READY);
  wire tl_b_ok = (tt_b_owner==U_TPU) &&
                 (tt_b_state==S_OWNED || tt_b_state==S_READY);
  wire ts_ok   = (tt_a_owner==U_TPU) && (tt_a_state!=S_BUSY)
                                     && (tt_a_state!=S_FREE);
  wire tpu_ok  = (op==OP_TLOAD)  ? (tl_a_ok && tl_b_ok) :
                 (op==OP_TSTORE) ? ts_ok : 1'b1;

  // ---- tile ownership op legality ----
  wire town_ok  = (tt_a_state==S_FREE) || (tt_a_owner==imm[2:0]);
  wire txfer_ok = (tt_a_state!=S_FREE) && (tt_a_state!=S_BUSY);

  // ---- dispatch operand wiring (combinational) ----
  assign sc_op   = op;
  assign sc_a    = rf[rs1];
  assign sc_b    = rf[rs2];
  assign sc_imm  = imm;
  assign sc_start= (st==DECODE) && is_scalar;

  assign gx_op   = op;
  assign gx_dbase= tt_a_base;
  assign gx_sbase= tt_b_base;
  assign gx_drows= tt_a_rows[7:0];
  assign gx_dcols= tt_a_cols[7:0];
  assign gx_srows= tt_b_rows[7:0];
  assign gx_scols= tt_b_cols[7:0];
  assign gx_imm  = imm;
  assign gx_start= (st==GFX_PRE) && gfx_ok;

  assign tp_op   = op;
  assign tp_wbase= tt_a_base;            // TLOAD weight tile (rs1)
  assign tp_abase= tt_b_base;            // TLOAD activation tile (rs2)
  assign tp_dbase= tt_a_base;            // TSTORE result tile (rd)
  assign tp_imm  = imm;
  assign tp_start= (st==TPU_PRE) && tpu_ok;

  // ---- instruction fetch / descriptor RAM ports ----
  assign if_we    = 1'b0;
  assign if_wdata = 32'b0;
  assign if_addr  = pc;
  assign if_req   = (st==FETCH);

  assign cm_we    = 1'b0;
  assign cm_wdata = 32'b0;
  assign cm_addr  = rf[rs1] + {14'b0, dr_idx};
  assign cm_req   = (st==TDEF_R);

  assign halted   = (st==HALTED);

  // ---- tile table write (combinational, gated by state) ----
  always_comb begin
    tt_we=1'b0; tt_widx=rd;
    tt_w_base=tt_a_base; tt_w_rows=tt_a_rows; tt_w_cols=tt_a_cols;
    tt_w_fam=tt_a_fam;   tt_w_fmt=tt_a_fmt;
    tt_w_owner=tt_a_owner; tt_w_state=tt_a_state;
    case (st)
      GFX_PRE: if (gfx_ok) begin tt_we=1; tt_w_state=S_BUSY; end
      GFX_RUN: if (gx_done) begin tt_we=1; tt_w_state=S_READY; end
      TPU_PRE: if (tpu_ok && op==OP_TSTORE) begin tt_we=1; tt_w_state=S_BUSY; end
      TPU_RUN: if (tp_done && op==OP_TSTORE) begin tt_we=1; tt_w_state=S_READY; end
      TDEF_WR: begin
        tt_we=1;
        tt_w_base = dsc[0][AW-1:0];
        tt_w_rows = dsc[1][31:16];
        tt_w_cols = dsc[1][15:0];
        tt_w_fam  = dsc[2][11:8];
        tt_w_fmt  = dsc[2][7:0];
        tt_w_owner= U_NONE;
        tt_w_state= S_FREE;
      end
      TILEOP: begin
        if (op==OP_TOWN && town_ok) begin
          tt_we=1; tt_w_owner=imm[2:0]; tt_w_state=S_OWNED;
        end else if (op==OP_TXFER && txfer_ok) begin
          tt_we=1; tt_w_owner=imm[2:0]; tt_w_state=S_READY;
        end else if (op==OP_TFREE) begin
          tt_we=1; tt_w_owner=U_NONE;  tt_w_state=S_FREE;
        end
      end
      default: ;
    endcase
  end

  integer i;
  always_ff @(posedge clk) begin
    if (rst) begin
      st<=RST; pc<=0; ir<=0; dr_idx<=0; wait_cnt<=0; reject_count<=0;
      for (i=0;i<16;i=i+1) rf[i]<=32'b0;
    end else begin
      case (st)
        RST    : st<=FETCH;
        FETCH  : if (if_gnt) st<=FETCHW1;
        FETCHW1: st<=FETCHW;
        FETCHW : begin ir<=if_rdata; st<=DECODE; end
        DECODE : begin
          if      (op==OP_HALT)               st<=HALTED;
          else if (op==OP_NOP)                st<=COMMIT;
          else if (is_scalar)                 st<=SC_RUN;
          else if (is_gfx)                    st<=GFX_PRE;
          else if (is_tpu)                    st<=TPU_PRE;
          else if (op==OP_TDEF) begin dr_idx<=0; st<=TDEF_R; end
          else if (is_tileop)                 st<=TILEOP;
          else if (op==OP_FENCE)              begin wait_cnt<=0; st<=SYNC; end
          else if (op==OP_WAIT)               begin wait_cnt<=imm; st<=SYNC; end
          else                                st<=COMMIT;
        end
        SC_RUN : if (sc_done) begin
          if (sc_wr_en && rd!=4'd0) rf[rd] <= sc_result;
          pc <= sc_br_taken ? sc_br_target : (pc + 1'b1);
          st <= FETCH;
        end
        GFX_PRE: begin
          if (!gfx_ok) reject_count <= reject_count + 1;
          if (gfx_ok) st<=GFX_RUN; else st<=COMMIT;
        end
        GFX_RUN: if (gx_done) st<=COMMIT;
        TPU_PRE: begin
          if (!tpu_ok) reject_count <= reject_count + 1;
          if (tpu_ok) st<=TPU_RUN; else st<=COMMIT;
        end
        TPU_RUN: if (tp_done) st<=COMMIT;
        TDEF_R : if (cm_gnt) st<=TDEF_RW1;
        TDEF_RW1: st<=TDEF_RW;
        TDEF_RW: begin
          dsc[dr_idx] <= cm_rdata;
          if (dr_idx==2'd2) st<=TDEF_WR;
          else begin dr_idx<=dr_idx+1; st<=TDEF_R; end
        end
        TDEF_WR: st<=COMMIT;
        TILEOP : begin
          if (op==OP_TOWN  && !town_ok ) reject_count<=reject_count+1;
          if (op==OP_TXFER && !txfer_ok) reject_count<=reject_count+1;
          st<=COMMIT;
        end
        SYNC   : if (wait_cnt==0) st<=COMMIT;
                 else wait_cnt<=wait_cnt-1;
        COMMIT : begin pc<=pc+1'b1; st<=FETCH; end
        HALTED : st<=HALTED;
        default: st<=FETCH;
      endcase
    end
  end
endmodule
