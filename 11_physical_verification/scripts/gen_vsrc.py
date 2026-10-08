#!/usr/bin/env python3
"""Write PSM voltage-source files for the pad ring's supply entry points.

The pad-to-ring stubs (24 um wide met3 paths in the routed DEF) are where
core power enters the grid. For each stub the source is placed at its ring
end, the endpoint nearer the die centre. PSM wants no header and four
comma-separated values per line: x, y, size (um), voltage.

Usage: gen_vsrc.py <route.def> <out_dir>   -> <out_dir>/vdd_src.csv, vss_src.csv
"""
import re, sys
from pathlib import Path

deftxt = Path(sys.argv[1]).read_text()
out = Path(sys.argv[2])
VOLT = {"vdd": 1.8, "vss": 0.0}
die = int(re.search(r"DIEAREA\s+\(\s*\d+\s+\d+\s*\)\s+\(\s*(\d+)\s+\d+\s*\)", deftxt).group(1))
centre = die // 2
sp = deftxt[deftxt.index("\nSPECIALNETS"):deftxt.index("END SPECIALNETS")]
src = {n: [] for n in VOLT}
for blk in re.split(r"\n\s*-\s+", sp)[1:]:
    name = blk.split()[0]
    if name not in src:
        continue
    for m in re.finditer(r"(?:\+ ROUTED|NEW)\s+met3\s+23900\s+\+ SHAPE STRIPE\s+\(\s*(\d+)\s+(\d+)\s*\)\s+\(\s*(\d+)\s+(\d+)\s*\)", blk):
        x1, y1, x2, y2 = map(int, m.groups())
        near = lambda x, y: (x - centre) ** 2 + (y - centre) ** 2
        x, y = (x1, y1) if near(x1, y1) < near(x2, y2) else (x2, y2)
        src[name].append((x / 1000, y / 1000))
for n, pts in src.items():
    if not pts:
        sys.exit(f"ERROR: no pad stubs found for {n}")
    (out / f"{n}_src.csv").write_text("".join(f"{x:.3f}, {y:.3f}, 5.0, {VOLT[n]}\n" for x, y in pts))
    print(f"{n}: {len(pts)} sources")
