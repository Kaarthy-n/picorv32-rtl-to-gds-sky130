# Runs INSIDE KLayout:  klayout -nc -z -rm klayout_screenshot.py
#
# Tiled screenshot of a finished layout, following SiliconCompiler's
# tools/klayout/scripts/klayout_show.py (screenshot mode): technology from a
# .lyt plus a layer-properties file, a black background with grid, ruler and text
# off, the PDK's hidden layers turned off, then one PNG per bin with the same
# tile geometry and file names (<design>_X<x>_Y<y>.png). render_chip.py stitches
# the tiles with ImageMagick montage, as SiliconCompiler's merge step does.
#
# Parameters arrive as environment variables (set by render_chip.py):
#   SHOT_GDS, SHOT_LYT, SHOT_LYP, SHOT_OUTDIR, SHOT_DESIGN,
#   SHOT_BINS="x,y", SHOT_RESOLUTION="w,h", SHOT_MARGIN, SHOT_LINEWIDTH,
#   SHOT_OVERSAMPLING, SHOT_HIDE_LAYERS="a,b"
import os
import pya

env = os.environ
gds, lyt, lyp = env["SHOT_GDS"], env["SHOT_LYT"], env["SHOT_LYP"]
outdir, design = env["SHOT_OUTDIR"], env["SHOT_DESIGN"]
xbins, ybins = (int(v) for v in env["SHOT_BINS"].split(","))
horizontal_resolution, vertical_resolution = (int(v) for v in env["SHOT_RESOLUTION"].split(","))
margin = float(env["SHOT_MARGIN"])
linewidth = int(env["SHOT_LINEWIDTH"])
oversampling = int(env["SHOT_OVERSAMPLING"])
hide_layers = {v for v in env.get("SHOT_HIDE_LAYERS", "").split(",") if v}

# technology: layer-properties file attached to the .lyt (klayout_utils.technology)
tech = pya.Technology.create_technology("sc_tech")
tech.load(lyt)
tech.layer_properties_file = lyp

app = pya.Application.instance()
main_window = pya.MainWindow.instance()
if not main_window:
    raise SystemExit("[ERROR] KLayout main window is not available")

app.set_config("full-hierarchy-new-cell", "true")        # show all cells
for option in ("grid-show-ruler", "grid-visible", "text-visible"):
    app.set_config(option, "false")
app.set_config("background-color", "#000000")            # black

print(f"[INFO] Opening {gds}")
cell_view = main_window.load_layout(gds, tech.name)
view = cell_view.view()

# hide the PDK's non-drawing layers (SiliconCompiler: schema 'hide_layers')
for layer in view.each_layer():
    layer_ldt = f"{layer.source_layer}/{layer.source_datatype}"
    layer_name = layer.source_name or layer.name
    if " " in layer_name:
        layer_name = layer_name.split()[0]
    if layer_name in hide_layers or layer_ldt in hide_layers:
        print(f"[INFO] Turning off layer: {layer_name} : {layer_ldt}")
        layer.visible = False

view.zoom_fit()
cell = view.active_cellview().cell

view_box = cell.dbbox()
view_box.left -= margin
view_box.bottom -= margin
view_box.right += margin
view_box.top += margin

x_incr = int(view_box.width() / xbins)
y_incr = int(view_box.height() / ybins)

if view_box.width() > view_box.height():
    y_px = vertical_resolution
    x_px = int((float(x_incr) / y_incr) * y_px)
else:
    x_px = horizontal_resolution
    y_px = int((float(y_incr) / x_incr) * x_px)

os.makedirs(outdir, exist_ok=True)
for x in range(xbins):
    for y in range(ybins):
        yidx = ybins - y - 1
        output_file = f"{design}_X{x}_Y{yidx}.png"
        x_start = view_box.left + x_incr * x
        y_start = view_box.bottom + y_incr * y
        subbox = pya.DBox(x_start, y_start, x_start + x_incr, y_start + y_incr)
        img_path = os.path.join(outdir, output_file)
        print(f"[INFO] Saving screenshot (({subbox.left}, {subbox.bottom}), "
              f"({subbox.right}, {subbox.top})) to {img_path}")
        view.save_image_with_options(img_path, x_px, y_px, linewidth, oversampling, 0, subbox, False)

# SiliconCompiler: `if sc_exit: pya.Application.instance().exit(0)` -- without it the
# hidden main window keeps the event loop (and the process) alive after the tiles are written.
pya.Application.instance().exit(0)
