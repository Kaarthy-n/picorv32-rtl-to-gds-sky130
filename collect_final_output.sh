#!/bin/bash
# Collect the final deliverables and reports into final_output/.
# Re-run after any stage to refresh. Missing inputs are reported, not fatal.
set -u
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$root/final_output"
rm -rf "$out"; mkdir -p "$out"/{gds,netlist,layout,constraints,reports,images}

put() { # put <src> <dest-dir> [new-name]
    if [ -f "$1" ]; then cp "$1" "$out/$2/${3:-$(basename "$1")}"; else echo "missing: $1" >&2; fi
}

put "$root/10_gds/picorv32_top.gds"                 gds
put "$root/04_synthesis/synth_output.v"             netlist synth_netlist.v
put "$root/09_place_and_route/route_output.v"       netlist routed_netlist.v
put "$root/09_place_and_route/route.def"            layout
put "$root/09_place_and_route/route.odb"            layout
put "$root/06_floorplanning/floorplan.def"          layout
put "$root/04_synthesis/constraints.sdc"            constraints

r="$out/reports"
put "$root/00_lint/lint_report.txt"                 reports lint.txt
put "$root/02_sim/sim.log"                          reports simulation.log
put "$root/08_sta/timing_report_tt.txt"             reports sta_tt.txt
put "$root/08_sta/timing_report_ss.txt"             reports sta_ss.txt
put "$root/09_place_and_route/route_drc.rpt"        reports route_drc.rpt
put "$root/11_physical_verification/results/physical_verification_status.txt" reports physical_verification_status.txt
put "$root/11_physical_verification/results/magic_drc_extract.log" reports magic_drc_extract.log
put "$root/11_physical_verification/results/netgen_lvs.log" reports netgen_lvs.log
put "$root/11_physical_verification/results/pg_overlap_check.txt" reports pg_overlap_check.txt
put "$root/11_physical_verification/results/ir_drop.txt" reports ir_drop.txt
# Synthesis area/cell report: the `stat` section of the yosys log, if present.
if [ -f "$root/04_synthesis/synth.log" ]; then cp "$root/04_synthesis/synth.log" "$r/synthesis.log"; fi

# Chip image in SiliconCompiler's screenshot style (KLayout tiles stitched with ImageMagick
# montage, see 11_physical_verification/scripts/render_chip.py). Skipped with a note when
# KLayout or ImageMagick is not installed.
if [ -f "$out/gds/picorv32_top.gds" ]; then
    python3 "$root/11_physical_verification/scripts/render_chip.py" "$out/gds/picorv32_top.gds" "$out/images" picorv32_top \
        || echo "note: chip image not generated" >&2
fi

# Summary of the key numbers, straight from the reports.
{
echo "# picorv32_top final output"
echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo
echo "## Files"
(cd "$out" && find . -type f ! -name SUMMARY.md | sort | while read -r f; do printf '%s  (%s)\n' "$f" "$(du -h "$f" | cut -f1)"; done)
echo
echo "## Simulation"; grep -m1 -E "^(PASS|FAIL)" "$r/simulation.log" 2>/dev/null || echo "no log"
echo
echo "## Route DRC (TritonRoute)"
if [ -f "$r/route_drc.rpt" ]; then
    if [ -s "$r/route_drc.rpt" ]; then echo "NON-EMPTY: $(wc -c < "$r/route_drc.rpt") bytes"; else echo "empty report: 0 violations"; fi
fi
echo
for c in tt ss; do
    echo "## STA $c"
    grep -A4 "== Summary" "$r/sta_$c.txt" 2>/dev/null | tail -n +2 || echo "no report"
    echo
done
echo "## Physical verification"
sed -n '/Layout SPICE/,$p' "$r/physical_verification_status.txt" 2>/dev/null | head -8
} > "$out/SUMMARY.md"
echo "wrote $out"
