#!/usr/bin/env python3
"""
Golden software reference model for DamnCore.

This is the single source of truth the RTL is checked against. It implements
the DCN ISA, the tile-ownership rules, the graphics tile ops, the 4x4 INT8
systolic matmul and the INT32->INT8 quantization -- with exactly the same
semantics as the SystemVerilog core.
"""

# unit / family / state codes (mirror dc_pkg.sv)
U_NONE, U_SCALAR, U_GFX, U_TPU, U_CM = 0, 1, 2, 3, 4
S_FREE, S_OWNED, S_BUSY, S_READY = 0, 1, 2, 3

MASK32 = 0xFFFFFFFF


# ---------------------------------------------------------------- primitives
def s8(word):
    """low 8 bits of a word interpreted as signed INT8."""
    v = word & 0xFF
    return v - 256 if v >= 128 else v


def s14(imm):
    """14-bit immediate as signed."""
    v = imm & 0x3FFF
    return v - 0x4000 if v >= 0x2000 else v


def sext8_to_32(v):
    """signed INT8 value -> 32-bit two's-complement word."""
    return v & MASK32


def matmul4(a, w):
    """4x4 INT8 matmul -> 16 INT32 results. a,w are flat length-16 lists.
       C[i][j] = sum_k A[i][k] * W[k][j]."""
    c = [0] * 16
    for i in range(4):
        for j in range(4):
            acc = 0
            for k in range(4):
                acc += a[i * 4 + k] * w[k * 4 + j]
            c[i * 4 + j] = acc
    return c


def quantize(acc, shift, relu):
    """INT32 accumulator -> INT8 (arithmetic shift, optional ReLU, clamp)."""
    v = acc >> shift                      # arithmetic shift (floor)
    if relu and v < 0:
        v = 0
    if v > 127:
        v = 127
    elif v < -128:
        v = -128
    return v


def clamp(v, lo, hi):
    return lo if v < lo else (hi if v > hi else v)


def box_blur(src, rows, cols):
    """3x3 box blur with clamp-to-edge borders; integer floor divide by 9."""
    out = [0] * (rows * cols)
    for r in range(rows):
        for c in range(cols):
            s = 0
            for dr in (-1, 0, 1):
                for dc in (-1, 0, 1):
                    rr = clamp(r + dr, 0, rows - 1)
                    cc = clamp(c + dc, 0, cols - 1)
                    s += src[rr * cols + cc] & 0xFF
            out[r * cols + c] = s // 9
    return out


# -------------------------------------------------------------- the core sim
class Tile:
    __slots__ = ('base', 'rows', 'cols', 'fam', 'fmt', 'owner', 'state')

    def __init__(self):
        self.base = self.rows = self.cols = self.fam = self.fmt = 0
        self.owner, self.state = U_NONE, S_FREE


class DamnCore:
    """Cycle-agnostic functional model of the DamnCore SoC."""

    def __init__(self, image, ramsize=1 << 16):
        self.mem = [0] * ramsize
        for i, w in enumerate(image):
            self.mem[i] = w & MASK32
        self.reg = [0] * 16
        self.pc = 0
        self.halted = False
        self.reject_count = 0
        self.tiles = [Tile() for _ in range(16)]
        # TPU execution-local state
        self.aflat = [0] * 16
        self.wflat = [0] * 16
        self.cmat = [0] * 16
        self.q = [0] * 16

    # ---- instruction field decode ----
    @staticmethod
    def _fields(w):
        return ((w >> 26) & 0x3F, (w >> 22) & 0xF, (w >> 18) & 0xF,
                (w >> 14) & 0xF, w & 0x3FFF)

    def run(self, max_steps=100000):
        steps = 0
        while not self.halted and steps < max_steps:
            self.step()
            steps += 1
        if not self.halted:
            raise RuntimeError("golden model did not HALT")
        return self

    # ---- one instruction ----
    def step(self):
        w = self.mem[self.pc & 0xFFFF]
        op, rd, rs1, rs2, imm = self._fields(w)
        nxt = (self.pc + 1) & 0xFFFF
        m, reg, t = self.mem, self.reg, self.tiles

        # ---------------- scalar ----------------
        if op == 0x01:    reg[rd] = (reg[rs1] + reg[rs2]) & MASK32
        elif op == 0x02:  reg[rd] = (reg[rs1] - reg[rs2]) & MASK32
        elif op == 0x03:  reg[rd] = reg[rs1] & reg[rs2]
        elif op == 0x04:  reg[rd] = reg[rs1] | reg[rs2]
        elif op == 0x05:  reg[rd] = reg[rs1] ^ reg[rs2]
        elif op == 0x06:  reg[rd] = (reg[rs1] << (imm & 31)) & MASK32
        elif op == 0x07:  reg[rd] = (reg[rs1] & MASK32) >> (imm & 31)
        elif op == 0x08:  reg[rd] = (reg[rs1] + s14(imm)) & MASK32
        elif op == 0x09:  reg[rd] = m[(reg[rs1] + s14(imm)) & 0xFFFF]
        elif op == 0x0A:  m[(reg[rs1] + s14(imm)) & 0xFFFF] = reg[rs2] & MASK32
        elif op == 0x0B:  nxt = imm & 0x3FFF
        elif op == 0x0C:  nxt = (imm & 0x3FFF) if reg[rs1] == reg[rs2] else nxt
        elif op == 0x0D:  nxt = (imm & 0x3FFF) if reg[rs1] != reg[rs2] else nxt
        elif op == 0x0E:  self.halted = True; return
        elif op == 0x00:  pass                                  # NOP

        # ---------------- tile / core-manager ----------------
        elif op == 0x10:                                        # TDEF
            a = reg[rs1] & 0xFFFF
            d0, d1, d2 = m[a], m[a + 1], m[a + 2]
            tl = t[rd]
            tl.base = d0 & 0xFFFF
            tl.rows = (d1 >> 16) & 0xFFFF
            tl.cols = d1 & 0xFFFF
            tl.fam = (d2 >> 8) & 0xF
            tl.fmt = d2 & 0xFF
            tl.owner, tl.state = U_NONE, S_FREE
        elif op == 0x11:                                        # TOWN
            tl, u = t[rd], imm & 7
            if tl.state == S_FREE or tl.owner == u:
                tl.owner, tl.state = u, S_OWNED
            else:
                self.reject_count += 1
        elif op == 0x12:                                        # TXFER
            tl, u = t[rd], imm & 7
            if tl.state not in (S_FREE, S_BUSY):
                tl.owner, tl.state = u, S_READY
            else:
                self.reject_count += 1
        elif op == 0x13:                                        # TFREE
            t[rd].owner, t[rd].state = U_NONE, S_FREE

        # ---------------- graphics ----------------
        elif 0x20 <= op <= 0x24:
            self._gfx(op, rd, rs1, imm)

        # ---------------- tensor ----------------
        elif 0x30 <= op <= 0x33:
            self._tpu(op, rd, rs1, rs2, imm)

        # ---------------- sync ----------------
        elif op in (0x38, 0x39):                                # FENCE / WAIT
            pass
        else:
            raise RuntimeError(f"bad opcode {op:#x} at pc={self.pc}")

        self.reg[0] = 0
        self.pc = nxt

    # ---- graphics ops ----
    def _gfx(self, op, rd, rs1, imm):
        dst, src = self.tiles[rd], self.tiles[rs1]
        # ownership pre-check (mirror of the RTL)
        dst_ok = dst.owner == U_GFX and dst.state not in (S_BUSY, S_FREE)
        src_ok = (op == 0x20) or (
            src.owner == U_GFX and src.state in (S_OWNED, S_READY))
        if not (dst_ok and src_ok):
            self.reject_count += 1
            return
        m = self.mem
        n = dst.rows * dst.cols
        sbuf = [m[(src.base + i) & 0xFFFF] for i in range(n)]
        if op == 0x20:                                          # GFILL
            out = [s14(imm) & MASK32] * n
        elif op == 0x21:                                        # GCOPY
            out = sbuf[:]
        elif op == 0x22:                                        # GCVT (invert)
            out = [(255 - (x & 0xFF)) & MASK32 for x in sbuf]
        elif op == 0x23:                                        # GNORM
            out = [((x & 0xFF) - s14(imm)) & MASK32 for x in sbuf]
        elif op == 0x24:                                        # GFILT
            out = [v & MASK32
                   for v in box_blur(sbuf, src.rows, src.cols)]
        for i, v in enumerate(out):
            m[(dst.base + i) & 0xFFFF] = v
        dst.state = S_READY

    # ---- tensor ops ----
    def _tpu(self, op, rd, rs1, rs2, imm):
        m, T = self.mem, self.tiles
        if op == 0x30:                                          # TLOAD
            wt, at = T[rs1], T[rs2]
            ok = (wt.owner == U_TPU and wt.state in (S_OWNED, S_READY) and
                  at.owner == U_TPU and at.state in (S_OWNED, S_READY))
            if not ok:
                self.reject_count += 1
                return
            self.wflat = [s8(m[(wt.base + i) & 0xFFFF]) for i in range(16)]
            self.aflat = [s8(m[(at.base + i) & 0xFFFF]) for i in range(16)]
        elif op == 0x31:                                        # TMAT
            self.cmat = matmul4(self.aflat, self.wflat)
        elif op == 0x32:                                        # TQUANT
            sh, relu = imm & 0x1F, bool((imm >> 5) & 1)
            self.q = [quantize(c, sh, relu) for c in self.cmat]
        elif op == 0x33:                                        # TSTORE
            dt = T[rd]
            ok = dt.owner == U_TPU and dt.state not in (S_BUSY, S_FREE)
            if not ok:
                self.reject_count += 1
                return
            for i in range(16):
                m[(dt.base + i) & 0xFFFF] = sext8_to_32(self.q[i])
            dt.state = S_READY


def run_image(image, max_steps=100000):
    """Convenience: run a memory image to completion, return the DamnCore."""
    return DamnCore(image).run(max_steps)


if __name__ == '__main__':
    import sys, os
    sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'asm'))
    from assembler import assemble
    src = sys.argv[1] if len(sys.argv) > 1 else \
        os.path.join(os.path.dirname(__file__), '..', 'programs', 'pipeline.dcasm')
    with open(src) as f:
        img = assemble(f.read())
    core = run_image(img)
    print(f"halted, reject_count={core.reject_count}")
    print("framebuffer tile @0x280:",
          [core.mem[0x280 + i] & 0xFF for i in range(16)])
