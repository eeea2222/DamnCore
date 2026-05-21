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
  wire [AW-1:0] addr0 = addr_in[0*AW +: AW];
  wire [AW-1:0] addr1 = addr_in[1*AW +: AW];
  wire [AW-1:0] addr2 = addr_in[2*AW +: AW];
  wire [AW-1:0] addr3 = addr_in[3*AW +: AW];
  wire [AW-1:0] addr4 = addr_in[4*AW +: AW];
  wire [DW-1:0] data0 = wdata_in[0*DW +: DW];
  wire [DW-1:0] data1 = wdata_in[1*DW +: DW];
  wire [DW-1:0] data2 = wdata_in[2*DW +: DW];
  wire [DW-1:0] data3 = wdata_in[3*DW +: DW];
  wire [DW-1:0] data4 = wdata_in[4*DW +: DW];

  always_comb begin
    gnt = 5'b0;
    ram_en    = 1'b0;
    ram_we    = 1'b0;
    ram_addr  = '0;
    ram_wdata = '0;

    if (req[0]) begin
      gnt[0]    = 1'b1;
      ram_en    = 1'b1;
      ram_we    = we_in[0];
      ram_addr  = addr0;
      ram_wdata = data0;
    end else if (req[1]) begin
      gnt[1]    = 1'b1;
      ram_en    = 1'b1;
      ram_we    = we_in[1];
      ram_addr  = addr1;
      ram_wdata = data1;
    end else if (req[2]) begin
      gnt[2]    = 1'b1;
      ram_en    = 1'b1;
      ram_we    = we_in[2];
      ram_addr  = addr2;
      ram_wdata = data2;
    end else if (req[3]) begin
      gnt[3]    = 1'b1;
      ram_en    = 1'b1;
      ram_we    = we_in[3];
      ram_addr  = addr3;
      ram_wdata = data3;
    end else if (req[4]) begin
      gnt[4]    = 1'b1;
      ram_en    = 1'b1;
      ram_we    = we_in[4];
      ram_addr  = addr4;
      ram_wdata = data4;
    end
  end
endmodule
