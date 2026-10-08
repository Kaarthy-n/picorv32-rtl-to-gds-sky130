# ===============================================================================
# Ignytion IO - CRUCIBLE CORE
# Copyright (c) 2026 Ignytion IO. All rights reserved.
# Author      : IGNYTION_TECH
# File        : picorv32_rtl_to_gds/09_place_and_route/openroad_route.tcl
# Created     : 2026-09-07
# Description : PicoRV32 project source, configuration, or documentation file.
# ===============================================================================

# OpenROAD global + detailed routing for picorv32_top
# Usage:
#   openroad -exit 09_place_and_route/openroad_route.tcl
#
# Prereqs: 09_place_and_route/cts.odb exists.

set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
set synth_dir [file join $project_root "04_synthesis"]
set sdc [file join $synth_dir "constraints.sdc"]
set cts_db [file join $script_dir "cts.odb"]

if { ![file exists $cts_db] } {
    puts stderr "Missing CTS database: $cts_db"
    puts stderr "Run 09_place_and_route/openroad_cts.tcl first."
    exit 1
}

if { [info exists ::env(PDK_ROOT)] } {
    set pdk_root $::env(PDK_ROOT)
} else {
    puts stderr "PDK_ROOT is not set. Example: \$env:PDK_ROOT = 'C:/Users/<you>/src/sky130A'"
    exit 1
}

source [file join $project_root "pdk_libs.tcl"]
set liberty_files [pdk_liberty_files $pdk_root tt]
set rcx_rules [file join $pdk_root "sky130A" "libs.tech" "openlane" "rcx_rules.info"]

foreach path [concat $liberty_files [list $sdc]] {
    if { ![file exists $path] } {
        puts stderr "Missing required file: $path"
        exit 1
    }
}

puts "Loading CTS database: $cts_db"
read_db $cts_db
foreach lib $liberty_files { read_liberty $lib }
read_sdc $sdc

# Global routing: congestion-driven route plan. met1-met5 for signal, keep
# the clock net on the upper, lower-resistance layers.
# Layer RC for the timing-driven parts of global routing; without it the
# parasitic estimator dereferences an unset layer RC and OpenROAD crashes.
set_wire_rc -signal -layer met2
set_wire_rc -clock  -layer met5

set_routing_layers -signal met1-met5 -clock met3-met5
global_route -critical_nets_percentage 0 -verbose -congestion_report_file [file join $script_dir "route_congestion.rpt"] -guide_file [file join $script_dir "route.guide"]

# Detailed routing (TritonRoute, built into OpenROAD's detailed_route).
detailed_route \
  -output_drc [file join $script_dir "route_drc.rpt"] \
  -output_maze [file join $script_dir "route_maze.log"]

# Extracted parasitics for signoff STA -- 08_sta picks this up automatically.
# write_spef needs real RC extraction data first (define_process_corner +
# extract_parasitics), not just a bare write_spef call -- confirmed live,
# 2026-08-27 (bare write_spef silently no-ops with "no extraction data" and
# never creates the file). rcx_rules.info is OpenRCX's per-process
# extraction ruleset, distributed under libs.tech/openlane/ in this PDK.
if { [file exists $rcx_rules] } {
    define_process_corner -ext_model_index 0 $rcx_rules
    extract_parasitics -ext_model_file $rcx_rules
    write_spef [file join $script_dir "route.spef"]
} else {
    puts "WARNING: no RCX rules file at $rcx_rules -- skipping parasitic extraction."
    puts "  08_sta will fall back to placement-based estimated parasitics."
}

write_def [file join $script_dir "route.def"]
write_db [file join $script_dir "route.odb"]
write_verilog [file join $script_dir "route_output.v"]

puts "Routing complete. Output files:"
puts "  [file join $script_dir "route.def"]"
puts "  [file join $script_dir "route.odb"]"
puts "  [file join $script_dir "route.spef"]"
puts "  [file join $script_dir "route_output.v"]"
puts "  [file join $script_dir "route_drc.rpt"]"

exit
