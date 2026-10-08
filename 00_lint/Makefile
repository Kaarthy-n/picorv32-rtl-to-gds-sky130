# ===============================================================================
# Ignytion IO - CRUCIBLE CORE
# File        : picorv32_rtl_to_gds/00_lint/Makefile
# Description : Make entrypoint for picorv32_top Verilator lint.
# ===============================================================================

PROJECT_ROOT := $(abspath ..)
REPORT := $(PROJECT_ROOT)/00_lint/lint_report.txt

# Discover the Sky130 PDK from the ciel install; an already-set PDK_ROOT wins.
PDK_ROOT ?= $(shell find $(HOME)/.ciel -path "*/sky130A/libs.tech/netgen/sky130A_setup.tcl" -print -quit 2>/dev/null | sed 's#/sky130A/libs.tech/netgen/sky130A_setup.tcl##')
export PDK_ROOT
IO_V := $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_io/verilog

.PHONY: all lint clean

all: lint

# The PDK pad models use tranif1 switch primitives, which Verilator rejects,
# so lint against port-only stubs (00_lint/pad_stubs.v) instead.
# -Wno-ASSIGNIN: the clk/resetn input ports feed the padring's inout pad
# ports (we_pad), which Verilator reports as assigning to an input. That is
# the intended pad connection, so it is waived here.
lint:
	cd "$(PROJECT_ROOT)" && igny run verilator --lint-only -Wall -Wno-fatal -Wno-ASSIGNIN --top-module picorv32_top \
		-I01_rtl 00_lint/pad_stubs.v 01_rtl/models/sky130_sram_2kbyte_1rw1r_32x512_8.v 01_rtl/picorv32_top.v \
		> "$(REPORT)" 2>&1 || { cat "$(REPORT)"; exit 1; }
	@echo "lint report: 00_lint/lint_report.txt ($$(grep -c '^%Warning' "$(REPORT)") warnings, 0 errors)"

clean:
	python "$(PROJECT_ROOT)/run.py" clean_files "$(PROJECT_ROOT)" \
		"00_lint/lint_report.txt" \
		"00_lint/lint_stdout.tmp"
