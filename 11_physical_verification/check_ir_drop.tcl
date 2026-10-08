# Static IR drop of the vdd / vss grids on the routed design (OpenROAD PSM),
# supplied from the real pad stubs (see scripts/gen_vsrc.py) rather than the
# default invented bump pattern.
# Usage: PDK_ROOT=... openroad -exit 11_physical_verification/check_ir_drop.tcl
#   (run scripts/gen_vsrc.py first; needs 09_place_and_route/route.odb)
set script_dir [file dirname [file normalize [info script]]]
set root [file normalize [file join $script_dir ..]]
set res [file join $script_dir results]
source [file join $root pdk_libs.tcl]
read_db [file join $root 09_place_and_route route.odb]
foreach l [pdk_liberty_files $::env(PDK_ROOT) tt] { read_liberty $l }
read_sdc [file join $root 04_synthesis constraints.sdc]
set_propagated_clock [all_clocks]
set_wire_rc -signal -layer met2
set_wire_rc -clock -layer met5
estimate_parasitics -global_routing
set_pdnsim_net_voltage -net vdd -voltage 1.8
set_pdnsim_net_voltage -net vss -voltage 0.0
foreach net {vdd vss} {
    puts "=== IR $net"
    analyze_power_grid -net $net -vsrc [file join $res ${net}_src.csv] \
        -error_file [file join $res ir_err_$net.rpt]
}
exit
