# Shape-level power connectivity check, independent of Magic's extraction.
#
# Builds connected pieces from the vdd / vss special-net shapes (PDN wires,
# via metal, the pad-to-ring stubs) plus the pad supply pin shapes, then
# reports which pad VCCD / VSSD stub shapes land in the same piece as the core
# grid (the met1 cell rails). Special nets are unchanged by routing, so the
# floorplan database is enough.
# Usage: openroad -exit 11_physical_verification/check_power_connectivity.tcl
set script_dir [file dirname [file normalize [info script]]]
read_db [file join $script_dir .. 06_floorplanning floorplan.odb]
set block [ord::get_db_block]
set dbu [$block getDbUnitsPerMicron]

proc pin_shapes {it} {
    set inst [$it getInst]; set m [$inst getMaster]
    set w [$m getWidth]; set h [$m getHeight]
    set bb [$inst getBBox]; set ox [$bb xMin]; set oy [$bb yMin]; set orient [$inst getOrient]
    set out {}
    foreach mpin [[$it getMTerm] getMPins] { foreach box [$mpin getGeometry] {
        set x1 [$box xMin]; set y1 [$box yMin]; set x2 [$box xMax]; set y2 [$box yMax]
        switch $orient {
            R0   { set r [list $x1 $y1 $x2 $y2] }
            R90  { set r [list [expr {$h-$y2}] $x1 [expr {$h-$y1}] $x2] }
            R180 { set r [list [expr {$w-$x2}] [expr {$h-$y2}] [expr {$w-$x1}] [expr {$h-$y1}]] }
            R270 { set r [list $y1 [expr {$w-$x2}] $y2 [expr {$w-$x1}]] }
        }
        lassign $r a b c d
        lappend out [[$box getTechLayer] getName] [expr {$a+$ox}] [expr {$b+$oy}] [expr {$c+$ox}] [expr {$d+$oy}]
    } }
    return $out
}

proc analyze {netname pinname} {
    global block
    set net [$block findNet $netname]
    set shapes {}   ;# {layer x1 y1 x2 y2 tag}
    set vid 0
    foreach sw [$net getSWires] { foreach b [$sw getWires] {
        if {[$b isVia]} {
            incr vid
            set tv [$b getTechVia]
            if {$tv eq "NULL"} { set tv [$b getBlockVia] }
            lassign [$b getViaXY] vx vy
            foreach vb [$tv getBoxes] {
                set ln [[$vb getTechLayer] getName]
                if {[string match "met*" $ln] || $ln eq "li1"} {
                    lappend shapes [list $ln [expr {$vx+[$vb xMin]}] [expr {$vy+[$vb yMin]}] [expr {$vx+[$vb xMax]}] [expr {$vy+[$vb yMax]}] via$vid]
                }
            }
        } else {
            lappend shapes [list [[$b getTechLayer] getName] [$b xMin] [$b yMin] [$b xMax] [$b yMax] wire]
        }
    } }
    # pad supply pins of this net
    foreach it [$net getITerms] {
        set m [[$it getInst] getMaster]
        if {[string match "sky130_ef_io__*" [$m getName]] && [[$it getMTerm] getName] eq $pinname} {
            foreach {l a b c d} [pin_shapes $it] {
                if {[string match "met*" $l]} { lappend shapes [list $l $a $b $c $d pad:[[$it getInst] getName]] }
            }
        }
    }
    set n [llength $shapes]
    for {set i 0} {$i < $n} {incr i} { set par($i) $i }
    proc find {x} { upvar par par; while {$par($x) != $x} { set par($x) $par($par($x)); set x $par($x) }; return $x }
    # a via's metal boxes are one conductor: union boxes sharing a via id
    array unset vfirst
    for {set i 0} {$i < $n} {incr i} {
        set t [lindex [lindex $shapes $i] 5]
        if {[string match via* $t]} {
            if {[info exists vfirst($t)]} {
                set ra [find $i]; set rb [find $vfirst($t)]
                if {$ra != $rb} { set par($ra) $rb }
            } else { set vfirst($t) $i }
        }
    }
    # bucket by layer
    array set bylayer {}
    for {set i 0} {$i < $n} {incr i} { lappend bylayer([lindex [lindex $shapes $i] 0]) $i }
    foreach l [array names bylayer] {
        set idx $bylayer($l)
        set k [llength $idx]
        for {set a 0} {$a < $k} {incr a} {
            set ia [lindex $idx $a]; set sa [lindex $shapes $ia]
            lassign [lrange $sa 1 4] ax1 ay1 ax2 ay2
            for {set b [expr {$a+1}]} {$b < $k} {incr b} {
                set ib [lindex $idx $b]; set sb [lindex $shapes $ib]
                if {$ax1 <= [lindex $sb 3] && [lindex $sb 1] <= $ax2 && $ay1 <= [lindex $sb 4] && [lindex $sb 2] <= $ay2} {
                    set ra [find $ia]; set rb [find $ib]
                    if {$ra != $rb} { set par($ra) $rb }
                }
            }
        }
    }
    # report
    array unset comps
    for {set i 0} {$i < $n} {incr i} { lappend comps([find $i]) $i }
    set sizes {}
    foreach r [array names comps] { lappend sizes [list [llength $comps($r)] $r] }
    set sizes [lsort -integer -decreasing -index 0 $sizes]
    puts "== $netname: $n shapes, [llength $sizes] connected pieces"
    set big [lindex $sizes 0]
    set pads_in_big 0; set pads_total 0; set met1_in_big 0
    foreach i $comps([lindex $big 1]) {
        set t [lindex [lindex $shapes $i] 5]
        if {[string match pad:* $t]} { incr pads_in_big }
        if {[lindex [lindex $shapes $i] 0] eq "met1"} { incr met1_in_big }
    }
    for {set i 0} {$i < $n} {incr i} { if {[string match pad:* [lindex [lindex $shapes $i] 5]]} { incr pads_total } }
    puts "   largest piece: [lindex $big 0] shapes, incl. $met1_in_big met1 rail shapes and $pads_in_big of $pads_total pad pin shapes"
    foreach r [lrange $sizes 0 2] {
        array unset lc
        foreach i $comps([lindex $r 1]) { set l [lindex [lindex $shapes $i] 0]; if {![info exists lc($l)]} {set lc($l) 0}; incr lc($l) }
        set desc {}
        foreach l [lsort [array names lc]] { lappend desc "$l=$lc($l)" }
        puts "   piece size [lindex $r 0]: $desc"
    }
    set bigroot [find [lindex [lindex $sizes 0] 1]]
    for {set i 0} {$i < $n} {incr i} {
        set sh [lindex $shapes $i]
        if {[string match pad:* [lindex $sh 5]] && [lindex $sh 0] eq "met3"} {
            puts "   stub [lindex $sh 5] ([expr {[lindex $sh 1]/1000}],[expr {[lindex $sh 2]/1000}]): [expr {[find $i] == $bigroot ? "CONNECTED to core grid" : ([llength $comps([find $i])] == 1 ? "bare pad terminal, no stub (not used)" : "DANGLING: stub not connected to the grid ([llength $comps([find $i])] shapes)")}]"
        }
    }
    puts "   next pieces sizes: [lrange [lmap s $sizes {lindex $s 0}] 1 8]"
}
analyze vdd VCCD
analyze vss VSSD
exit
