// ============================================================================
// dc_systolic4 -- 4x4 output-stationary INT8 systolic array.
// Computes C[i][j] = sum_k A[i][k] * W[k][j] with INT32 accumulation.
//   * activations A stream left->right, one row per PE-row, skewed by row
//   * weights     W stream top->bottom, one col per PE-col, skewed by col
// PE(i,j) sees a_in = A[i][k] and w_in = W[k][j] with k = cyc-i-j, so each PE
// accumulates exactly its dot product. 16 multiply-accumulate PEs.
// ============================================================================
module dc_systolic4 (
  input  logic          clk,
  input  logic          rst,
  input  logic          start,
  input  logic [127:0]  a_flat,     // 16 x INT8, A[i][k] at (i*4+k)*8
  input  logic [127:0]  w_flat,     // 16 x INT8, W[k][j] at (k*4+j)*8
  output logic          done,
  output logic [511:0]  c_flat      // 16 x INT32, C[i][j] at (i*4+j)*32
);
  logic               running, valid;
  logic [4:0]         cyc;
  logic signed [7:0]  Am   [0:3][0:3];
  logic signed [7:0]  Wm   [0:3][0:3];
  logic signed [7:0]  areg [0:3][0:3];
  logic signed [7:0]  wreg [0:3][0:3];
  logic signed [15:0] prod [0:3][0:3];
  logic signed [31:0] acc  [0:3][0:3];

  integer i,j;

  // edge feeders -- value entering the array this cycle
  function automatic signed [7:0] leftf(input integer ii, input integer c);
    integer k; k = c - ii;
    leftf = (k>=0 && k<4) ? Am[ii][k] : 8'sd0;
  endfunction
  function automatic signed [7:0] topf(input integer jj, input integer c);
    integer k; k = c - jj;
    topf = (k>=0 && k<4) ? Wm[k][jj] : 8'sd0;
  endfunction

  logic signed [7:0] ain, win;

  always_ff @(posedge clk) begin
    if (rst) begin
      running<=0; valid<=0; cyc<=0;
      for (i=0;i<4;i=i+1) for (j=0;j<4;j=j+1) begin
        Am[i][j]<=0; Wm[i][j]<=0; areg[i][j]<=0; wreg[i][j]<=0;
        prod[i][j]<=0; acc[i][j]<=0;
      end
    end else if (start) begin
      running<=1; valid<=0; cyc<=0;
      for (i=0;i<4;i=i+1) for (j=0;j<4;j=j+1) begin
        Am[i][j] <= a_flat[(i*4+j)*8 +: 8];
        Wm[i][j] <= w_flat[(i*4+j)*8 +: 8];
        areg[i][j]<=0; wreg[i][j]<=0; prod[i][j]<=0; acc[i][j]<=0;
      end
    end else if (running) begin
      for (i=0;i<4;i=i+1) for (j=0;j<4;j=j+1) begin
        ain = (j==0) ? leftf(i,cyc) : areg[i][j-1];
        win = (i==0) ? topf(j,cyc)  : wreg[i-1][j];
        areg[i][j] <= ain;
        wreg[i][j] <= win;
        prod[i][j] <= ain * win;
        acc[i][j]  <= acc[i][j] + prod[i][j];
      end
      if (cyc == 5'd14) begin running<=0; valid<=1; end
      else                   cyc <= cyc + 1;
    end
  end

  assign done = valid;
  genvar gi,gj;
  generate
    for (gi=0;gi<4;gi=gi+1) for (gj=0;gj<4;gj=gj+1)
      assign c_flat[(gi*4+gj)*32 +: 32] = acc[gi][gj];
  endgenerate
endmodule
