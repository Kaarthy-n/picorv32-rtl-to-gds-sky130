# PicoRV32 with Pad Ring, RTL to GDS (SKY130)

RTL-to-GDS flow for `picorv32_top`: a PicoRV32 RV32I core, a 2 KB OpenRAM
SRAM macro (`sky130_sram_2kbyte_1rw1r_32x512_8`) and a `sky130_ef_io` pad ring
(40 gpio pads + vdd/vss/vddio/vssio supply pads on each of the four sides),
targeting the open **SKY130** PDK. Orchestrated end-to-end with `make`, using
`igny` (Crucible) to provide every EDA tool as a reproducible, versioned
binding. Derived from the APB RTL-to-GDS flow in the sibling repo.

<p align="center">
  <img src="docs/images/picorv32_top.png" alt="Final layout of picorv32_top: pad ring, PicoRV32 standard cells, SRAM macro and power grid" width="720">
</p>
<p align="center"><em>Final layout (GDS) of <code>picorv32_top</code>: 1504 x 1504 um die with the sky130_ef_io pad ring, the PicoRV32 standard cells, the 2 KB SRAM macro (bottom) and the PDN.</em></p>

## Design

| Item | Value |
|---|---|
| Top | `picorv32_top` (`01_rtl/picorv32_top.v`: core, `la_spram`, `la_padring`) |
| Clock | `clk` pad, 50 MHz (20 ns) |
| Reset | `resetn` pad (active low) |
| Outputs | `trap`, `mem_valid`, `mem_la_read`, `mem_la_write`, `mem_la_wstrb[3:0]`, `mem_addr[29:0]` (word address) |
| Supplies | `vdd`/`vss` (core), `vddio`/`vssio` (IO), one pad of each per side |
| Memory | program and data live in the on-die SRAM; the bus is also brought out on pads for observation |
| Die | 1504 x 1504 um, core 270..1234 um, pad cells butted so the ring buses connect by abutment |

Pad placement and cell orientation are computed in
`06_floorplanning/openroad_floorplan.tcl` from the instance names
(`padring.i<side>.ipad[n]`), so the ring order follows the CELLMAP in the RTL.

## Flow stages

Each stage is a numbered directory with its own `Makefile`, driven from the
top-level `Makefile`:

| Stage | Directory | Tool(s) | Purpose |
|---|---|---|---|
| 1 | `00_lint` | `verilator` | RTL lint |
| 2 | `01_rtl` | — | RTL (`picorv32_top.v`) and the SRAM behavioural model (`models/`) |
| 3 | `02_sim` | `iverilog` | Functional simulation with pad and SRAM models |
| 4 | `03_verification` | `iverilog` | Self-checking regression (re-runs `02_sim`) |
| 5 | `04_synthesis` | `yosys` | Logic synthesis against the SKY130 lib |
| 6 | `05_dft` | — | Design-for-test |
| 7 | `06_floorplanning` | `openroad` | Floorplan |
| 8 | `07_placement` | `openroad` | Placement |
| 9 | `08_sta` | `openroad` | Static timing analysis (std cells + pad + SRAM libs) |
| 10 | `09_place_and_route` | `openroad` | CTS + routing |
| 11 | `10_gds` | `klayout-stream` | GDS streamout |
| 12 | `11_physical_verification` | `python`, `openroad`, `magic`, `netgen` | vdd/vss short check, static IR drop, DRC, extraction, LVS (pads and SRAM blackboxed) |

## Running the flow

All commands run through `igny` inside the `picorv32_ignytion` Crucible environment
bound to this workspace (`crucible.toml`).

```bash
igny run make            # full flow: lint → sim → verify → synth → floorplan → place → cts → route → sta → gds → physical → final
igny run make lint       # 00_lint only
igny run make sim        # 02_sim only
igny run make verify     # 03_verification only
igny run make synth      # 04_synthesis only
igny run make dft        # 05_dft only
igny run make floorplan  # 06_floorplanning only
igny run make place      # 07_placement only
igny run make cts        # 09_place_and_route cts
igny run make route      # 09_place_and_route route
igny run make sta        # 08_sta only
igny run make gds        # 10_gds only
igny run make physical   # 11_physical_verification only (includes the static IR drop)
igny run make final      # collect deliverables and reports into final_output/
igny run make clean      # remove generated artifacts across all stages, including final_output/
```

## Reproducing the toolchain

Run `igny workspace lock` once to generate `crucible.lock` for this workspace (not copied from the APB repo). On another machine:

```bash
igny workspace sync   # installs + binds every tool in crucible.lock
igny status            # confirm environment + tool count
```

## Notes

- The image above is a 2048 px copy of `final_output/images/picorv32_top.png`, which
  `make final` renders (8192 px) from `10_gds/picorv32_top.gds`; refresh it with
  `cp final_output/images/picorv32_top_preview.png docs/images/picorv32_top.png`.

- `make lint` writes `00_lint/lint_report.txt` and `make synth` writes
  `04_synthesis/synth.log`; both are copied into `final_output/reports/`.
- `make physical` runs, in order: the vdd/vss geometry short check
  (`scripts/check_pg_overlap.py`), static IR drop with the supplies placed at
  the real pad stubs (`run_ir_drop.sh`), Magic DRC + extraction, and Netgen LVS.
  Magic's per-cell `.ext` files go to `11_physical_verification/results/extract/`.
- Simulation needs the power-pinned functional pad models: the stage passes
  `-DFUNCTIONAL -DUSE_POWER_PINS` and the bench forces the shared `ioring`
  rails (see `02_sim/tb_picorv32_top.v`).
- `01_rtl/models/sky130_sram_2kbyte_1rw1r_32x512_8.v` is the PDK model with a
  `timescale` added and the `mem` declaration moved ahead of first use so
  iverilog accepts it.
- Synthesis keeps the pad cells and SRAM as blackboxes; OpenROAD places them
  from the PDK LEFs. Pad-only nets (`ioring[*]`, pad `PAD` nets) are marked
  special so global routing skips them.
- The vdd/vss pads are tied to the core PDN ring by met3 stubs plus via
  stacks added in the floorplan script (vias only where the ring runs).
- OpenROAD's resizer excludes the `probe`, `probec` and `lpflow` cells.
- LVS compares the core logic; pads and the SRAM are black boxes, and supplies
  are stripped. Power connectivity is covered by the geometry check and
  `check_power_connectivity.tcl`.


## Licensing and third-party material

There is no repository-wide licence file yet. Parts that carry their own terms:

- `01_rtl/picorv32_top.v` includes the PicoRV32 core, copyright Claire Xenia Wolf,
  ISC licence (the notice is kept at the top of the file), plus the Lambda
  project's `la_*` pad-ring and memory wrappers (MIT).
- `04_synthesis/lib/*.lib` and `01_rtl/models/sky130_sram_*.v` come from the
  SkyWater SKY130 PDK and the OpenRAM macro (Apache-2.0).
- Many flow files carry the "Copyright (c) 2026 Ignytion IO" header they had in
  the APB flow they were derived from.
