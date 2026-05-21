// ============================================================================
// dc_gfx_unit -- graphics / tile processor. Operates on tiles living in the
// unified RAM. It first streams the whole source tile into a small local
// buffer (execution-local storage only), then computes and writes the result
// tile. Supported ops: GFILL, GCOPY, GCVT (invert), GNORM (bias subtract),
// GFILT (3x3 box blur, clamp-to-edge borders).
// ============================================================================
module dc_gfx_unit import dc_pkg::*; (
  input  logic              clk,
  input  logic              rst,

  // dispatch
  input  logic              start,
  input  logic [5:0]        op,
  input  logic [AW-1:0]     dbase,
  input  logic [AW-1:0]     sbase,
  input  logic [7:0]        drows,
  input  logic [7:0]        dcols,
  input  logic [7:0]        srows,
  input  logic [7:0]        scols,
  input  logic [13:0]       imm,
  output logic              busy,
  output logic              done,

  // arbiter / RAM port
  output logic              m_req,
  output logic              m_we,
  output logic [AW-1:0]     m_addr,
  output logic [31:0]       m_wdata,
  input  logic              m_gnt,
  input  logic [31:0]       m_rdata
);
  // PROC split into PROC_COMP (latch gval into gval_q, 1 cycle) and PROC_WR
  // (issue the registered write). 2 cycles/element but the deep combinational
  // gval logic is no longer on the cycle-critical RAM-write path.
  typedef enum logic [2:0] {IDLE,LOAD,PROC_COMP,PROC,FIN} state_t;
  state_t st;

  logic [5:0]   r_op;
  logic [AW-1:0]r_db, r_sb;
  logic [7:0]   r_dr,r_dc,r_sr,r_sc;
  logic [13:0]  r_imm;
  logic [31:0]  lb [0:63];               // local source buffer
  logic [6:0]   n;                       // linear element index
  logic [7:0]   pr, pc;                   // row / col during PROC
  // pipelined-read state. With the registered arbiter->RAM stage, rdata
  // arrives 2 cycles after m_gnt, so we need two pipeline ranks.
  logic [6:0]   ld_iss, ld_cap;
  logic [6:0]   idx_q1, idx_q2;
  logic         grant_q1, grant_q2;

  wire [31:0] simm = {{18{r_imm[13]}}, r_imm};
  wire needs_src   = (r_op!=OP_GFILL);
  // ld_cnt / proc_cnt are products of shape regs that only change once per
  // dispatch (at IDLE->LOAD/PROC). Register them so the multiplier sits off
  // the cycle-critical compare path used by LOAD/PROC.
  logic [12:0] ld_cnt;
  logic [12:0] proc_cnt;
  // Per-row offsets into lb[] for the source tile, precomputed at dispatch
  // (row_off[i] = i * r_sc). Keeps the per-cycle GFILT path multiplier-free.
  logic [5:0] row_off [0:7];      // supports up to 8x8 source tiles (lb is 64-deep)

  // clamp-to-edge helper
  function automatic [7:0] clp(input integer v, input integer hi);
    if (v < 0)        clp = 8'd0;
    else if (v > hi)  clp = hi[7:0];
    else              clp = v[7:0];
  endfunction
  function automatic [31:0] px(input [7:0] rr, input [7:0] cc);
    // multiplier-free row offset lookup
    logic [5:0]  off;
    logic [31:0] word;
    off  = row_off[rr[2:0]] + cc[5:0];
    word = lb[off];
    px   = {24'b0, word[7:0]};
  endfunction

  // 3x3 box-blur sum at (pr,pc)
  function automatic [31:0] blur(input [7:0] rr, input [7:0] cc);
    integer dr, dc, s;
    s = 0;
    for (dr=-1; dr<=1; dr=dr+1)
      for (dc=-1; dc<=1; dc=dc+1)
        s = s + px(clp(rr+dr, r_sr-1), clp(cc+dc, r_sc-1));
    blur = s / 9;
  endfunction

  // value written for the current PROC element. Computed combinationally,
  // then captured into gval_q (registered) before reaching the RAM port -
  // takes the deep blur()/sign-extend chain off the cycle-critical write
  // path. m_wdata uses gval_q, and `n` only advances after the write commits.
  logic [31:0] cur_pix;
  logic [31:0] gval;
  logic [31:0] gval_q;
  always_comb begin
    cur_pix = {24'b0, lb[n][7:0]};
    case (r_op)
      OP_GFILL: gval = simm;
      OP_GCOPY: gval = lb[n];
      OP_GCVT : gval = 32'd255 - cur_pix;
      OP_GNORM: gval = $signed(cur_pix) - $signed(simm);
      OP_GFILT: gval = blur(pr, pc);
      default : gval = 32'b0;
    endcase
  end

  assign busy = (st!=IDLE);
  assign done = (st==FIN);

  always_comb begin
    m_req=0; m_we=0; m_addr='0; m_wdata='0;
    if (st==LOAD) begin
      m_req = (ld_iss < ld_cnt); m_we=0; m_addr=r_sb + ld_iss;
    end else if (st==PROC) begin
      m_req=1; m_we=1; m_addr=r_db + n; m_wdata=gval_q;
    end
  end

  integer ri;
  always_ff @(posedge clk) begin
    if (rst) begin
      st<=IDLE; n<=0; pr<=0; pc<=0;
      ld_iss<=0; ld_cap<=0;
      idx_q1<=0; idx_q2<=0; grant_q1<=0; grant_q2<=0;
      r_op<=6'b0; r_db<='0; r_sb<='0;
      r_dr<=8'b0; r_dc<=8'b0; r_sr<=8'b0; r_sc<=8'b0; r_imm<=14'b0;
      ld_cnt<=13'b0; proc_cnt<=13'b0; gval_q<=32'b0;
      for (ri=0; ri<8;  ri=ri+1) row_off[ri] <= 6'b0;
      // NOTE: lb[] is intentionally NOT reset. Resetting 64x32 FFs blew up the
      // reset-net fanout (16+ns of routing into every lb[i].CE on FPGA). The
      // LOAD phase always fully populates lb[0..ld_cnt-1] before any PROC
      // reads it, and the GFILL op skips lb entirely. So lb contents pre-LOAD
      // are don't-care.
    end else begin
      case (st)
        IDLE: if (start) begin
          r_op<=op; r_db<=dbase; r_sb<=sbase;
          r_dr<=drows; r_dc<=dcols; r_sr<=srows; r_sc<=scols;
          r_imm<=imm; n<=0; pr<=0; pc<=0;
          ld_iss<=0; ld_cap<=0; grant_q1<=0; grant_q2<=0;
          // shape products precomputed at dispatch -- off the per-cycle path
          ld_cnt   <= srows * scols;
          proc_cnt <= drows * dcols;
          // also precompute the 8 source row-base offsets used by GFILT
          row_off[0] <= 6'd0;
          row_off[1] <= scols[5:0];
          row_off[2] <= (scols[5:0] << 1);
          row_off[3] <= (scols[5:0] << 1) + scols[5:0];
          row_off[4] <= (scols[5:0] << 2);
          row_off[5] <= (scols[5:0] << 2) + scols[5:0];
          row_off[6] <= (scols[5:0] << 2) + (scols[5:0] << 1);
          row_off[7] <= (scols[5:0] << 2) + (scols[5:0] << 1) + scols[5:0];
          if (op!=OP_GFILL) st<=LOAD; else st<=PROC_COMP;
        end
        // pipelined streaming load: 1 word/cycle (issue + 2-cycle latency)
        LOAD: begin
          // shift the grant/idx pipeline regardless
          grant_q2 <= grant_q1;
          idx_q2   <= idx_q1;
          if (grant_q2) begin
            lb[idx_q2] <= m_rdata;
            ld_cap     <= ld_cap + 1'b1;
          end
          if (m_gnt) begin
            idx_q1   <= ld_iss;
            grant_q1 <= 1'b1;
            ld_iss   <= ld_iss + 1'b1;
          end else
            grant_q1 <= 1'b0;
          if (grant_q2 && (ld_cap + 1'b1 == ld_cnt)) begin
            n<=0; pr<=0; pc<=0; st<=PROC_COMP;
          end
        end
        // Capture the combinational result into gval_q so the deep blur/clamp
        // chain is not on the same cycle as the RAM write.
        PROC_COMP: begin gval_q <= gval; st<=PROC; end
        PROC: if (m_gnt) begin
          if (n+1 >= proc_cnt) st<=FIN;
          else begin
            n  <= n+1;
            if (pc+1 >= r_dc) begin pc<=0; pr<=pr+1; end
            else                   pc<=pc+1;
            st<=PROC_COMP;
          end
        end
        FIN : st<=IDLE;
        default: st<=IDLE;
      endcase
    end
  end
endmodule
