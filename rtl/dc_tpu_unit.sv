// ============================================================================
// dc_tpu_unit -- native tensor execution unit (TPU-style).
// Four operations, all sourcing/sinking the unified RAM:
//   TLOAD  : stage a 4x4 weight tile and a 4x4 activation tile into local regs
//   TMAT   : run the 4x4 systolic array  (INT8*INT8 -> INT32 accumulate)
//   TQUANT : INT32 accumulator -> INT8  (arith shift, optional ReLU, clamp)
//   TSTORE : write the 16 quantized INT8 results to a destination tile
// Local A/W/C/Q registers are execution-local storage only.
// ============================================================================
module dc_tpu_unit import dc_pkg::*; (
  input  logic              clk,
  input  logic              rst,

  // dispatch
  input  logic              start,
  input  logic [5:0]        op,
  input  logic [AW-1:0]     wbase,    // TLOAD weight tile base
  input  logic [AW-1:0]     abase,    // TLOAD activation tile base
  input  logic [AW-1:0]     dbase,    // TSTORE result tile base
  input  logic [13:0]       imm,      // TQUANT: [4:0]=shift, [5]=relu
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
  typedef enum logic [3:0]
    {IDLE,TLD,MAT_S,MAT_W,QNT,ST,FIN} state_t;
  state_t st;

  logic [5:0]    r_op;
  logic [AW-1:0] r_wb, r_ab, r_db;
  logic [13:0]   r_imm;
  logic [4:0]    n;
  // pipelined-read state: stream 32 words (16 weight + 16 activation).
  // With the registered arbiter->RAM stage, rdata is 2 cycles after m_gnt.
  logic [5:0]    iss, cap, idx_q1, idx_q2;
  logic          grant_q1, grant_q2;

  logic [127:0]  aflat, wflat;
  logic [511:0]  cflat;
  logic signed [7:0] q [0:15];

  // systolic array
  logic          sys_start, sys_done;
  logic [511:0]  sys_c;
  dc_systolic4 u_sys (
    .clk(clk), .rst(rst), .start(sys_start),
    .a_flat(aflat), .w_flat(wflat), .done(sys_done), .c_flat(sys_c)
  );

  wire [4:0] sh   = r_imm[4:0];
  wire       relu = r_imm[5];

  // quantize one accumulator lane
  function automatic signed [7:0] quant(input signed [31:0] acc);
    logic signed [31:0] v;
    v = acc >>> sh;
    if (relu && v < 0) v = 0;
    if      (v >  127) v =  127;
    else if (v < -128) v = -128;
    quant = v[7:0];
  endfunction

  assign busy = (st!=IDLE);
  assign done = (st==FIN);

  always_comb begin
    m_req=0; m_we=0; m_addr='0; m_wdata='0;
    if (st==TLD) begin
      m_req  = (iss < 6'd32);
      m_addr = (iss < 6'd16) ? (r_wb + iss) : (r_ab + (iss - 6'd16));
    end else if (st==ST) begin
      m_req=1; m_we=1; m_addr=r_db + n;
      m_wdata = {{24{q[n[3:0]][7]}}, q[n[3:0]]};      // sign-extended INT8
    end
  end

  integer k;
  always_ff @(posedge clk) begin
    if (rst) begin
      st<=IDLE; n<=0; sys_start<=0; aflat<=0; wflat<=0; cflat<=0;
      iss<=0; cap<=0; idx_q1<=0; idx_q2<=0; grant_q1<=0; grant_q2<=0;
      r_op<=6'b0; r_wb<='0; r_ab<='0; r_db<='0; r_imm<=14'b0;
      for (k=0; k<16; k=k+1) q[k] <= 8'sb0;
    end else begin
      sys_start <= 1'b0;
      case (st)
        IDLE: if (start) begin
          r_op<=op; r_wb<=wbase; r_ab<=abase; r_db<=dbase; r_imm<=imm; n<=0;
          iss<=0; cap<=0; grant_q1<=0; grant_q2<=0;
          case (op)
            OP_TLOAD : st<=TLD;
            OP_TMAT  : st<=MAT_S;
            OP_TQUANT: st<=QNT;
            OP_TSTORE: st<=ST;
            default  : st<=FIN;
          endcase
        end
        // ---- TLOAD: pipelined stream of 32 words, 1 word/cycle ----
        // Two-cycle read latency: gnt -> ... -> rdata is 2 cycles, so the
        // grant/idx tag pipeline has two ranks.
        TLD: begin
          grant_q2 <= grant_q1;
          idx_q2   <= idx_q1;
          if (grant_q2) begin
            if (idx_q2 < 6'd16)
              wflat[idx_q2*8 +: 8]            <= m_rdata[7:0];
            else
              aflat[(idx_q2-6'd16)*8 +: 8]    <= m_rdata[7:0];
            cap <= cap + 1'b1;
          end
          if (m_gnt) begin
            idx_q1   <= iss;
            grant_q1 <= 1'b1;
            iss      <= iss + 1'b1;
          end else
            grant_q1 <= 1'b0;
          if (grant_q2 && (cap + 1'b1 == 6'd32)) st<=FIN;
        end
        // ---- TMAT ----
        MAT_S: begin sys_start<=1'b1; st<=MAT_W; end
        MAT_W: if (sys_done) begin cflat<=sys_c; st<=FIN; end
        // ---- TQUANT ----
        QNT: begin
          for (k=0;k<16;k=k+1)
            q[k] <= quant($signed(cflat[k*32 +: 32]));
          st<=FIN;
        end
        // ---- TSTORE ----
        ST : if (m_gnt) begin
          if (n==5'd15) st<=FIN;
          else          n<=n+1;
        end
        FIN: st<=IDLE;
        default: st<=IDLE;
      endcase
    end
  end
endmodule
