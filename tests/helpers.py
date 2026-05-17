"""Shared test helpers: assemble, run the golden model, run the RTL sim."""
import os, sys, glob, shutil, subprocess

ROOT  = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, 'build')
sys.path.insert(0, os.path.join(ROOT, 'asm'))
sys.path.insert(0, os.path.join(ROOT, 'model'))

from assembler import assemble          # noqa: E402
from golden import DamnCore             # noqa: E402

_sim_cache = []


def have_iverilog():
    return bool(shutil.which('iverilog') and shutil.which('vvp'))


def asm_file(path):
    with open(path) as f:
        return assemble(f.read())


def run_golden(image):
    core = DamnCore(list(image))
    core.run()
    return core


def compile_rtl():
    """Compile the RTL + testbench once; cached for the session."""
    if _sim_cache:
        return _sim_cache[0]
    os.makedirs(BUILD, exist_ok=True)
    sim = os.path.join(BUILD, 'sim')
    pkg = os.path.join(ROOT, 'rtl', 'dc_pkg.sv')
    rtl = [pkg] + sorted(f for f in glob.glob(os.path.join(ROOT, 'rtl', '*.sv'))
                         if not f.endswith('dc_pkg.sv'))
    tb = os.path.join(ROOT, 'tb', 'tb_damncore.sv')
    subprocess.run(['iverilog', '-g2012', '-o', sim, *rtl, tb],
                   check=True, cwd=ROOT)
    _sim_cache.append(sim)
    return sim


def run_rtl(image, dump=768):
    """Run the RTL sim on a memory image; return dict(mem, reg, reject, halted).

    Paths are passed to vvp *relative* to ROOT: $value$plusargs("%s") stops at
    whitespace, and the project path may contain spaces, so absolute paths
    cannot be passed safely."""
    sim = compile_rtl()
    os.makedirs(BUILD, exist_ok=True)
    prog = os.path.join(BUILD, 'prog.hex')
    ramo = os.path.join(BUILD, 'ram_out.hex')
    stao = os.path.join(BUILD, 'state_out.txt')
    with open(prog, 'w') as f:
        for w in image:
            f.write(f"{w & 0xFFFFFFFF:08x}\n")
    out = subprocess.run(
        ['vvp', os.path.relpath(sim, ROOT),
         '+PROG=build/prog.hex', '+RAMOUT=build/ram_out.hex',
         '+STATEOUT=build/state_out.txt', f'+DUMP={dump}'],
        check=True, capture_output=True, text=True, cwd=ROOT)
    mem = [int(x, 16) for x in open(ramo) if x.strip()]
    reg, reject, halted = [0] * 16, 0, 0
    for line in open(stao):
        p = line.split()
        if p[0].startswith('r') and p[0][1:].isdigit():
            reg[int(p[0][1:])] = int(p[1], 16)
        elif p[0] == 'reject':
            reject = int(p[1])
        elif p[0] == 'halted':
            halted = int(p[1])
    return dict(mem=mem, reg=reg, reject=reject, halted=halted, log=out.stdout)
