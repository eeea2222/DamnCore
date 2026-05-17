# DCN ISA — DamnCore Native

32-bit fixed-width instruction:

```
 31    26 25  22 21  18 17  14 13           0
┌────────┬──────┬──────┬──────┬──────────────┐
│   op   │  rd  │ rs1  │ rs2  │    imm14     │
└────────┴──────┴──────┴──────┴──────────────┘
```

- 16 scalar registers `r0..r15`; `r0` is hardwired to 0.
- 16 tile descriptors `t0..t15`.
- `imm14` is sign-extended for scalar arithmetic / load-store offsets.
- All addresses are **word** addresses into the single unified RAM.

## Opcode map

| op   | mnemonic | form | effect |
|------|----------|------|--------|
| 0x00 | NOP    | —              | no operation |
| 0x01 | ADD    | rd,rs1,rs2     | rd = rs1 + rs2 |
| 0x02 | SUB    | rd,rs1,rs2     | rd = rs1 - rs2 |
| 0x03 | AND    | rd,rs1,rs2     | rd = rs1 & rs2 |
| 0x04 | OR     | rd,rs1,rs2     | rd = rs1 \| rs2 |
| 0x05 | XOR    | rd,rs1,rs2     | rd = rs1 ^ rs2 |
| 0x06 | SHL    | rd,rs1,imm     | rd = rs1 << imm[4:0] |
| 0x07 | SHR    | rd,rs1,imm     | rd = rs1 >> imm[4:0] (logical) |
| 0x08 | ADDI   | rd,rs1,imm     | rd = rs1 + sext(imm) |
| 0x09 | LOAD   | rd,rs1,imm     | rd = MEM[rs1 + sext(imm)] |
| 0x0A | STORE  | rdata,rbase,imm| MEM[rbase + sext(imm)] = rdata |
| 0x0B | JMP    | target         | PC = target |
| 0x0C | BEQ    | rs1,rs2,target | if rs1==rs2: PC = target |
| 0x0D | BNE    | rs1,rs2,target | if rs1!=rs2: PC = target |
| 0x0E | HALT   | —              | stop the core |
| 0x10 | TDEF   | tile,rbase     | load a 3-word descriptor from MEM[rbase] |
| 0x11 | TOWN   | tile,unit      | claim ownership (rejected if owned by another) |
| 0x12 | TXFER  | tile,unit      | transfer ownership to `unit` |
| 0x13 | TFREE  | tile           | release the tile |
| 0x20 | GFILL  | tile,imm       | tile[i] = imm |
| 0x21 | GCOPY  | dst,src        | dst[i] = src[i] |
| 0x22 | GCVT   | dst,src        | dst[i] = 255 - src[i]  (color invert) |
| 0x23 | GNORM  | dst,src,imm    | dst[i] = src[i] - imm  (signed bias) |
| 0x24 | GFILT  | dst,src        | 3x3 box blur, clamp-to-edge borders |
| 0x30 | TLOAD  | wtile,atile    | stage weight + activation tiles into the TPU |
| 0x31 | TMAT   | —              | 4x4 systolic INT8 matmul, INT32 accumulate |
| 0x32 | TQUANT | shift[,RELU]   | INT32 acc → INT8: arith shift, ReLU, clamp |
| 0x33 | TSTORE | tile           | write the 16 quantized INT8 results |
| 0x38 | FENCE  | —              | memory-ordering barrier |
| 0x39 | WAIT   | cycles         | stall the Core Manager for `cycles` |

`unit` codes: `NONE=0 SCALAR=1 GFX=2 TPU=3 CM=4`.
`TQUANT` immediate: bits `[4:0]` = right-shift amount, bit `[5]` = ReLU enable.

## Tile descriptor (in unified RAM, read by TDEF)

A descriptor is 3 consecutive words:

| word | contents |
|------|----------|
| 0    | base address |
| 1    | `rows<<16 | cols` |
| 2    | `family<<8 | format` |

Families: `IMAGE=1 TENSOR=2 WEIGHT=3 FRAME=4 META=5`.

## Tile state machine

```
FREE ──TOWN──▶ OWNED ──(write op dispatched)──▶ BUSY ──(op done)──▶ READY
  ▲              │                                                   │
  └────TFREE─────┴───────────────TXFER (OWNED/READY → READY)──────────┘
```

A unit may read a tile it owns when the state is `OWNED` or `READY`, write it
when not `BUSY`, and never touch a tile owned by another unit. Illegal `TOWN`
and `TXFER` attempts are rejected and counted in `reject_count`.
