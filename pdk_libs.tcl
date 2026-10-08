# Shared liberty list for the picorv32_top flow (standard cells + pad + SRAM).
# Usage: source pdk_libs.tcl ; set files [pdk_liberty_files $pdk_root tt]
proc pdk_liberty_files {pdk_root corner} {
    set refs [file join $pdk_root "sky130A" "libs.ref"]
    switch -- $corner {
        tt { set sc "sky130_fd_sc_hd__tt_025C_1v80.lib" }
        ss { set sc "sky130_fd_sc_hd__ss_100C_1v60.lib" }
        ff { set sc "sky130_fd_sc_hd__ff_n40C_1v95.lib" }
    }
    # Pad and SRAM libraries are only characterised at nominal conditions.
    return [list \
        [file join $refs "sky130_fd_sc_hd" "lib" $sc] \
        [file join $refs "sky130_fd_io" "lib" "sky130_ef_io__gpiov2_pad_wrapped_tt_tt_025C_1v80_3v30.lib"] \
        [file join $refs "sky130_sram_macros" "lib" "sky130_sram_2kbyte_1rw1r_32x512_8_TT_1p8V_25C.lib"]]
}

# Cells the resizer must not use as buffers/repair targets: probe cells have a
# second internal output node (LVS sees their X pin on a different net than
# the load) and the lpflow cells are low-power-flow variants. Synthesis already
# excludes the same families.
proc pdk_set_dont_use {} {
    foreach pattern {sky130_fd_sc_hd__probe_* sky130_fd_sc_hd__probec_* sky130_fd_sc_hd__lpflow_*} {
        set_dont_use [get_lib_cells $pattern]
    }
}
