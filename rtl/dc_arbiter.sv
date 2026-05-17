// ============================================================================
// dc_arbiter -- 5-port fixed-priority crossbar onto the unified RAM.
// Requesters (priority high->low): instr-fetch, scalar load/store, Core Manager
// descriptor loads, graphics unit, tensor unit. Exactly ONE requester is
// granted the single RAM port each cycle, so two units can never write the
// same word in the same cycle -> no torn / corrupted accesses.
// ============================================================================
module dc_arbiter #(
  parameter int AW = 16,
  parameter int DW = 32
)(
  input  logic [4:0]        req,        // one bit per port
  input  logic [4:0]        we_in,
  input  logic [5*AW-1:0]   addr_in,    // packed: port p at [p*AW +: AW]
  input  logic [5*DW-1:0]   wdata_in,

  output logic [4:0]        gnt,        // one-hot grant
  output logic              ram_en,
  output logic              ram_we,
  output logic [AW-1:0]     ram_addr,
  output logic [DW-1:0]     ram_wdata
);
  integer sel;
  always_comb begin
    gnt = 5'b0;
    sel = -1;
    if      (req[0]) sel = 0;
    else if (req[1]) sel = 1;
    else if (req[2]) sel = 2;
    else if (req[3]) sel = 3;
    else if (req[4]) sel = 4;

    if (sel >= 0) gnt[sel] = 1'b1;

    ram_en    = (sel >= 0);
    ram_we    = (sel >= 0) ? we_in[sel]                   : 1'b0;
    ram_addr  = (sel >= 0) ? addr_in [sel*AW +: AW]       : '0;
    ram_wdata = (sel >= 0) ? wdata_in[sel*DW +: DW]       : '0;
  end
endmodule
