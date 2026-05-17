# ============================================================================
# DamnCore / UnifiedTensorGraphicsCore  --  build & verification
# ============================================================================
IVERILOG ?= iverilog
VVP      ?= vvp
PYTHON   ?= python3

RTL  := rtl/dc_pkg.sv $(filter-out rtl/dc_pkg.sv,$(wildcard rtl/*.sv))
BUILD := build

.PHONY: all asm sim arb golden test clean tools

all: sim test

tools:
	@which $(IVERILOG) >/dev/null 2>&1 || \
	  (echo ">> installing icarus-verilog via Homebrew"; brew install icarus-verilog)

# assemble the example pipeline program
asm: $(BUILD)
	$(PYTHON) asm/assembler.py programs/pipeline.dcasm -o $(BUILD)/pipeline.hex

# compile + run the full SoC testbench on the pipeline program
sim: $(BUILD) asm
	$(IVERILOG) -g2012 -o $(BUILD)/sim $(RTL) tb/tb_damncore.sv
	$(VVP) $(BUILD)/sim +PROG=$(BUILD)/pipeline.hex \
	  +RAMOUT=$(BUILD)/ram_out.hex +STATEOUT=$(BUILD)/state_out.txt +DUMP=768

# arbiter contention / corruption testbench
arb: $(BUILD)
	$(IVERILOG) -g2012 -o $(BUILD)/arb rtl/dc_pkg.sv rtl/dc_arbiter.sv \
	  rtl/dc_ram.sv tb/tb_arbiter.sv
	$(VVP) $(BUILD)/arb

# run the golden model on the pipeline program
golden:
	$(PYTHON) model/golden.py programs/pipeline.dcasm

# full golden + RTL-vs-golden regression
test:
	$(PYTHON) -m pytest tests/ -v

$(BUILD):
	mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD) tests/__pycache__ asm/__pycache__ model/__pycache__
