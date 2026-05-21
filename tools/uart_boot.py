#!/usr/bin/env python3
"""Send a DamnCore hex image over the UART boot protocol."""
import argparse
import sys
import time


def read_hex(path):
    words = []
    with open(path) as f:
        for line in f:
            s = line.strip()
            if s:
                words.append(int(s, 16) & 0xFFFFFFFF)
    if len(words) > 0xFFFF:
        raise SystemExit("image is too large for the UART boot header")
    return words


def build_packet(words):
    pkt = bytearray(b"DC")
    pkt += len(words).to_bytes(2, "little")
    for word in words:
        pkt += word.to_bytes(4, "little")
    return pkt


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("port", help="serial port, for example /dev/ttyUSB0")
    ap.add_argument("hex", help="hex image produced by asm/assembler.py")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--reset-delay", type=float, default=0.1,
                    help="seconds to wait after opening the port")
    args = ap.parse_args(argv)

    try:
        import serial
    except ImportError as exc:
        raise SystemExit("install pyserial to use this tool: pip install pyserial") from exc

    words = read_hex(args.hex)
    pkt = build_packet(words)
    with serial.Serial(args.port, args.baud, timeout=1) as ser:
        time.sleep(args.reset_delay)
        ser.write(pkt)
        ser.flush()
    print(f"sent {len(words)} words ({len(pkt)} bytes) to {args.port} @ {args.baud}")


if __name__ == "__main__":
    main()
