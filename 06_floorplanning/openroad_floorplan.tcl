# ===============================================================================
# Ignytion IO - CRUCIBLE CORE
# File        : picorv32_rtl_to_gds/06_floorplanning/openroad_floorplan.tcl
# Description : OpenROAD floorplan for picorv32_top: pad ring, SRAM macro, tap cells, PDN.
# ===============================================================================

# OpenROAD floorplan script for picorv32_top (PicoRV32 + OpenRAM SRAM + sky130_ef_io padring)
# Usage:
#   openroad -exit 06_floorplanning/openroad_floorplan.tcl
#
# Prereqs:
#   - PDK_ROOT set to the Sky130 install root (the stage Makefile discovers it)
#   - 04_synthesis/synth_output.v and 04_synthesis/constraints.sdc exist

set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
set synth_dir [file join $project_root "04_synthesis"]
set netlist [file join $synth_dir "synth_output.v"]
set sdc [file join $synth_dir "constraints.sdc"]

if { ![file exists $netlist] } {
    puts stderr "Missing synthesized netlist: $netlist"
    exit 1
}

if { ![file exists $sdc] } {
    puts stderr "Missing SDC file: $sdc"
    exit 1
}

if { [info exists ::env(PDK_ROOT)] } {
    set pdk_root $::env(PDK_ROOT)
} else {
    puts stderr "PDK_ROOT is not set. Example: export PDK_ROOT=\$HOME/.ciel/ciel/sky130/versions/<hash>"
    exit 1
}

set refs [file join $pdk_root "sky130A" "libs.ref"]
# Older PDK builds ship the tech LEF as sky130_fd_sc_hd.tlef; current ones as ..__nom.tlef.
set tech_lef_src [file join $refs "sky130_fd_sc_hd" "techlef" "sky130_fd_sc_hd.tlef"]
if { ![file exists $tech_lef_src] } {
    set tech_lef_src [file join $refs "sky130_fd_sc_hd" "techlef" "sky130_fd_sc_hd__nom.tlef"]
}
set stdcell_lef  [file join $refs "sky130_fd_sc_hd" "lef" "sky130_fd_sc_hd.lef"]
set io_lef       [file join $refs "sky130_fd_io" "lef" "sky130_ef_io.lef"]
set sram_lef     [file join $refs "sky130_sram_macros" "lef" "sky130_sram_2kbyte_1rw1r_32x512_8.lef"]
set liberty_tt   [file join $refs "sky130_fd_sc_hd" "lib" "sky130_fd_sc_hd__tt_025C_1v80.lib"]
set io_lib       [file join $refs "sky130_fd_io" "lib" "sky130_ef_io__gpiov2_pad_wrapped_tt_tt_025C_1v80_3v30.lib"]
set sram_lib     [file join $refs "sky130_sram_macros" "lib" "sky130_sram_2kbyte_1rw1r_32x512_8_TT_1p8V_25C.lib"]

foreach path [list $tech_lef_src $stdcell_lef $io_lef $sram_lef $liberty_tt $io_lib $sram_lib] {
    if { ![file exists $path] } {
        puts stderr "Missing PDK file: $path"
        exit 1
    }
}

# OpenROAD's read_lef derives OpenDB's internal library name from the LEF
# file's basename. The Sky130 tech LEF and the standard-cell LEF are both
# literally named sky130_fd_sc_hd.* -- reading them back to back under their
# real PDK filenames collides ("library already exists") and silently drops
# the standard-cell macros, breaking link_design later. Read the tech LEF
# from a locally renamed copy to dodge the collision; the PDK itself is
# never modified.
set tech_lef [file join $script_dir "_sky130_tech.tlef"]
file copy -force $tech_lef_src $tech_lef

puts "Using PDK root: $pdk_root"
puts "Netlist: $netlist"
puts "SDC: $sdc"

read_liberty $liberty_tt
read_liberty $io_lib
read_liberty $sram_lib
read_lef $tech_lef
read_lef $stdcell_lef
read_lef $io_lef
read_lef $sram_lef
read_verilog $netlist
link_design picorv32_top

read_sdc $sdc

# -----------------------------------------------------------------------------
# Floorplan geometry (um)
#
# The ring is sized so the pads butt together exactly: each side carries 10
# gpio pads (80 wide) + 4 supply pads (75 wide) = 1100, between two corner
# cells (200 x 204). The pad cells' supply buses (VDDIO/VSSIO/VCCD/VSSD,
# AMUX, VSWITCH, ...) only connect by abutment, so there must be no gaps:
#   die = 204 + 1100 + 200 = 1504 on both axes.
# The core sits inside the deepest pad (gpiov2_pad_wrapped, 211 um) with
# margin for the PDN ring and the pad-to-core stubs.
# -----------------------------------------------------------------------------
set die 1504
set core_lo 270
set core_hi [expr {$die - 270}]

initialize_floorplan \
  -site unithd \
  -die_area "0 0 $die $die" \
  -core_area "$core_lo $core_lo $core_hi $core_hi"

make_tracks

set block [ord::get_db_block]
set dbu [$block getDbUnitsPerMicron]
proc to_dbu {v} { global dbu; return [expr {int(round($v * $dbu))}] }

# -----------------------------------------------------------------------------
# Corner cells. sky130_ef_io__corner_pad is drawn as the top-right corner.
# -----------------------------------------------------------------------------
proc place_fixed {inst orient llx lly} {
    $inst setOrient $orient
    $inst setLocation [to_dbu $llx] [to_dbu $lly]
    $inst setPlacementStatus FIRM
}

# Physical-only cells (corners, bus slices, tap/endcap) are not in the
# synthesized netlist, so create them here.
set corner_master [[ord::get_db] findMaster sky130_ef_io__corner_pad]
foreach {name orient llx lly} [list \
    corner_ne R0   [expr {$die - 200}] [expr {$die - 204}] \
    corner_nw R90  0                   [expr {$die - 200}] \
    corner_sw R180 0                   0 \
    corner_se R270 [expr {$die - 204}] 0 ] {
    set inst [odb::dbInst_create $block $corner_master $name]
    place_fixed $inst $orient $llx $lly
}

# -----------------------------------------------------------------------------
# Pad placement. Instances are named padring.i<side>.ipad[<n>].<...>; n is the
# position in the side's CELLMAP, and positions are packed in that order,
# clockwise starting from the north-west corner. The signal side of each
# cell (y = 0 in the LEF) faces the core: R0 north, R270 east, R180 south,
# R90 west.
# -----------------------------------------------------------------------------
array set side_pads {north {} east {} south {} west {}}
foreach inst [$block getInsts] {
    set mname [[$inst getMaster] getName]
    if { ![string match "sky130_ef_io__*" $mname] || [string match "*corner*" $mname] } { continue }
    if { ![regexp {padring\.i(north|east|south|west)\.ipad\\?\[(\d+)\\?\]} [$inst getName] -> side idx] } {
        puts stderr "ERROR: unexpected pad instance name [$inst getName]"
        exit 1
    }
    lappend side_pads($side) [list $idx $inst]
}

proc dims {inst} {
    set m [$inst getMaster]
    return [list [expr {[$m getWidth] / double([to_dbu 1])}] [expr {[$m getHeight] / double([to_dbu 1])}]]
}

set n_pads 0
foreach side {north east south west} {
    set pads [lsort -integer -index 0 $side_pads($side)]
    if { [llength $pads] != 14 } {
        puts stderr "ERROR: $side side has [llength $pads] pads, expected 14"
        exit 1
    }
    # `pos` is the running edge along the side; north/west grow, east/south shrink.
    switch $side {
        north { set pos 204 }
        east  { set pos [expr {$die - 204}] }
        south { set pos [expr {$die - 204}] }
        west  { set pos 204 }
    }
    foreach p $pads {
        set inst [lindex $p 1]
        lassign [dims $inst] w h
        switch $side {
            north { place_fixed $inst R0   $pos [expr {$die - $h}];           set pos [expr {$pos + $w}] }
            east  { place_fixed $inst R270 [expr {$die - $h}] [expr {$pos - $w}]; set pos [expr {$pos - $w}] }
            south { place_fixed $inst R180 [expr {$pos - $w}] 0;              set pos [expr {$pos - $w}] }
            west  { place_fixed $inst R90  0 $pos;                            set pos [expr {$pos + $w}] }
        }
        incr n_pads
    }
}
puts "Placed $n_pads pad cells + 4 corners"

# -----------------------------------------------------------------------------
# Top-level pins. With a padring every top-level port is the pad's own PAD /
# supply terminal, so each BTerm gets a FIRM pin shape right on top of the
# pad pin it is wired to (instead of place_pins choosing a free edge slot).
# -----------------------------------------------------------------------------
# Placed (die-coordinate) shapes of an instance terminal: {layer x1 y1 x2 y2 ...}.
# The pad masters have ORIGIN 0 0, so the placed bbox lower-left plus the
# orientation maps master coordinates to die coordinates.
proc pin_shapes {it} {
    set inst [$it getInst]
    set m [$inst getMaster]
    set w [$m getWidth]
    set h [$m getHeight]
    set bb [$inst getBBox]
    set ox [$bb xMin]
    set oy [$bb yMin]
    set orient [$inst getOrient]
    set out {}
    foreach mpin [[$it getMTerm] getMPins] {
        foreach box [$mpin getGeometry] {
            set x1 [$box xMin]; set y1 [$box yMin]; set x2 [$box xMax]; set y2 [$box yMax]
            switch $orient {
                R0   { set r [list $x1 $y1 $x2 $y2] }
                R90  { set r [list [expr {$h - $y2}] $x1 [expr {$h - $y1}] $x2] }
                R180 { set r [list [expr {$w - $x2}] [expr {$h - $y2}] [expr {$w - $x1}] [expr {$h - $y1}]] }
                R270 { set r [list $y1 [expr {$w - $x2}] $y2 [expr {$w - $x1}]] }
                default { puts stderr "ERROR: unsupported pad orientation $orient"; exit 1 }
            }
            lassign $r a b c d
            lappend out [$box getTechLayer] [expr {$a + $ox}] [expr {$b + $oy}] [expr {$c + $ox}] [expr {$d + $oy}]
        }
    }
    return $out
}

set supply_pin {vdd VCCD vss VSSD vddio VDDIO vssio VSSIO}
set tech [ord::get_db_tech]
set n_bpins 0
foreach bterm [$block getBTerms] {
    set net [$bterm getNet]
    set bname [$bterm getName]
    set want ""
    if { [dict exists $supply_pin $bname] } { set want [dict get $supply_pin $bname] } else { set want PAD }
    set found 0
    foreach it [$net getITerms] {
        set inst [$it getInst]
        if { ![string match "sky130_ef_io__*" [[$inst getMaster] getName]] } { continue }
        if { [[$it getMTerm] getName] ne $want } { continue }
        # largest geometry of this pin on its top layer
        set best ""
        set best_area -1
        foreach {layer x1 y1 x2 y2} [pin_shapes $it] {
            set a [expr {double($x2 - $x1) * ($y2 - $y1)}]
            if { $a > $best_area } { set best_area $a; set best [list $layer $x1 $y1 $x2 $y2] }
        }
        if { $best eq "" } { continue }
        lassign $best layer x1 y1 x2 y2
        set bpin [odb::dbBPin_create $bterm]
        odb::dbBox_create $bpin $layer $x1 $y1 $x2 $y2
        $bpin setPlacementStatus FIRM
        incr n_bpins
        set found 1
        break
    }
    if { !$found } {
        puts stderr "ERROR: no pad terminal found for port $bname"
        exit 1
    }
}
puts "Created $n_bpins top-level pins on pad terminals"

# Nets that exist only inside the pad ring are not signal-routed: the ioring
# buses (VDDIO_Q, VSWITCH, VCCHIB, VSSIO_Q, AMUX A/B, VDDA, VSSA) connect by
# cell abutment, and each port net just joins a pad's PAD terminal to the
# FIRM pin placed right on top of it. Mark them special so global/detailed
# routing leaves them alone (there are no routing tracks under the pads).
set n_special 0
foreach net [$block getNets] {
    set nm [$net getName]
    set only_pads 1
    foreach it [$net getITerms] {
        if { ![string match "sky130_ef_io__*" [[[$it getInst] getMaster] getName]] } { set only_pads 0; break }
    }
    if { [string match "ioring*" $nm] || ($only_pads && [llength [$net getBTerms]] > 0) } {
        $net setSpecial
        # Take the signal type from the pad terminals (VDDIO_Q is POWER,
        # VSSIO_Q GROUND, AMUXBUS stays SIGNAL, ...), or detailed routing
        # refuses to connect them.
        if { [string match "ioring*" $nm] } {
            set it [lindex [$net getITerms] 0]
            if { $it ne "" } { $net setSigType [[$it getMTerm] getSigType] }
        }
        incr n_special
    }
}
puts "Marked $n_special pad-only nets special"

# -----------------------------------------------------------------------------
# SRAM macro: fixed in the lower half of the core, centred horizontally.
# Its met4 power pins (vccd1/vssd1) are tied into the core grid below.
# -----------------------------------------------------------------------------
set sram [$block findInst "sram.itech.ADDR\\\[0\\\].WORD\\\[0\\\].isky130_sram_2kbyte_1rw1r_32x512_8.memory"]
if { $sram eq "NULL" } {
    foreach i [$block getInsts] {
        if { [[$i getMaster] getName] eq "sky130_sram_2kbyte_1rw1r_32x512_8" } { set sram $i }
    }
}
set sram_w [expr {[[$sram getMaster] getWidth] / double($dbu)}]
set core_bb [$block getCoreArea]
set core_llx [expr {[$core_bb xMin] / double($dbu)}]
set core_lly [expr {[$core_bb yMin] / double($dbu)}]
set core_urx [expr {[$core_bb xMax] / double($dbu)}]
set sram_x [expr {$core_llx + (($core_urx - $core_llx - $sram_w) / 2.0) + 40}]
place_fixed $sram R0 $sram_x [expr {$core_lly + 40}]
puts "SRAM macro [$sram getName] placed at ($sram_x, [expr {$core_lly + 40}])"

# Well-tap / endcap insertion (foundry latch-up rule). Standard cells' VPB/VNB
# body-tie pins only reach the supply through the dedicated tap cells.
# The core supply nets here are the netlist's own `vdd` / `vss` (the pad
# ring's VCCD / VSSD), not VPWR / VGND.
add_global_connection -net vdd -pin_pattern "^VPWR$" -power
add_global_connection -net vss -pin_pattern "^VGND$" -ground
add_global_connection -net vdd -pin_pattern "^VPB$" -power
add_global_connection -net vss -pin_pattern "^VNB$" -ground
add_global_connection -net vdd -pin_pattern "^vccd1$" -power
add_global_connection -net vss -pin_pattern "^vssd1$" -ground

# The corner cells carry the pad ring's shared buses; they are not in the
# netlist, so tie their pins to the same nets the pad cells use.
foreach {pin net} {
    VCCD vdd  VSSD vss  VDDIO vddio  VSSIO vssio
    VDDIO_Q ioring[0]  VSWITCH ioring[1]  VCCHIB ioring[2]  VSSIO_Q ioring[3]
    AMUXBUS_A ioring[4]  AMUXBUS_B ioring[5]  VDDA ioring[6]  VSSA ioring[7]
} {
    add_global_connection -net $net -inst_pattern "corner_.*" -pin_pattern "^${pin}$" \
        -[expr {[string match "VSS*" $pin] || [string match "*AMUX*" $pin] ? "ground" : "power"}]
}

tapcell \
  -tapcell_master "sky130_fd_sc_hd__tapvpwrvgnd_1" \
  -endcap_master "sky130_fd_sc_hd__decap_4" \
  -distance 14

# Power distribution network.
set_voltage_domain -name Core -power vdd -ground vss
define_pdn_grid -name Core -voltage_domains Core

add_pdn_stripe -grid Core -layer met1 -width 0.48 -followpins
add_pdn_ring -grid Core -layers {met4 met5} -widths {5 5} -spacings {2 2} -core_offsets {4 4}
add_pdn_stripe -grid Core -layer met4 -width 3 -pitch 100 -offset 30 -extend_to_core_ring
add_pdn_stripe -grid Core -layer met5 -width 3 -pitch 100 -offset 30 -extend_to_core_ring
# SRAM macro: its met4 vccd1/vssd1 pins are picked up by the core met5 straps.
define_pdn_grid -macro -name SRAM -cells sky130_sram_2kbyte_1rw1r_32x512_8 -grid_over_boundary -voltage_domains Core
add_pdn_connect -grid SRAM -layers {met4 met5}

add_pdn_connect -grid Core -layers {met1 met4}
add_pdn_connect -grid Core -layers {met4 met5}

global_connect
pdngen


# -----------------------------------------------------------------------------
# Pad-to-core power stubs.
#
# The vccd/vssd pads expose their core-facing VCCD/VSSD terminals as met3
# stubs on the cell edge facing the core. Run each stub straight in to the
# matching PDN ring (met5 on the north/south sides, met4 on east/west) and
# drop a via stack where they overlap. The outer ring is vdd; the vss stub
# passes under it on met3 (a different layer, so no contact) before landing
# on the inner vss ring.
# -----------------------------------------------------------------------------
set tech [ord::get_db_tech]
set m3 [$tech findLayer met3]
set v34 [$tech findVia M3M4_PR]
set v45 [$tech findVia M4M5_PR]
if { $v34 eq "NULL" || $v45 eq "NULL" } {
    puts stderr "ERROR: M3M4_PR / M4M5_PR vias not found in tech"
    exit 1
}
set core_hi_um [expr {$core_hi}]

# Ring segments on each side: {net -> side -> {layer lo hi pos}} where pos is the
# ring band's coordinate across the side and lo/hi its extent along it.
proc ring_band {net_name side} {
    global block dbu core_lo core_hi
    set net [$block findNet $net_name]
    set best ""
    foreach sw [$net getSWires] {
        foreach b [$sw getWires] {
            if { [$b isVia] } continue
            set x1 [expr {[$b xMin] / double($dbu)}]; set x2 [expr {[$b xMax] / double($dbu)}]
            set y1 [expr {[$b yMin] / double($dbu)}]; set y2 [expr {[$b yMax] / double($dbu)}]
            set w [expr {$x2 - $x1}]; set h [expr {$y2 - $y1}]
            switch $side {
                north { if { $w > 900 && $h < 10 && $y1 > $core_hi } { set cand [list $b $y1 $y2 $x1 $x2] } else { continue } }
                south { if { $w > 900 && $h < 10 && $y2 < $core_lo } { set cand [list $b $y1 $y2 $x1 $x2] } else { continue } }
                east  { if { $h > 900 && $w < 10 && $x1 > $core_hi } { set cand [list $b $x1 $x2 $y1 $y2] } else { continue } }
                west  { if { $h > 900 && $w < 10 && $x2 < $core_lo } { set cand [list $b $x1 $x2 $y1 $y2] } else { continue } }
            }
            set best $cand
        }
    }
    if { $best eq "" } { puts stderr "ERROR: no $net_name ring on $side side"; exit 1 }
    return $best
}

set n_stubs 0
set n_skipped 0
foreach inst [$block getInsts] {
    set mname [[$inst getMaster] getName]
    if { $mname eq "sky130_ef_io__vccd_hvc_pad" } { set net_name vdd; set pin VCCD } \
    elseif { $mname eq "sky130_ef_io__vssd_hvc_pad" } { set net_name vss; set pin VSSD } \
    else { continue }
    regexp {padring\.i(north|east|south|west)\.} [$inst getName] -> side
    lassign [ring_band $net_name $side] ring ring_lo ring_hi ring_alo ring_ahi
    set sw [odb::dbSWire_create [$block findNet $net_name] ROUTED]
    foreach it [$inst getITerms] {
        if { [[$it getMTerm] getName] ne $pin } continue
        foreach {layer x1 y1 x2 y2} [pin_shapes $it] {
            if { [$layer getName] ne "met3" } continue
            # Only land a stub where the ring actually runs. The inner (vss)
            # ring stops short of the corners, and a supply pad near a corner
            # can have a terminal beyond its end: a stub there would dangle.
            if { $side in {north south} } { set a1 [expr {$x1 / double($dbu)}]; set a2 [expr {$x2 / double($dbu)}] } \
            else { set a1 [expr {$y1 / double($dbu)}]; set a2 [expr {$y2 / double($dbu)}] }
            set over [expr {min($a2, $ring_ahi) - max($a1, $ring_alo)}]
            if { $over < 6.0 } {
                puts "Skipping $net_name stub on [$inst getName]: only [format %.1f $over] um over the ring"
                incr n_skipped
                continue
            }
            # Stub: pad shape extended across to the far edge of the ring band.
            switch $side {
                north { set sx1 $x1; set sx2 $x2; set sy1 [to_dbu $ring_lo]; set sy2 $y2 }
                south { set sx1 $x1; set sx2 $x2; set sy1 $y1; set sy2 [to_dbu $ring_hi] }
                east  { set sy1 $y1; set sy2 $y2; set sx1 [to_dbu $ring_lo]; set sx2 $x2 }
                west  { set sy1 $y1; set sy2 $y2; set sx1 $x1; set sx2 [to_dbu $ring_hi] }
            }
            odb::dbSBox_create $sw $m3 $sx1 $sy1 $sx2 $sy2 STRIPE
            # Via stack across the ring-band overlap, one cut per ~2 um.
            switch $side {
                north { set ox1 $sx1; set ox2 $sx2; set oy1 [to_dbu $ring_lo]; set oy2 [to_dbu $ring_hi] }
                south { set ox1 $sx1; set ox2 $sx2; set oy1 [to_dbu $ring_lo]; set oy2 [to_dbu $ring_hi] }
                east  { set ox1 [to_dbu $ring_lo]; set ox2 [to_dbu $ring_hi]; set oy1 $sy1; set oy2 $sy2 }
                west  { set ox1 [to_dbu $ring_lo]; set ox2 [to_dbu $ring_hi]; set oy1 $sy1; set oy2 $sy2 }
            }
            set step [to_dbu 2]
            set margin [to_dbu 1]
            set oyc [expr {($oy1 + $oy2) / 2}]
            set oxc [expr {($ox1 + $ox2) / 2}]
            set v34_layer_stack [list $v34]
            if { $side in {north south} } { lappend v34_layer_stack $v45 }
            # Vias only where the ring metal really is: clip to the ring's extent
            # along the side. The inner ring stops short of the corners, and a via
            # stack past its end lands on the other net's ring (that was a
            # vdd/vss short in the extracted layout).
            set lo_lim [to_dbu $ring_alo]
            set hi_lim [to_dbu $ring_ahi]
            if { $side in {north south} } {
                set vx0 [expr {max($ox1, $lo_lim) + $margin}]
                set vx1 [expr {min($ox2, $hi_lim) - $margin}]
                for {set vx $vx0} {$vx <= $vx1} {incr vx $step} {
                    foreach v $v34_layer_stack { odb::dbSBox_create $sw $v $vx $oyc STRIPE }
                }
            } else {
                set vy0 [expr {max($oy1, $lo_lim) + $margin}]
                set vy1 [expr {min($oy2, $hi_lim) - $margin}]
                for {set vy $vy0} {$vy <= $vy1} {incr vy $step} {
                    foreach v $v34_layer_stack { odb::dbSBox_create $sw $v $oxc $vy STRIPE }
                }
            }
            incr n_stubs
        }
    }
}
puts "Added $n_stubs pad-to-ring power stubs ($n_skipped skipped: not over the ring)"

write_def [file join $script_dir "floorplan.def"]
write_db [file join $script_dir "floorplan.odb"]

puts "Floorplan complete. Output files:"
puts "  [file join $script_dir "floorplan.def"]"
puts "  [file join $script_dir "floorplan.odb"]"

exit
