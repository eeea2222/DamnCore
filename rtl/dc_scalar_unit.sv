// ============================================================================
// dc_scalar_unit -- minimal integer execution unit.
// The Core Manager supplies the operand values (rf[rs1], rf[rs2]) and the
// immediate; this unit performs the ALU op, resolves branches, and runs the
// load/store memory access through its own arbiter port. PC + register file
// live in the Core Manager.
// ============================================================================
module dc_scalar_unit import dc_pkg::*; (
  input  logic              clk,
  input  logic              rst,

  // dispatch
  input  logic              start,
  input  logic [5:0]        op,
  input  logic [31:0]       a,        // rf[rs1]
  input  logic [31:0]       b,        // rf[rs2]
  input  logic [13:0]       imm,
  output logic              busy,
  output logic              done,

  // result back to Core Manager
  output logic [31:0]       result,
  output logic              wr_en,    // writes rf[rd]
  output logic              br_taken,
  output logic [AW-1:0]     br_target,

  // arbiter / RAM port
  output logic              m_req,
  output logic              m_we,
  output logic [AW-1:0]     m_addr,
  output logic [31:0]       m_wdata,
  input  logic              m_gnt,
  input  logic [31:0]       m_rdata
);
  // MEMW1 is the extra latency cycle introduced by the registered RAM input.
  typedef enum logic [2:0] {IDLE, EXEC, MEM, MEMW1, MEMW, FIN} state_t;
  state_t st;

  logic [5:0]  r_op;
  logic [31:0] r_a, r_b, r_ld;
  logic [13:0] r_imm;

  wire [31:0] simm = {{18{r_imm[13]}}, r_imm};         // sign-extended imm
  wire [4:0]  sh   = r_imm[4:0];
  wire [31:0] alu  =
      (r_op==OP_ADD ) ? r_a + r_b :
      (r_op==OP_SUB ) ? r_a - r_b :
      (r_op==OP_AND ) ? r_a & r_b :
      (r_op==OP_OR  ) ? r_a | r_b :
      (r_op==OP_XOR ) ? r_a ^ r_b :
      (r_op==OP_SHL ) ? (r_a << sh) :
      (r_op==OP_SHR ) ? (r_a >> sh) :
      (r_op==OP_ADDI) ? r_a + simm :
                        32'b0;
  wire is_mem  = (r_op==OP_LOAD) || (r_op==OP_STORE);
  wire is_alu  = (r_op >= OP_ADD) && (r_op <= OP_ADDI);   // contiguous range

  assign result   = (r_op==OP_LOAD) ? r_ld : alu;
  assign wr_en    = is_alu || (r_op==OP_LOAD);
  assign br_taken = (r_op==OP_JMP) ||
                    (r_op==OP_BEQ && (r_a==r_b)) ||
                    (r_op==OP_BNE && (r_a!=r_b));
  assign br_target= r_imm;
  assign busy     = (st != IDLE);
  assign done     = (st == FIN);

  always_comb begin
    m_req=1'b0; m_we=1'b0; m_addr='0; m_wdata='0;
    if (st==MEM) begin
      m_req   = 1'b1;
      m_we    = (r_op==OP_STORE);
      m_addr  = (r_a + simm);
      m_wdata = r_b;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      st<=IDLE; r_op<=OP_NOP; r_a<=0; r_b<=0; r_imm<=0; r_ld<=0;
    end else begin
      case (st)
        IDLE: if (start) begin
                r_op<=op; r_a<=a; r_b<=b; r_imm<=imm; st<=EXEC;
              end
        EXEC: begin if (is_mem) st<=MEM; else st<=FIN; end
        MEM : if (m_gnt) begin
                if (r_op==OP_STORE) st<=FIN; else st<=MEMW1;
              end
        MEMW1: st<=MEMW;
        MEMW: begin r_ld<=m_rdata; st<=FIN; end
        FIN : st <= IDLE;
        default: st<=IDLE;
      endcase
    end
  end
endmodule
