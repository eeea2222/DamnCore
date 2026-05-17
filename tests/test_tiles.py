"""Tile ownership: two units can never own the same tile at once;
ownership transfer is the only legal hand-off."""
import pytest
from helpers import assemble, run_golden, run_rtl, have_iverilog
from golden import U_GFX, U_TPU, S_OWNED, S_READY, S_FREE

# t0 defined, claimed by GFX, then a TPU claim is attempted (must be rejected),
# then re-claimed by GFX (same owner -> allowed).
DOUBLE = """
        ADDI r1, r0, dsc
        TDEF t0, r1
        TOWN t0, GFX
        TOWN t0, TPU
        TOWN t0, GFX
        HALT
.org 0x40
dsc:    .word 0x200, 0x00040004, 0x0100
"""

# legal hand-off chain: GFX -> TPU -> GFX via TXFER (no rejects)
HANDOFF = """
        ADDI r1, r0, dsc
        TDEF t0, r1
        TOWN  t0, GFX
        TXFER t0, TPU
        TXFER t0, GFX
        TFREE t0
        HALT
.org 0x40
dsc:    .word 0x200, 0x00040004, 0x0100
"""


def test_double_ownership_rejected_golden():
    core = run_golden(assemble(DOUBLE))
    assert core.reject_count == 1, "TPU claim of a GFX-owned tile must reject"
    assert core.tiles[0].owner == U_GFX
    assert core.tiles[0].state == S_OWNED


def test_handoff_is_clean_golden():
    core = run_golden(assemble(HANDOFF))
    assert core.reject_count == 0
    assert core.tiles[0].state == S_FREE


@pytest.mark.skipif(not have_iverilog(), reason="iverilog not installed")
def test_double_ownership_rejected_rtl():
    assert run_rtl(assemble(DOUBLE))['reject'] == 1


@pytest.mark.skipif(not have_iverilog(), reason="iverilog not installed")
def test_handoff_clean_rtl():
    assert run_rtl(assemble(HANDOFF))['reject'] == 0
