"""Graphics/tile unit: fill, copy, color-convert, normalize, box blur."""
import pytest
from helpers import assemble, run_golden, run_rtl, have_iverilog
from golden import box_blur

GFX = """
        ADDI r1, r0, dsc_a
        TDEF t0, r1
        ADDI r1, r0, dsc_b
        TDEF t1, r1
        TOWN  t0, GFX
        TOWN  t1, GFX
        GFILL t0, 10
        GCVT  t1, t0
        HALT
.org 0x40
dsc_a:  .word 0x200, 0x00040004, 0x0100
dsc_b:  .word 0x220, 0x00040004, 0x0200
"""


def test_gfill_and_gcvt_golden():
    core = run_golden(assemble(GFX))
    assert all(core.mem[0x200 + i] == 10 for i in range(16))
    assert all(core.mem[0x220 + i] == 245 for i in range(16))   # 255-10


def test_gnorm_centering():
    # GNORM subtracts a bias; pixels above/below the bias straddle zero.
    src = list(range(120, 136))                  # 16 pixels 120..135
    core = run_golden(assemble("""
            ADDI r1, r0, da
            TDEF t0, r1
            ADDI r1, r0, db
            TDEF t1, r1
            TOWN  t0, GFX
            TOWN  t1, GFX
            GNORM t1, t0, 128
            HALT
.org 0x40
da:     .word 0x300, 0x00040004, 0x0100
db:     .word 0x320, 0x00040004, 0x0200
.org 0x300
""" + "        .word " + ",".join(str(v) for v in src) + "\n"))
    for i, v in enumerate(src):
        got = core.mem[0x320 + i]
        exp = (v - 128) & 0xFFFFFFFF
        assert got == exp


def test_box_blur_reference():
    # uniform tile blurs to itself; a single bright pixel spreads.
    flat = [50] * 16
    assert box_blur(flat, 4, 4) == [50] * 16
    spike = [0] * 16
    spike[5] = 90                                # interior pixel (1,1)
    out = box_blur(spike, 4, 4)
    assert out[5] == 90 // 9                     # 9 neighbours, floor divide
    assert out[0] == 90 // 9                     # corner sees it too


@pytest.mark.skipif(not have_iverilog(), reason="iverilog not installed")
def test_rtl_matches_golden_gfx():
    img = assemble(GFX)
    g = run_golden(img)
    r = run_rtl(img)
    assert r['mem'][0x200:0x210] == [g.mem[0x200 + i] for i in range(16)]
    assert r['mem'][0x220:0x230] == [g.mem[0x220 + i] for i in range(16)]
