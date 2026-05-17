"""Tensor unit: 4x4 INT8 systolic matmul, INT32 accumulate, quantization."""
import pytest
from helpers import assemble, run_golden, run_rtl, have_iverilog
from golden import matmul4, quantize


def _ref_matmul(a, w):
    c = [0] * 16
    for i in range(4):
        for j in range(4):
            c[i * 4 + j] = sum(a[i * 4 + k] * w[k * 4 + j] for k in range(4))
    return c


def test_matmul_identity():
    a = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
    ident = [1 if i == j else 0 for i in range(4) for j in range(4)]
    assert matmul4(a, ident) == a


def test_matmul_signed():
    a = [70, -30, 20, -80] * 4
    w = [1] * 16                                  # row-sum
    c = matmul4(a, w)
    rowsum = 70 - 30 + 20 - 80
    assert all(c[i] == rowsum for i in range(16))
    assert matmul4(a, w) == _ref_matmul(a, w)


def test_quantize():
    assert quantize(256, 6, False) == 4           # 256>>6
    assert quantize(-256, 6, False) == -4         # arithmetic shift
    assert quantize(-256, 6, True) == 0           # ReLU clamps negatives
    assert quantize(1 << 20, 0, False) == 127     # clamp high
    assert quantize(-(1 << 20), 0, False) == -128 # clamp low


# end-to-end TPU program: GNORM-free, weights all 1 -> row sums, quantized.
TPU_PROG = """
        ADDI r1, r0, d_w
        TDEF t2, r1
        ADDI r1, r0, d_a
        TDEF t1, r1
        ADDI r1, r0, d_r
        TDEF t3, r1
        TOWN  t1, TPU
        TOWN  t2, TPU
        TOWN  t3, TPU
        TLOAD t2, t1
        TMAT
        TQUANT 2, RELU
        TSTORE t3
        HALT
.org 0x40
d_w:    .word 0x240, 0x00040004, 0x0300
d_a:    .word 0x220, 0x00040004, 0x0200
d_r:    .word 0x260, 0x00040004, 0x0200
.org 0x220
A:      .word 8,8,8,8, 4,4,4,4, 16,16,16,16, 1,1,1,1
.org 0x240
W:      .word 1,1,1,1, 1,1,1,1, 1,1,1,1, 1,1,1,1
"""


def test_tpu_program_golden():
    core = run_golden(assemble(TPU_PROG))
    # row sums: 32,16,64,4 ; >>2 = 8,4,16,1
    expect = [8] * 4 + [4] * 4 + [16] * 4 + [1] * 4
    got = [core.mem[0x260 + i] & 0xFF for i in range(16)]
    assert got == expect


@pytest.mark.skipif(not have_iverilog(), reason="iverilog not installed")
def test_tpu_program_rtl():
    img = assemble(TPU_PROG)
    g = run_golden(img)
    r = run_rtl(img)
    assert r['mem'][0x260:0x270] == [g.mem[0x260 + i] for i in range(16)]
