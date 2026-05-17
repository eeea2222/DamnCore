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
  typedef enum logic [2:0] {IDLE,LOAD,PROC,FIN} state_t;
  state_t st;

  logic [5:0]   r_op;
  logic [AW-1:0]r_db, r_sb;
  logic [7:0]   r_dr,r_dc,r_sr,r_sc;
  logic [13:0]  r_imm;
  logic [31:0]  lb [0:63];               // local source buffer
  logic [6:0]   n;                       // linear element index
  logic [7:0]   pr, pc;                   // row / col during PROC
  // pipelined-read state: issue a read every cycle, capture 1 cycle later
  logic [6:0]   ld_iss, ld_cap, idx_q;
  logic         grant_q;

  wire [31:0] simm = {{18{r_imm[13]}}, r_imm};
  wire needs_src   = (r_op!=OP_GFILL);
  wire [12:0] ld_cnt   = r_sr * r_sc;
  wire [12:0] proc_cnt = r_dr * r_dc;

  // clamp-to-edge helper
  function automatic [7:0] clp(input integer v, input integer hi);
    if (v < 0)        clp = 8'd0;
    else if (v > hi)  clp = hi[7:0];
    else              clp = v[7:0];
  endfunction
  function automatic [31:0] px(input [7:0] rr, input [7:0] cc);
    px = {24'b0, lb[rr*r_sc + cc][7:0]};
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

  // value written for the current PROC element
  wire [31:0] cur_pix = lb[n][7:0];
  wire [31:0] gval =
      (r_op==OP_GFILL) ? simm :
      (r_op==OP_GCOPY) ? lb[n] :
      (r_op==OP_GCVT ) ? (32'd255 - cur_pix) :
      (r_op==OP_GNORM) ? ($signed(cur_pix) - $signed(simm)) :
      (r_op==OP_GFILT) ? blur(pr,pc) :
                         32'b0;

  assign busy = (st!=IDLE);
  assign done = (st==FIN);

  always_comb begin
    m_req=0; m_we=0; m_addr='0; m_wdata='0;
    if (st==LOAD) begin
      m_req = (ld_iss < ld_cnt); m_we=0; m_addr=r_sb + ld_iss;
    end else if (st==PROC) begin
      m_req=1; m_we=1; m_addr=r_db + n; m_wdata=gval;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      st<=IDLE; n<=0; pr<=0; pc<=0;
      ld_iss<=0; ld_cap<=0; idx_q<=0; grant_q<=0;
    end else begin
      case (st)
        IDLE: if (start) begin
          r_op<=op; r_db<=dbase; r_sb<=sbase;
          r_dr<=drows; r_dc<=dcols; r_sr<=srows; r_sc<=scols;
          r_imm<=imm; n<=0; pr<=0; pc<=0;
          ld_iss<=0; ld_cap<=0; grant_q<=0;
          if (op!=OP_GFILL) st<=LOAD; else st<=PROC;
        end
        // pipelined streaming load: 1 word/cycle (issue + trailing capture)
        LOAD: begin
          if (grant_q) begin
            lb[idx_q] <= m_rdata;
            ld_cap    <= ld_cap + 1'b1;
          end
          if (m_gnt) begin
            idx_q<=ld_iss; grant_q<=1'b1; ld_iss<=ld_iss+1'b1;
          end else
            grant_q<=1'b0;
          if (grant_q && (ld_cap + 1'b1 == ld_cnt)) begin
            n<=0; pr<=0; pc<=0; st<=PROC;
          end
        end
        PROC: if (m_gnt) begin
          if (n+1 >= proc_cnt) st<=FIN;
          else begin
            n  <= n+1;
            if (pc+1 >= r_dc) begin pc<=0; pr<=pr+1; end
            else                   pc<=pc+1;
          end
        end
        FIN : st<=IDLE;
        default: st<=IDLE;
      endcase
    end
  end
endmodule
