# ===============================================================================
# Ignytion IO - CRUCIBLE CORE
# File        : picorv32_rtl_to_gds/02_sim/Makefile
# Description : Make entrypoint for picorv32_top functional simulation (iverilog).
# ===============================================================================

PROJECT_ROOT := $(abspath ..)
SIM_OUT := 02_sim/picorv32_sim.out

# Discover the Sky130 PDK from the ciel install; an already-set PDK_ROOT wins.
PDK_ROOT ?= $(shell find $(HOME)/.ciel -path "*/sky130A/libs.tech/netgen/sky130A_setup.tcl" -print -quit 2>/dev/null | sed 's#/sky130A/libs.tech/netgen/sky130A_setup.tcl##')
export PDK_ROOT
IO_V := $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_io/verilog

.PHONY: all sim compile run clean

all: sim

sim: compile run

# FUNCTIONAL + USE_POWER_PINS select the behavioural, power-pinned pad models.
compile:
	cd "$(PROJECT_ROOT)" && igny run iverilog -g2012 -DFUNCTIONAL -DUSE_POWER_PINS -DUNIT_DELAY='#0' \
		-o "$(SIM_OUT)" -s tb_picorv32_top \
		01_rtl/picorv32_top.v 01_rtl/models/sky130_sram_2kbyte_1rw1r_32x512_8.v 02_sim/tb_picorv32_top.v \
		$(IO_V)/sky130_ef_io.v $(IO_V)/sky130_fd_io.v

run:
	cd "$(PROJECT_ROOT)" && igny run vvp "$(SIM_OUT)" | tee 02_sim/sim.log
	@grep -q '^PASS' "$(PROJECT_ROOT)/02_sim/sim.log"

clean:
	python ../run.py clean_files "$(PROJECT_ROOT)" "$(SIM_OUT)" "02_sim/sim.log"
