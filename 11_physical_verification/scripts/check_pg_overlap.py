#!/usr/bin/env python3
"""vdd/vss short check on the finished layout: geometry of the power nets only.

Reads the routed DEF (09_place_and_route/route.def) for the vdd and vss
special nets (wire paths + vias) and the via cell shapes from the GDS, then
reports any vdd shape that overlaps a vss shape on the same layer. Wire ends
are flush (the GDS paths are pathtype 0). Exits non-zero on any overlap.

The GDS via cells hold only the cut shapes (no metal pads), and cut layers
share a layer number with the metal above them (71 = met4 and via4, datatype
20 vs 44). So the check has two parts: metal vs metal of the other net, and
each cut of one net against the other net's metal on the two layers it joins
(a cut landing on the other net's metal ties the two nets together).
"""
import collections, re, struct, sys
from pathlib import Path

root = Path(__file__).resolve().parents[2]
gds = (root / "10_gds/picorv32_top.gds").read_bytes()
deftxt = (root / "09_place_and_route/route.def").read_text()

rects = collections.defaultdict(list)
cur = ly = dt = pts = None
inb = False
i = 0
while i + 4 <= len(gds):
    n, t = struct.unpack(">HH", gds[i:i + 4]); p = gds[i + 4:i + n]
    if t == 0x0606: cur = p.rstrip(b"\0").decode()
    if t == 0x0800: inb = True; ly = dt = pts = None
    if inb:
        if t == 0x0D02: ly = struct.unpack(">h", p)[0]
        if t == 0x0E02: dt = struct.unpack(">h", p)[0]
        if t == 0x1003: pts = struct.unpack(">%di" % (len(p) // 4), p)
        if t == 0x1100:
            inb = False
            if cur and cur.startswith(("via", "M1M2", "M2M3", "M3M4", "M4M5", "L1M1")) and dt in (20, 44):
                xs, ys = pts[0::2], pts[1::2]
                rects[cur].append((ly, dt, min(xs), min(ys), max(xs), max(ys)))
    i += n

LAYER = {"met1": 68, "met2": 69, "met3": 70, "met4": 71, "met5": 72}
sp = deftxt[deftxt.index("\nSPECIALNETS"):deftxt.index("END SPECIALNETS")]
shapes = {"vdd": [], "vss": []}
pat = re.compile(r"(?:\+ ROUTED|NEW)\s+(met\d)\s+(\d+)\s+\+ SHAPE \w+\s+\(\s*(\d+)\s+(\d+)\s*\)\s*"
                 r"(?:\(\s*(\d+|\*)\s+(\d+|\*)\s*\)\s*)?(\w+)?")
for blk in re.split(r"\n\s*-\s+", sp)[1:]:
    name = blk.split()[0]
    if name not in shapes: continue
    for m in pat.finditer(blk):
        lay, w, x1, y1, x2, y2, via = m.groups(); w = int(w); x1 = int(x1); y1 = int(y1)
        if x2 is None:
            if via:
                shapes[name] += [(l, d_, x1 + a, y1 + b, x1 + c, y1 + e) for l, d_, a, b, c, e in rects.get(via, [])]
            continue
        x2 = x1 if x2 == "*" else int(x2); y2 = y1 if y2 == "*" else int(y2); h = w // 2
        if x1 == x2: shapes[name].append((LAYER[lay], 20, x1 - h, min(y1, y2), x1 + h, max(y1, y2)))
        else: shapes[name].append((LAYER[lay], 20, min(x1, x2), y1 - h, max(x1, x2), y1 + h))
        if via:
            shapes[name] += [(l, d_, x2 + a, y2 + b, x2 + c, y2 + e) for l, d_, a, b, c, e in rects.get(via, [])]

def ov(r, s_):
    return r[2] < s_[4] and s_[2] < r[4] and r[3] < s_[5] and s_[3] < r[5]

def conflicts(a, b):
    """Shapes of net a that touch net b's metal."""
    metal = collections.defaultdict(list)
    for s_ in shapes[b]:
        if s_[1] == 20: metal[s_[0]].append(s_)
    out = []
    for r in shapes[a]:
        if r[1] == 20:                       # metal on metal, same layer
            targets = metal[r[0]]
        else:                                # cut on layer L joins metal L and L+1 (via4 = 71/44 joins met4 and met5)
            targets = metal[r[0]] + metal[r[0] + 1]
        out += [(r, s_) for s_ in targets if ov(r, s_)]
    return out

bad = conflicts("vdd", "vss") + [(s_, r) for r, s_ in conflicts("vss", "vdd")]
print(f"vdd shapes {len(shapes['vdd'])}, vss shapes {len(shapes['vss'])}; vdd/vss conflicts: {len(bad)}")
for r, s_ in bad[:10]:
    print(f"  {'cut' if r[1] == 44 else 'metal'} layer {r[0]}: {[v / 1000 for v in r[2:]]}  vs other-net metal {s_[0]}: {[v / 1000 for v in s_[2:]]}")
sys.exit(1 if bad else 0)
