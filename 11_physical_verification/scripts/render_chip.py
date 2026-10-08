#!/usr/bin/env python3
"""Chip image from a finished GDS, in SiliconCompiler's screenshot style.

SiliconCompiler's HighResScreenshotFlow is: KLayout takes one PNG per bin
(tools/klayout/scripts/klayout_show.py, see klayout_screenshot.py next to this
file), then ImageMagick `montage` merges the tiles (tools/montage/tile.py):

    montage <tiles, y outer / x inner> -tile <X>x<Y> -geometry +0+0 <design>.png

and an optional ConvertTask-style downsample gives a light preview. Defaults are
SiliconCompiler's (4096x4096 per tile, 10 um margin, linewidth 0, oversampling 2,
hidden layer areaid.standardc for sky130) with the 2x2 bins its heartbeat example uses.

Usage: render_chip.py <gds> <out_dir> [design=picorv32_top] [xbins ybins]
Writes <out_dir>/<design>.png and <out_dir>/<design>_preview.png.
Exit code 2 (with a message) when KLayout, ImageMagick or the PDK display files
are missing, so callers can skip the image.
"""
import glob, os, shutil, subprocess, sys, tempfile
from pathlib import Path

here = Path(__file__).resolve().parent
gds = Path(sys.argv[1]).resolve()
out_dir = Path(sys.argv[2]).resolve()
design = sys.argv[3] if len(sys.argv) > 3 else "picorv32_top"
xbins, ybins = (int(sys.argv[4]), int(sys.argv[5])) if len(sys.argv) > 5 else (2, 2)

RESOLUTION = (4096, 4096)   # per tile, SiliconCompiler default
MARGIN = 10                 # um
LINEWIDTH = 0
OVERSAMPLING = 2
HIDE_LAYERS = ["areaid.standardc"]
PREVIEW = "2048x2048"       # ConvertTask-style resize geometry


def need(cmd):
    path = shutil.which(cmd)
    if not path:
        print(f"{cmd} not found; skipping chip image", file=sys.stderr)
        sys.exit(2)
    return path


klayout, montage, magick = need("klayout"), need("montage"), shutil.which("magick") or need("convert")

# Technology files: SiliconCompiler's sky130 setup (lambdapdk) when installed,
# otherwise the PDK's own klayout tech.
sc = glob.glob(os.path.expanduser("~/.sc/cache/dataroot/lambdapdk-*/lambdapdk/sky130/base/setup/klayout"))
pdk_root = os.environ.get("PDK_ROOT", "")
pdk = glob.glob(os.path.join(pdk_root, "sky130A/libs.tech/klayout/tech")) or \
      glob.glob(os.path.expanduser("~/.ciel/ciel/sky130/versions/*/sky130A/libs.tech/klayout/tech"))
lyt = lyp = None
for d in sc + pdk:
    a = glob.glob(os.path.join(d, "skywater130.lyt")) + glob.glob(os.path.join(d, "sky130A.lyt"))
    b = glob.glob(os.path.join(d, "sky130A.lyp"))
    if a and b:
        lyt, lyp = a[0], b[0]
        break
if not lyt:
    print("sky130 KLayout tech files not found; skipping chip image", file=sys.stderr)
    sys.exit(2)

out_dir.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory() as tmp:
    env = dict(os.environ, QT_QPA_PLATFORM=os.environ.get("QT_QPA_PLATFORM", "offscreen"),
               SHOT_GDS=str(gds), SHOT_LYT=lyt, SHOT_LYP=lyp, SHOT_OUTDIR=tmp, SHOT_DESIGN=design,
               SHOT_BINS=f"{xbins},{ybins}", SHOT_RESOLUTION="%d,%d" % RESOLUTION,
               SHOT_MARGIN=str(MARGIN), SHOT_LINEWIDTH=str(LINEWIDTH),
               SHOT_OVERSAMPLING=str(OVERSAMPLING), SHOT_HIDE_LAYERS=",".join(HIDE_LAYERS))
    # same command line as SiliconCompiler's ScreenshotTask: -nc -z -rm <script>
    r = subprocess.run([klayout, "-nc", "-z", "-rm", str(here / "klayout_screenshot.py")],
                       env=env, capture_output=True, text=True)
    tiles = [Path(tmp) / f"{design}_X{x}_Y{y}.png" for y in range(ybins) for x in range(xbins)]
    if r.returncode != 0 or not all(t.exists() for t in tiles):
        sys.stderr.write(r.stdout[-2000:] + r.stderr[-2000:])
        print("KLayout screenshot failed", file=sys.stderr)
        sys.exit(1)
    out = out_dir / f"{design}.png"
    subprocess.run([montage, *map(str, tiles), "-tile", f"{xbins}x{ybins}", "-geometry", "+0+0", str(out)], check=True)
    print(f"wrote {out}")
    preview = out_dir / f"{design}_preview.png"
    subprocess.run([magick, str(out), "-resize", PREVIEW, str(preview)] if os.path.basename(magick) == "magick"
                   else [magick, str(out), "-resize", PREVIEW, str(preview)], check=True)
    print(f"wrote {preview}")
