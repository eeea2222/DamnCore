# UART Board Boot

`dc_board_uart_top` is the FPGA-facing top for a 50 MHz board clock. It wires a
UART loader into `dc_top`, holds the core in reset while RAM is being filled,
then releases the core to execute from word address 0.

## Pins

Constrain these top-level ports for your board:

- `clk_50mhz`: 50 MHz clock input
- `rst_btn`: active-high reset button
- `uart_rx`: USB-UART RX into the FPGA
- `uart_tx`: USB-UART TX from the FPGA, currently held idle-high
- `led_boot`: boot image accepted and core released
- `led_halted`: core reached `HALT`
- `led_error`: bad UART boot header

## Boot Protocol

Serial format is 8N1. Default baud is 115200.

The host sends:

```text
0x44 0x43              # "DC"
count_lo count_hi      # number of 32-bit words
word0[7:0] ... word0[31:24]
word1[7:0] ... word1[31:24]
...
```

Words are loaded starting at RAM word address 0. A count of zero releases the
core without writing RAM.

## Host Flow

```sh
make asm
python3 tools/uart_boot.py /dev/ttyUSB0 build/pipeline.hex
```

Use the serial port name for your board. Install `pyserial` if the host tool
asks for it.

## Verification

```sh
make uart-boot-sim
make test
```

The UART boot simulation sends a one-word `HALT` image, checks that RAM word 0
was written, and verifies that the core runs the image to `halted`.

## Timing Closure Notes

This repo now provides a 50 MHz-targeted board top, but physical timing closure
still depends on the selected FPGA, pin constraints, synthesis/place-and-route
toolchain, and memory mapping. Add the board constraint file for your target and
run the vendor or open-source timing report with a 20 ns clock constraint.
