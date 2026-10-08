#!/bin/bash
# Static IR drop with real supply points -> results/ir_drop.txt
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$here/results"
export PDK_ROOT="${PDK_ROOT:-$(find "$HOME/.ciel" -path '*/sky130A/libs.tech/netgen/sky130A_setup.tcl' -print -quit | sed 's#/sky130A/libs.tech/netgen/sky130A_setup.tcl##')}"
python3 "$here/scripts/gen_vsrc.py" "$here/../09_place_and_route/route.def" "$here/results"
cd "$here/.."
igny run openroad -exit 11_physical_verification/check_ir_drop.tcl 2>&1 | tee "$here/results/ir_drop_full.log" \
    | grep -E "=== IR|Net  |Total power|Supply voltage|Worstcase|Average|Percentage" > "$here/results/ir_drop.txt"
cat "$here/results/ir_drop.txt"
