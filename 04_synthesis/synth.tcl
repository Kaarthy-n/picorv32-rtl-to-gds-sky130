# ===============================================================================
# Ignytion IO - CRUCIBLE CORE
# File        : picorv32_rtl_to_gds/04_synthesis/synth.tcl
# Description : Yosys script for picorv32_top (PicoRV32 + SRAM macro + sky130 padring).
# ===============================================================================

# Yosys script for picorv32_top.
# Standard cells map to the Sky130 HD library at the worst-case (ss, 100C,
# 1.60V) corner. The sky130_ef_io pad cells and the OpenRAM SRAM macro are
# hard macros: they are read as blackboxes (-lib) and kept as instances in
# the netlist for OpenROAD to place from their LEFs.
#
# Run from the repo root: yosys -c 04_synthesis/synth.tcl

# $PDK_ROOT is exported by the stage Makefile (04_synthesis/Makefile).
yosys read_verilog -sv -DUSE_POWER_PINS -lib $::env(PDK_ROOT)/sky130A/libs.ref/sky130_fd_io/verilog/sky130_ef_io.v
yosys read_verilog -lib 01_rtl/models/sky130_sram_2kbyte_1rw1r_32x512_8.v
yosys read_verilog -sv 01_rtl/picorv32_top.v
yosys hierarchy -check -top picorv32_top

# The la_* wrappers carry keep_hierarchy; flatten everything but the macros.
yosys setattr -mod -unset keep_hierarchy
yosys synth -flatten -top picorv32_top

yosys dfflibmap -liberty 04_synthesis/lib/sky130_fd_sc_hd__ss_100C_1v60.lib -dont_use sky130_fd_sc_hd__lpflow_*
yosys abc -liberty 04_synthesis/lib/sky130_fd_sc_hd__ss_100C_1v60.lib -D 20000 -dont_use sky130_fd_sc_hd__lpflow_* -dont_use sky130_fd_sc_hd__probe_* -dont_use sky130_fd_sc_hd__clkdlybuf* -dont_use sky130_fd_sc_hd__dlygate* -dont_use sky130_fd_sc_hd__dlymetal*

# Tie cells for constant pad controls, then split multi-bit nets and drop
# unused wires so the netlist is OpenROAD-friendly.
yosys hilomap -hicell sky130_fd_sc_hd__conb_1 HI -locell sky130_fd_sc_hd__conb_1 LO
yosys splitnets -ports
yosys splitnets
yosys opt_clean -purge
yosys insbuf -buf sky130_fd_sc_hd__buf_2 A X
yosys clean

# Area/cell breakdown against the typical corner
yosys stat -liberty 04_synthesis/lib/sky130_fd_sc_hd__tt_025C_1v80.lib

yosys write_verilog -noattr -noexpr 04_synthesis/synth_output.v
