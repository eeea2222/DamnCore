#!/usr/bin/env python3
"""
DCN assembler -- DamnCore Native ISA.

Assembles .dcasm text into a flat 32-bit word memory image (hex, one word per
line) suitable for Verilog $readmemh and for the Python golden model.

Instruction word: [31:26] op | [25:22] rd | [21:18] rs1 | [17:14] rs2 | [13:0] imm

Operand forms
  ADD/SUB/AND/OR/XOR  rd, rs1, rs2
  SHL/SHR/ADDI/LOAD   rd, rs1, imm
  STORE               rdata, rbase, imm        ; MEM[rbase+imm] = rdata
  JMP                 target
  BEQ/BNE             rs1, rs2, target
  HALT / NOP / TMAT / FENCE
  TDEF                tile, rbase              ; load descriptor at MEM[rbase]
  TOWN/TXFER          tile, unit               ; unit: NONE|SCALAR|GFX|TPU|CM
  TFREE / TSTORE      tile
  GFILL               tile, imm
  GCOPY/GCVT/GFILT    dtile, stile
  GNORM               dtile, stile, imm
  TLOAD               wtile, atile
  TQUANT              shift [, RELU]
  WAIT                cycles

Directives:  .org ADDR   .word v0, v1, ...   (values may be labels)
Comments start with ';' or '#'.
"""
import sys, re

OPC = {
    'NOP':0x00,'ADD':0x01,'SUB':0x02,'AND':0x03,'OR':0x04,'XOR':0x05,
    'SHL':0x06,'SHR':0x07,'ADDI':0x08,'LOAD':0x09,'STORE':0x0A,'JMP':0x0B,
    'BEQ':0x0C,'BNE':0x0D,'HALT':0x0E,
    'TDEF':0x10,'TOWN':0x11,'TXFER':0x12,'TFREE':0x13,
    'GFILL':0x20,'GCOPY':0x21,'GCVT':0x22,'GNORM':0x23,'GFILT':0x24,
    'TLOAD':0x30,'TMAT':0x31,'TQUANT':0x32,'TSTORE':0x33,
    'FENCE':0x38,'WAIT':0x39,
}
UNIT = {'NONE':0,'SCALAR':1,'GFX':2,'TPU':3,'CM':4}

FORM = {  # mnemonic -> operand form tag
    'ADD':'RRR','SUB':'RRR','AND':'RRR','OR':'RRR','XOR':'RRR',
    'SHL':'RRI','SHR':'RRI','ADDI':'RRI','LOAD':'RRI',
    'STORE':'ST','JMP':'J','BEQ':'BR','BNE':'BR',
    'HALT':'N','NOP':'N','TMAT':'N','FENCE':'N',
    'TDEF':'TR','TOWN':'TU','TXFER':'TU','TFREE':'T','TSTORE':'T',
    'GFILL':'GI','GCOPY':'GG','GCVT':'GG','GFILT':'GG','GNORM':'GNI',
    'TLOAD':'TL','TQUANT':'QI','WAIT':'WI',
}


class AsmError(Exception):
    pass


def _reg(tok):
    t = tok.lower()
    if not (t.startswith('r') and t[1:].isdigit()):
        raise AsmError(f"expected register, got '{tok}'")
    n = int(t[1:])
    if not 0 <= n < 16:
        raise AsmError(f"register out of range: '{tok}'")
    return n


def _tile(tok):
    t = tok.lower()
    if not (t.startswith('t') and t[1:].isdigit()):
        raise AsmError(f"expected tile id, got '{tok}'")
    n = int(t[1:])
    if not 0 <= n < 16:
        raise AsmError(f"tile id out of range: '{tok}'")
    return n


def _num(tok, labels):
    t = tok.strip()
    if t.upper() in UNIT:
        return UNIT[t.upper()]
    if t in labels:
        return labels[t]
    try:
        return int(t, 0)
    except ValueError:
        raise AsmError(f"cannot resolve value '{tok}'")


def _split(line):
    line = re.split(r'[;#]', line, maxsplit=1)[0].strip()
    return line


def encode(op, rd=0, rs1=0, rs2=0, imm=0):
    imm &= 0x3FFF
    return ((op & 0x3F) << 26) | ((rd & 0xF) << 22) | \
           ((rs1 & 0xF) << 18) | ((rs2 & 0xF) << 14) | imm


def assemble(text):
    """Return a list of 32-bit ints (the memory image)."""
    raw = []
    for ln in text.splitlines():
        s = _split(ln)
        if s:
            raw.append(s)

    # ---- pass 1: addresses + labels ----
    labels, addr, items = {}, 0, []
    for s in raw:
        while ':' in s:
            lbl, _, rest = s.partition(':')
            lbl = lbl.strip()
            if not re.match(r'^[A-Za-z_]\w*$', lbl):
                raise AsmError(f"bad label '{lbl}'")
            labels[lbl] = addr
            s = rest.strip()
            if not s:
                break
        if not s:
            continue
        toks = s.replace(',', ' ').split()
        head = toks[0]
        if head.lower() == '.org':
            addr = int(toks[1], 0)
            items.append(('org', addr))
        elif head.lower() == '.word':
            items.append(('word', addr, toks[1:]))
            addr += len(toks) - 1
        else:
            items.append(('insn', addr, toks))
            addr += 1
    size = addr

    # ---- pass 2: emit ----
    mem = [0] * size
    for it in items:
        if it[0] == 'org':
            continue
        if it[0] == 'word':
            a, vals = it[1], it[2]
            for i, v in enumerate(vals):
                mem[a + i] = _num(v, labels) & 0xFFFFFFFF
            continue
        a, toks = it[1], it[2]
        m = toks[0].upper()
        args = toks[1:]
        if m not in OPC:
            raise AsmError(f"unknown mnemonic '{toks[0]}'")
        op, form = OPC[m], FORM[m]
        try:
            if form == 'RRR':
                w = encode(op, _reg(args[0]), _reg(args[1]), _reg(args[2]))
            elif form == 'RRI':
                w = encode(op, _reg(args[0]), _reg(args[1]),
                           imm=_num(args[2], labels))
            elif form == 'ST':
                w = encode(op, 0, _reg(args[1]), _reg(args[0]),
                           _num(args[2], labels))
            elif form == 'J':
                w = encode(op, imm=_num(args[0], labels))
            elif form == 'BR':
                w = encode(op, 0, _reg(args[0]), _reg(args[1]),
                           _num(args[2], labels))
            elif form == 'N':
                w = encode(op)
            elif form == 'TR':
                w = encode(op, _tile(args[0]), _reg(args[1]))
            elif form == 'TU':
                w = encode(op, _tile(args[0]), imm=_num(args[1], labels))
            elif form == 'T':
                w = encode(op, _tile(args[0]))
            elif form == 'GI':
                w = encode(op, _tile(args[0]), imm=_num(args[1], labels))
            elif form == 'GG':
                w = encode(op, _tile(args[0]), _tile(args[1]))
            elif form == 'GNI':
                w = encode(op, _tile(args[0]), _tile(args[1]),
                           imm=_num(args[2], labels))
            elif form == 'TL':
                w = encode(op, 0, _tile(args[0]), _tile(args[1]))
            elif form == 'QI':
                imm = _num(args[0], labels) & 0x1F
                if len(args) > 1 and args[1].upper() == 'RELU':
                    imm |= 0x20
                w = encode(op, imm=imm)
            elif form == 'WI':
                w = encode(op, imm=_num(args[0], labels))
            else:
                raise AsmError(f"internal: form {form}")
        except IndexError:
            raise AsmError(f"too few operands for '{m}'")
        mem[a] = w & 0xFFFFFFFF
    return mem


def main():
    if len(sys.argv) < 2:
        print("usage: assembler.py prog.dcasm [-o out.hex]", file=sys.stderr)
        sys.exit(1)
    src = sys.argv[1]
    out = 'out.hex'
    if '-o' in sys.argv:
        out = sys.argv[sys.argv.index('-o') + 1]
    with open(src) as f:
        mem = assemble(f.read())
    with open(out, 'w') as f:
        for w in mem:
            f.write(f"{w & 0xFFFFFFFF:08x}\n")
    print(f"assembled {len(mem)} words -> {out}")


if __name__ == '__main__':
    main()
