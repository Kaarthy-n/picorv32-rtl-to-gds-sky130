# ===============================================================================
# Ignytion IO - CRUCIBLE CORE
# File        : picorv32_rtl_to_gds/04_synthesis/Makefile
# Description : Make entrypoint for picorv32_top Yosys synthesis and SDC generation.
# ===============================================================================

PROJECT_ROOT := $(abspath ..)

# pipefail so a failing yosys still fails the target when its output is tee'd
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

# Discover the Sky130 PDK from the ciel install; an already-set PDK_ROOT wins.
PDK_ROOT ?= $(shell find $(HOME)/.ciel -path "*/sky130A/libs.tech/netgen/sky130A_setup.tcl" -print -quit 2>/dev/null | sed 's#/sky130A/libs.tech/netgen/sky130A_setup.tcl##')
export PDK_ROOT
IO_V := $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_io/verilog

.PHONY: all synth sdc clean

all: synth sdc

synth:
	cd "$(PROJECT_ROOT)" && igny run yosys -c 04_synthesis/synth.tcl 2>&1 | tee 04_synthesis/synth.log

sdc:
	cd "$(PROJECT_ROOT)" && igny run yosys -c 04_synthesis/gen_sdc.tcl

clean:
	python "$(PROJECT_ROOT)/run.py" clean_files "$(PROJECT_ROOT)" \
		"04_synthesis/_in.txt" \
		"04_synthesis/_out.txt" \
		"04_synthesis/synth_output.v" \
		"04_synthesis/synth.log" \
		"04_synthesis/constraints.sdc"
