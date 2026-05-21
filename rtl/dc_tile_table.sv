// ============================================================================
// dc_tile_table -- the tile descriptor table. One entry per tile id:
//   base address, shape (rows/cols), format, family, owner, state.
// Two asynchronous read ports (so the Core Manager can inspect a source and a
// destination tile in the same cycle) and one synchronous write port.
// Ownership *policy* lives in the Core Manager; this module is the storage and
// exposes a combinational "safe to operate" check helper.
// ============================================================================
module dc_tile_table import dc_pkg::*; (
  input  logic              clk,
  input  logic              rst,

  // write port (full-entry write)
  input  logic              we,
  input  logic [3:0]        widx,
  input  logic [AW-1:0]     w_base,
  input  logic [15:0]       w_rows,
  input  logic [15:0]       w_cols,
  input  logic [3:0]        w_fam,
  input  logic [7:0]        w_fmt,
  input  logic [2:0]        w_owner,
  input  logic [1:0]        w_state,

  // read port A
  input  logic [3:0]        ridx_a,
  output logic [AW-1:0]     a_base,
  output logic [15:0]       a_rows,
  output logic [15:0]       a_cols,
  output logic [3:0]        a_fam,
  output logic [7:0]        a_fmt,
  output logic [2:0]        a_owner,
  output logic [1:0]        a_state,

  // read port B
  input  logic [3:0]        ridx_b,
  output logic [AW-1:0]     b_base,
  output logic [15:0]       b_rows,
  output logic [15:0]       b_cols,
  output logic [3:0]        b_fam,
  output logic [7:0]        b_fmt,
  output logic [2:0]        b_owner,
  output logic [1:0]        b_state
);
  logic [AW-1:0] base  [0:NTILE-1];
  logic [15:0]   rows  [0:NTILE-1];
  logic [15:0]   cols  [0:NTILE-1];
  logic [3:0]    fam   [0:NTILE-1];
  logic [7:0]    fmt   [0:NTILE-1];
  logic [2:0]    owner [0:NTILE-1];
  logic [1:0]    state [0:NTILE-1];

  integer i;
  always_ff @(posedge clk) begin
    if (rst) begin
      for (i = 0; i < NTILE; i = i + 1) begin
        // Only owner/state participate in post-reset legality checks. The
        // descriptor payload is don't-care until a TDEF writes the entry, so
        // leaving it unreset avoids a wide reset fanout across the table.
        owner[i]<=U_NONE; state[i]<=S_FREE;
      end
    end else if (we) begin
      base[widx]<=w_base; rows[widx]<=w_rows; cols[widx]<=w_cols;
      fam[widx]<=w_fam;   fmt[widx]<=w_fmt;
      owner[widx]<=w_owner; state[widx]<=w_state;
    end
  end

  assign a_base=base[ridx_a]; assign a_rows=rows[ridx_a];
  assign a_cols=cols[ridx_a]; assign a_fam=fam[ridx_a];
  assign a_fmt=fmt[ridx_a];   assign a_owner=owner[ridx_a];
  assign a_state=state[ridx_a];

  assign b_base=base[ridx_b]; assign b_rows=rows[ridx_b];
  assign b_cols=cols[ridx_b]; assign b_fam=fam[ridx_b];
  assign b_fmt=fmt[ridx_b];   assign b_owner=owner[ridx_b];
  assign b_state=state[ridx_b];
endmodule
