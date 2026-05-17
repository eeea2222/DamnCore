"""Scalar ISA: golden behaviour + RTL agreement."""
import pytest
from helpers import assemble, run_golden, run_rtl, have_iverilog

PROG = """
        ADDI r1, r0, 5
        ADDI r2, r0, 7
        ADD  r3, r1, r2
        SUB  r4, r2, r1
        XOR  r5, r1, r2
        SHL  r6, r1, 2
        AND  r10, r2, r1
        OR   r11, r1, r2
        SHR  r12, r2, 1
        ADDI r7, r0, 0x100
        STORE r3, r7, 0
        LOAD r8, r7, 0
        ADDI r9, r0, 3
        BEQ  r1, r9, skip
        ADDI r9, r0, 99
skip:   HALT
"""
EXPECT = {1: 5, 2: 7, 3: 12, 4: 2, 5: 2, 6: 20, 8: 12,
          9: 99, 10: 5, 11: 7, 12: 3}


def test_golden_scalar():
    core = run_golden(assemble(PROG))
    for r, v in EXPECT.items():
        assert core.reg[r] == v, f"r{r}={core.reg[r]} expected {v}"
    assert core.mem[0x100] == 12
    assert core.halted


def test_branch_taken():
    core = run_golden(assemble("""
        ADDI r1, r0, 4
        ADDI r2, r0, 4
        BEQ  r1, r2, hit
        ADDI r3, r0, 1
hit:    ADDI r4, r0, 2
        HALT
    """))
    assert core.reg[3] == 0 and core.reg[4] == 2


@pytest.mark.skipif(not have_iverilog(), reason="iverilog not installed")
def test_rtl_matches_golden():
    img = assemble(PROG)
    g = run_golden(img)
    r = run_rtl(img)
    assert r['halted'] == 1
    assert r['reg'] == g.reg, f"RTL {r['reg']} != golden {g.reg}"
    assert r['mem'][0x100] == 12
