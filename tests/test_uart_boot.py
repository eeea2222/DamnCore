import glob
import os
import subprocess

import pytest

from helpers import BUILD, ROOT, have_iverilog


@pytest.mark.skipif(not have_iverilog(), reason="iverilog/vvp not installed")
def test_uart_boot_halt_image():
    os.makedirs(BUILD, exist_ok=True)
    sim = os.path.join(BUILD, "uart_boot_sim")
    pkg = os.path.join(ROOT, "rtl", "dc_pkg.sv")
    rtl = [pkg] + sorted(f for f in glob.glob(os.path.join(ROOT, "rtl", "*.sv"))
                         if not f.endswith("dc_pkg.sv"))
    tb = os.path.join(ROOT, "tb", "tb_uart_boot.sv")
    subprocess.run(["iverilog", "-g2012", "-o", sim, *rtl, tb],
                   check=True, cwd=ROOT)
    out = subprocess.run(["vvp", os.path.relpath(sim, ROOT)],
                         check=True, capture_output=True, text=True, cwd=ROOT)
    assert "UART boot loaded HALT image and core halted" in out.stdout
