UnifiedTensorGraphicsCore — SoC "DamnSoCCore"
A tiny, original AI-native processor core, designed from scratch — not RISC-V, ARM or MIPS, and not a wrapper around any of them. Scalar control, graphics-style tile processing and a TPU-style tensor engine all live inside one core, sharing one unified RAM, coordinated by a central Core Manager. There is no separate VRAM and no separate TPU memory: every unit addresses the same physical memory.

                         ┌───────────────────────────┐
                         │      Core Manager         │  fetch / decode / dispatch
                         │  PC · regfile · scoreboard│  tile-ownership enforcement
                         └─┬────────┬────────┬───────┘
              ┌────────────┘        │        └────────────┐
        ┌─────▼─────┐         ┌─────▼─────┐         ┌──────▼──────┐
        │  Scalar   │         │ Graphics  │         │   Tensor    │
        │  integer  │         │  tile     │         │ 4x4 systolic│
        │   ALU     │         │ processor │         │  INT8 · TPU │
        └─────┬─────┘         └─────┬─────┘         └──────┬──────┘
              └──────────┬──────────┴──────────┬──────────┘
                   ┌─────▼─────┐         ┌──────▼──────┐
                   │  5-port   │         │ tile descr. │
                   │  arbiter  │         │   table     │
                   └─────┬─────┘         └─────────────┘
                   ┌─────▼─────┐
                   │ unified   │  code · data · image/tensor/weight tiles
                   │   RAM     │  framebuffer · tile metadata
                   └───────────┘
Quick start
make tools     # installs icarus-verilog via Homebrew if missing
make sim       # assemble + simulate the example pipeline program
make arb       # arbiter contention / corruption testbench
make uart-boot-sim # simulate the UART board boot path
make test      # golden model + full RTL-vs-golden regression (pytest)
All 18 tests pass: scalar ISA, tile ownership, graphics ops, tensor matmul, quantization, and a full RTL-vs-golden RAM diff of the example pipeline.

The DCN ISA
32-bit fixed-width instructions:

[31:26] op | [25:22] rd | [21:18] rs1 | [17:14] rs2 | [13:0] imm14
16 scalar registers (r0 is hardwired 0), 16 tile descriptors. All addresses are word addresses into the single unified RAM.

class	instructions
scalar	ADD SUB AND OR XOR SHL SHR ADDI LOAD STORE JMP BEQ BNE HALT
tile/CM	TDEF (define descriptor) TOWN (claim) TXFER (transfer) TFREE
graphics	GFILL GCOPY GCVT GNORM GFILT
tensor	TLOAD TMAT TQUANT TSTORE
sync	FENCE WAIT
See docs/ISA.md for full encoding and semantics.

Tile ownership & flow
Every tile has a descriptor: id, base, shape, format, family, owner, state. Families: IMAGE TENSOR WEIGHT FRAME META. States: FREE → OWNED → BUSY → READY. The Core Manager guarantees a tile has exactly one owner: a TOWN that would give a second unit a tile already owned by another is rejected and counted (reject_count), never silently allowed. A tile moves between units only through TXFER. A unit may only operate on a tile it owns, and never reads a tile mid-write (BUSY). This makes graphics → TPU → graphics pipelines safe by construction.

The tensor engine
dc_systolic4.sv is a real 4x4 output-stationary systolic array: 16 multiply-accumulate PEs, activations stream left→right, weights stream top→bottom, each PE accumulates one INT32 dot product of INT8 operands. TQUANT requantizes the INT32 accumulators back to INT8 with an arithmetic shift, optional ReLU and saturating clamp.

Example pipeline
programs/pipeline.dcasm runs the full flow:

image tile → GFX GNORM (center pixels) → TPU matmul (INT8, INT32 accum)
           → TQUANT (shift + ReLU) → GFX GCOPY overlay → framebuffer tile
with every tile hand-off going through an approved ownership transfer.

Project layout
rtl/   dc_pkg  dc_ram  dc_arbiter  dc_tile_table  dc_core_manager
       dc_scalar_unit  dc_gfx_unit  dc_tpu_unit  dc_systolic4  dc_top
       dc_uart_boot  dc_board_uart_top
tb/    tb_damncore (full SoC)   tb_arbiter (contention test)
asm/   assembler.py             — DCN assembler (.dcasm → hex image)
model/ golden.py                — Python golden reference model
tools/ uart_boot.py             — host sender for UART-loaded hex images
programs/ pipeline.dcasm        — example end-to-end program
tests/ test_scalar / test_tiles / test_gfx / test_tpu / test_integration

Board boot
dc_board_uart_top is the pin-agnostic FPGA wrapper for a 50 MHz board clock.
It receives a hex image over UART, writes it into unified RAM while the core is
held in reset, then releases the scalar/GFX/TPU core to execute from address 0.
See docs/BOARD_UART_BOOT.md for the protocol, host command and timing-closure
notes.
How it is verified
model/golden.py is the reference implementation of the ISA, tile rules, graphics ops, matmul and quantization. The RTL testbench runs an assembled program and dumps the final RAM; tests/test_integration.py diffs the entire RTL RAM image against the golden model word-for-word. The tests prove:

scalar instructions execute correctly (RTL == golden);

two units cannot own/write the same tile (reject_count == 1 on a double claim);

the GFX → TPU → GFX hand-off completes with zero rejects;

the systolic INT8 matmul matches the golden reference;

quantization (shift / ReLU / clamp) matches the golden reference;

unified-RAM arbitration grants one port per cycle and corrupts nothing.

Design notes
DamnCore is single-issue and in-order: the Core Manager dispatches one unit at a time and waits for completion, so structural hazards are serialized by the dispatch model itself. The 5-port arbiter still resolves instruction-fetch vs. unit memory traffic every cycle and is stress-tested under full contention by tb_arbiter. FENCE/WAIT are explicit barriers that are conservatively safe given this dispatch model. The dimensions are deliberately small (4x4 tensor tiles, 16 registers, 16 tile descriptors) so the whole core stays readable and testable while still being the complete idea — not a toy subset.

Memory bandwidth
Tile streaming reads in the graphics and tensor units are pipelined: a new RAM read is issued every cycle while the previous cycle's word is captured, so sustained read bandwidth is 1 word/cycle instead of the 2-cycle-per-word request/capture handshake. The capture is gated on a registered grant, so the scheme also stalls correctly under arbiter contention. This cuts the example pipeline from 365 to 304 cycles: a 16-word GFX tile load drops 32→17 cycles and the 32-word TPU TLOAD drops 64→33 cycles.
