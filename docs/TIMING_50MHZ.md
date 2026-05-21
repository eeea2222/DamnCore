# 50 MHz Timing Work

This design targets a 20 ns clock period for on-board operation. The repo cannot
sign off physical timing without a concrete FPGA, constraints and P&R report,
but the RTL avoids the worst single-cycle combinational structures that pushed
early builds into the low-MHz range.

## Timing Cuts Added

- The unified RAM input is registered after arbitration in `dc_top`.
- The arbiter now uses explicit fixed mux slices instead of dynamic part-selects.
- `GFILT` is split into sum, exact divide-by-9, and write stages. The divide is
  implemented as `(sum * 1821) >> 14`, which is exact for the 3x3 8-bit blur
  sum range `0..2295`.
- `TQUANT` quantizes one lane per cycle instead of all 16 lanes in one cycle.
- The systolic array registers each PE product before accumulation, splitting
  multiplier timing from the 32-bit accumulator add.
- Scalar ALU/branch/load results and memory addresses are registered inside the
  scalar unit before the Core Manager consumes them.
- The GFX unit keeps shape products and row offsets registered at dispatch.
- The tile table resets only owner/state, because descriptor payload fields are
  don't-care until TDEF writes a legal entry.
- Core Manager opcode class decode uses opcode bit fields instead of wider
  range comparators.

## Expected Tradeoff

These changes trade a few cycles of latency for shorter combinational paths:

- `GFILT` gains one cycle per output pixel.
- `TQUANT` takes 16 cycles instead of one.
- `TMAT` gains one cycle for the PE product pipeline.
- Scalar ALU, branch, load and store cycle counts are unchanged.
- Normal scalar, ownership, RAM load/store, TPU load, and non-filter GFX paths
  keep the same behavior.

## Signoff Checklist

To claim true 50 MHz closure on a board:

1. Add the board pin constraints for `dc_board_uart_top`.
2. Constrain the board clock to 20 ns.
3. Run synthesis and place-and-route for the target FPGA.
4. Confirm worst negative slack is non-negative for setup and hold.
5. UART-load `build/pipeline.hex` and confirm `led_boot` then `led_halted`.
