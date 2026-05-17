// ============================================================================
// DamnCore / UnifiedTensorGraphicsCore  --  ISA + architecture constants
// ----------------------------------------------------------------------------
// Custom "DCN" (DamnCore Native) ISA. 32-bit fixed-width instructions:
//   [31:26] op | [25:22] rd | [21:18] rs1 | [17:14] rs2 | [13:0] imm14
// All addresses are WORD addresses into one unified 32-bit RAM.
// ============================================================================
package dc_pkg;

  // ---- machine parameters ----
  localparam int AW    = 16;          // RAM address width (word addressed)
  localparam int DW    = 32;          // RAM data width
  localparam int NREG  = 16;          // scalar registers r0..r15 (r0 == 0)
  localparam int NTILE = 16;          // tile descriptor table entries
  localparam int SYS   = 4;           // systolic array dimension (4x4 INT8)

  // ---- arbiter port indices (0 = highest priority) ----
  localparam int P_IFETCH = 0;
  localparam int P_SCALAR = 1;
  localparam int P_CM     = 2;
  localparam int P_GFX    = 3;
  localparam int P_TPU    = 4;

  // ---- opcodes (6-bit) ----
  localparam logic [5:0]
    OP_NOP   = 6'h00,
    // scalar
    OP_ADD   = 6'h01, OP_SUB  = 6'h02, OP_AND  = 6'h03, OP_OR   = 6'h04,
    OP_XOR   = 6'h05, OP_SHL  = 6'h06, OP_SHR  = 6'h07, OP_ADDI = 6'h08,
    OP_LOAD  = 6'h09, OP_STORE= 6'h0A, OP_JMP  = 6'h0B, OP_BEQ  = 6'h0C,
    OP_BNE   = 6'h0D, OP_HALT = 6'h0E,
    // tile / core-manager
    OP_TDEF  = 6'h10, OP_TOWN = 6'h11, OP_TXFER= 6'h12, OP_TFREE= 6'h13,
    // graphics
    OP_GFILL = 6'h20, OP_GCOPY= 6'h21, OP_GCVT = 6'h22, OP_GNORM= 6'h23,
    OP_GFILT = 6'h24,
    // tensor
    OP_TLOAD = 6'h30, OP_TMAT = 6'h31, OP_TQUANT=6'h32, OP_TSTORE=6'h33,
    // sync
    OP_FENCE = 6'h38, OP_WAIT = 6'h39;

  // ---- unit identifiers (tile owners) ----
  localparam logic [2:0]
    U_NONE = 3'd0, U_SCALAR = 3'd1, U_GFX = 3'd2, U_TPU = 3'd3, U_CM = 3'd4;

  // ---- tile families ----
  localparam logic [3:0]
    F_IMAGE = 4'd1, F_TENSOR = 4'd2, F_WEIGHT = 4'd3, F_FRAME = 4'd4,
    F_META  = 4'd5;

  // ---- tile states ----
  localparam logic [1:0]
    S_FREE = 2'd0, S_OWNED = 2'd1, S_BUSY = 2'd2, S_READY = 2'd3;

  // ---- GFX sub-ops mirrored for clarity (same as opcodes) ----
  // GFILL: dst = imm           GCOPY: dst = src
  // GCVT : dst = 255 - src     GNORM: dst = src - imm   (signed)
  // GFILT: 3x3 box blur (/9, clamp-to-edge borders)

endpackage
