"""Full pipeline: image -> GFX -> TPU -> quant -> GFX -> framebuffer.
Proves the RTL core reproduces the golden reference bit-for-bit, that the
GFX->TPU->GFX hand-off is safe, and that unified RAM is not corrupted."""
import os
import pytest
from helpers import asm_file, run_golden, run_rtl, have_iverilog, ROOT

PIPE = os.path.join(ROOT, 'programs', 'pipeline.dcasm')


def test_pipeline_golden():
    core = run_golden(asm_file(PIPE))
    assert core.halted
    assert core.reject_count == 0, "the pipeline must use only legal hand-offs"
    # framebuffer (0x280) must equal the TPU result tile (0x260)
    fb  = [core.mem[0x280 + i] for i in range(16)]
    trs = [core.mem[0x260 + i] for i in range(16)]
    assert fb == trs
    # weights are all 1 -> each result row is the row-sum of (pixel-128),
    # quantized >>6 with ReLU. row pixels: 200,150,100,50 -> centered
    # 72,22,-28,-78 ; row sums 288,88,-112,-312 ; >>6 = 4,1,-2,-5 -> ReLU
    expect_rows = [4, 1, 0, 0]
    for r in range(4):
        for c in range(4):
            assert fb[r * 4 + c] & 0xFF == expect_rows[r]


@pytest.mark.skipif(not have_iverilog(), reason="iverilog not installed")
def test_pipeline_rtl_matches_golden():
    img = asm_file(PIPE)
    g = run_golden(img)
    r = run_rtl(img, dump=768)
    assert r['halted'] == 1, r['log']
    assert r['reject'] == 0
    # entire dumped RAM image must match the golden model exactly
    for a in range(768):
        assert r['mem'][a] == (g.mem[a] & 0xFFFFFFFF), \
            f"RAM mismatch @{a:#x}: rtl={r['mem'][a]:#x} golden={g.mem[a]:#x}"
