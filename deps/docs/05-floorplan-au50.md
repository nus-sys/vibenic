# Floorplan — Alveo U50

Read this before designing, instantiating, or constraining anything physical.
The general method (and the rules about which pblock kind to reach for) is in
[`../prompts/05-floorplanning-and-timing.md`](../prompts/05-floorplanning-and-timing.md);
this document is the concrete au50 map.

## The device

au50 is a **VU35P**: a clock-region grid of **X0–X7 × Y0–Y7** (8 × 8), split
into **two SLRs**.

```
        X0   X1   X2   X3   X4   X5   X6   X7
  Y7   [------- pb_cmac (static) -------]  QDMA QDMA  ┐
  Y6                                       QDMA QDMA  │ SLR1
  Y5                                       QDMA QDMA  │ (Y4–Y7)
  Y4                                       QDMA QDMA  ┘
  ── SLR boundary — pipeline anything crossing here ──
  Y3                                       QDMA QDMA  ┐
  Y2                                       QDMA QDMA  │ SLR0
  Y1                                            QDMA  │ (Y0–Y3)
  Y0   [============ HBM along the bottom edge =====]  ┘
```

- **SLR0 = rows Y0–Y3**, carries the HBM at the bottom.
- **SLR1 = rows Y4–Y7**.
- The boundary to pipeline across is **Y3 ↔ Y4**.

The static shell occupies **19 of the 64 clock regions**, pinned to the chip
edge; the remaining 45 are yours as one contiguous partition — including every
HBM-facing region.

Floorplan **only at clock-region granularity**, and only for the *major* IPs.
Pin rough rectangles and let the placer do fine placement inside them.
Over-constraining hurts more than it helps.

## What a clock region actually holds

Clock-region granularity is only usable if you know what a region *contains* —
otherwise "put the hash table in `X3Y2`" is a guess about whether the BRAM fits.
The numbers below come from the device database, not from a build; regenerate
them with [`../examples/scripts/device-grid.tcl`](../examples/scripts/device-grid.tcl).

The fabric is column-structured: **every clock region in a given CR column holds
the same resources**, on all three boards ([06](06-board-deltas.md) — au280 and
au55c are VU37P, which is the same column architecture with a third SLR). So one
table describes the whole grid.

| CR col | SLICE X range | SLICE | LUT | FF | BRAM36 | URAM | DSP48E2 | Also in this column |
|---|---|---|---|---|---|---|---|---|
| **X0** | `X0`–`X30`    | 1860 | 14880 | 29760 | 24 | 0  | 96  | CMAC, PCIe, left GTY quad, HBM AXI |
| **X1** | `X31`–`X56`   | 1560 | 12480 | 24960 | 24 | 16 | 96  | |
| **X2** | `X57`–`X94`   | 2280 | 18240 | 36480 | 36 | 0  | 120 | widest column, most BRAM, no URAM |
| **X3** | `X95`–`X116`  | 1320 | 10560 | 21120 | 12 | 16 | 72  | narrowest column |
| **X4** | `X117`–`X145` | 1740 | 13920 | 27840 | 24 | 16 | 96  | **the CMT column** — MMCM + 2 PLL + 24 BUFGCE per region |
| **X5** | `X146`–`X175` | 1800 | 14400 | 28800 | 12 | 16 | 120 | |
| **X6** | `X176`–`X205` | 1800 | 14400 | 28800 | 12 | 16 | 120 | |
| **X7** | `X206`–`X232` | 1620 | 12960 | 25920 | 24 | 0  | 48  | right GTY quads, PCIe, `CONFIG_SITE`, SYSMON |

Two corrections apply to that table, and both are worth remembering because they
bite exactly where the interesting logic goes:

- **SLR-boundary rows and the top row lose 120 SLICE per column** (LAGUNA and the
  die edge displace CLBs). On au50 that is rows **Y3, Y4 and Y7**: `X2Y3` has
  2160 SLICE, not 2280. BRAM/URAM/DSP are unaffected.
- **Row Y0 has 25 % fewer DSP** — the HBM interface row. `X2Y0` has 90 DSP, not
  120; `X0Y0` has 72, not 96. SLICE/BRAM/URAM are unaffected.

Converting a clock region to a SLICE rectangle (what `HD.PARTPIN_RANGE` and
nested guard pblocks want): row `Yn` spans `SLICE_*Y(60n)` to `SLICE_*Y(60n+59)`.
So `CLOCKREGION_X5Y4` = `SLICE_X146Y240:SLICE_X175Y299`.

### Where the special resources are

- **URAM lives only in columns X1, X3, X4, X5, X6** — 16 URAM288 per region.
  X0, X2 and X7 have none. A URAM-heavy block pinned to `X0Y*` or `X2Y*` will
  either fail placement or get scattered across the die to reach URAM.
- **BRAM is densest in X2** (36/region) and thinnest in X3, X5, X6 (12/region).
  X2 is the column to reach for when a block is BRAM-bound; note it is also the
  column with no URAM, so a mixed BRAM+URAM block wants X1 or X4 next to it.
- **DSP is densest in X2, X5, X6** (120/region) and sparse in X7 (48/region).
- **The only CMT column is X4.** All MMCM/PLL/BUFGCE sites are there, one MMCM +
  two PLLs + 24 BUFGCEs per region, and the site names run `MMCM_X0Y0`…`MMCM_X0Y7`
  bottom to top — `MMCM_X0Yn` is in `CLOCKREGION_X4Yn`. That mapping is the one
  people get wrong: the `X0` in the site name is the *CMT column index*, not a
  clock-region column. See [the clock column](#the-clock-column) below.
- **LAGUNA** exists only in the two CR rows either side of an SLR boundary (au50:
  Y3 and Y4). See the next subsection — it is the resource that decides whether
  an SLR-spanning guard pblock routes.

### LAGUNA: the SLR-crossing budget, and how to name it

Plain fabric nets cross an SLR **only** through LAGUNA SLLs. A `REG=10` register
slice therefore needs LAGUNA sites *inside* whatever pblock holds it, and if the
pblock is a SLICE rectangle it contains none — you must add the LAGUNA range
explicitly. Getting that wrong is the `Route 35-4445` failure described at the
end of this document.

Each boundary-row clock region holds 480 LAGUNA sites in **4 LAGUNA site
columns**. A column spans both rows of the boundary, so it is 240 sites ×
6 TX registers = **1440 crossing registers per LAGUNA column**, i.e. **5760 per
clock-region column**. One 512-bit AXI4 `REG=10` crossing consumes roughly 700,
so about two per LAGUNA column.

The site coordinates do not follow the clock-region grid, so here is the map:

| CR col | LAGUNA site columns | which sit between SLICE columns |
|---|---|---|
| **X0** | `LAGUNA_X0`–`X3`   | `X7`/`X8` and `X18`/`X19` |
| **X1** | `LAGUNA_X4`–`X7`   | `X36`/`X37` and `X49`/`X50` |
| **X2** | `LAGUNA_X8`–`X11`  | `X62`/`X63` and `X84`/`X85` |
| **X3** | `LAGUNA_X12`–`X15` | `X96`/`X97` and `X110`/`X111` |
| **X4** | `LAGUNA_X16`–`X19` | `X123`/`X124` and `X138`/`X139` |
| **X5** | `LAGUNA_X20`–`X23` | `X151`/`X152` and `X163`/`X164` |
| **X6** | `LAGUNA_X24`–`X27` | `X181`/`X182` and `X193`/`X194` |
| **X7** | `LAGUNA_X28`–`X31` | `X213`/`X214` and `X224`/`X225` |

LAGUNA **Y** coordinates number per boundary, not per die: the *k*-th SLR
boundary counting from the bottom occupies `Y(240k)`–`Y(240k+239)`. au50 has one
boundary, so all its LAGUNA is `Y0`–`Y239`. The 3-SLR boards have two: `Y0`–`Y239`
is the SLR0/SLR1 crossing and `Y240`–`Y479` the SLR1/SLR2 one
([06](06-board-deltas.md)).

Read the two together to size a guard: a strip covering SLICE columns
`X104`–`X116` lies in CR column X3, so its usable SLLs are `LAGUNA_X14Y0:X15Y239`
— 1440 registers, enough for two 512-bit crossings. Needing three means widening
the strip left to pick up `LAGUNA_X12`/`X13`. That is not hypothetical: it is
what au280's guard had to do, and the run history is in
[06](06-board-deltas.md#au280-slr-crossing-guards).

### The RP's actual budget

`pb_user`'s 45 clock regions, totalled:

| | `pb_user` | whole VU35P | share |
|---|---|---|---|
| SLICE | 77 700 | 108 960 | 71 % |
| LUT | 621 600 | 871 680 | 71 % |
| FF | 1 243 200 | 1 743 360 | 71 % |
| BRAM36 | 972 | 1344 | 72 % |
| URAM | 480 | 640 | 75 % |
| DSP48E2 | 4296 | 5952 | 72 % |

And the three zones this document recommends below:

| Zone | CRs | SLICE | BRAM36 | URAM | DSP |
|---|---|---|---|---|---|
| HBM `CLOCKREGION_X0Y0:X3Y1` | 8 | 14 040 | 192 | 64 | 672 |
| DMA `CLOCKREGION_X5Y4:X5Y6` | 3 | 5 280 | 36 | 48 | 360 |
| NIC `CLOCKREGION_X0Y5:X4Y6` | 10 | 17 520 | 240 | 96 | 960 |

Use these to *shape* a pblock, not to size one to the millimetre: if a module
needs 300 BRAM36 it cannot live in the DMA zone, and if it needs URAM it cannot
live in a zone made only of X0 and X2. Beyond that, keep the rectangles generous —
the warning about `pb_user` congestion above applies to every pblock inside it.

## The RP pblock

```
pb_user = CLOCKREGION_X0Y0:X5Y6  +  X6Y0:X6Y1  +  X7Y0
```

The RP owns the lower-left bulk of the die. Columns X6–X7 above Y1 are static
QDMA and off-limits.

> **`pb_user` congestion never means resource shortage.** The pblock is
> deliberately huge and the RP inside it is small. If you see
> `Constraints 18-1067` PPLOC congestion, or the placer struggling, the cause is
> the static floorplan or the partition-pin geometry squeezing the RP into an
> awkward shape — not capacity. Do not respond by shrinking anything.

## Interface anchors and partition pins

| Interface | Static anchor | RP partition-pin zone | Put your logic in |
|---|---|---|---|
| NIC in (`s_axis_*`) | `pb_cmac` = CR `X0Y7:X5Y7` | CR `X1Y6` | `CLOCKREGION_X0Y5:X4Y6` |
| NIC out (`m_axis_*`) | `pb_cmac` = CR `X0Y7:X5Y7` | CR `X4Y6` | `CLOCKREGION_X0Y5:X4Y6` |
| DMA / AXI-MM + AXI-L | `pb_qdma_aximst` = CR `X6Y4:X6Y6` | CR `X5Y4:X5Y6` | `CLOCKREGION_X5Y4:X5Y6` |
| HBM | bottom edge row Y0 (X0–X7); LEFT-stack MC0–3 bottom-left | n/a (internal) | `CLOCKREGION_X0Y0:X3Y1` |

Note the AXIS partition pins are **two disjoint columns three CR-columns apart**
— in at `X1Y6`, out at `X4Y6` — so a NIC block pinned to a single narrow
rectangle will stretch to reach one of them. That is why the recommended NIC zone
is the wide `X0Y5:X4Y6` and not something tighter. The AXIS-out region also lands
in the CMT column X4, alongside `MMCM_X0Y6`.

The three partition-pin regions, as exact SLICE rectangles (with the clock
regions they fall in, since that is the granularity you constrain at):

| Region | Partpins | Clock regions | Guard pblock rectangle |
|---|---|---|---|
| AXI-MM (`s_axi_dma`, `s_axi_pcie`, `s_axil`, `m_axibr`) | `SLICE_X162Y240:X175Y389` | `X5Y4:X5Y6` (right edge of X5) | `SLICE_X160Y180:X175Y389` |
| AXIS-in (`s_axis_rph2c`, `s_axis_ethrx0`) | `SLICE_X42Y375:X51Y409` | `X1Y6` | `SLICE_X41Y360:X52Y418` |
| AXIS-out (`m_axis_rpout0/1`) | `SLICE_X129Y375:X140Y409` | `X4Y6` | `SLICE_X128Y360:X141Y418` |

The AXI-MM guard rectangle reaches down to `Y180`, i.e. into CR row `Y3` — it
spans the SLR0/SLR1 boundary on purpose, and legally: `X5Y3`/`X5Y4` carry
4 LAGUNA columns = 5760 crossing registers, ample for the `REG=10` slices it
holds. The two AXIS guards sit entirely inside CR row `Y6` in SLR1 and cross
nothing.

Trust these ranges, not a sibling design's comment header — several of those are
stale. The authoritative source is the shell's `boards/au50/base.xdc`, and the
ranges above are what the validated builds actually used.

## The clock column

au50 has exactly **one CMT column, at clock-region column X4**, with one MMCM,
two PLLs and 24 BUFGCEs per region. The MMCM sites are named `MMCM_X0Y0`…
`MMCM_X0Y7` bottom to top and map one-to-one onto the rows: **`MMCM_X0Yn` is in
`CLOCKREGION_X4Yn`.** The `X0` is the CMT column index, not a clock-region
column — reading it as `CLOCKREGION_X0*` is a recurring mistake.

`MMCM_X0Y0` (in `CLOCKREGION_X4Y0`, at the bottom of SLR0 next to the HBM) is
the **only** MMCM site the RP may use. `MMCM_X0Y1` (`X4Y1`) and `MMCM_X0Y4`
(`X4Y4`) are carved out by the static shell for sysclk, `pcie_rstn`, and
`hbm_cattrip` — `base.xdc` trims `SLICE_X117Y60:X119Y119` and
`SLICE_X117Y240:X119Y299` out of `pb_user` to do it, which is why those two
regions are 3 SLICE columns short of the table above. See
[04](04-clocking-and-reset.md) for the LOC and the `CLOCK_DEDICATED_ROUTE
BACKBONE` exception that must go with it.

## Suggested pins for an HBM + DMA + NIC design

Major IPs only; leave everything else to the placer.

| Block group | Rough pblock |
|---|---|
| HBM IP + per-channel `rama` / dwidth-conv / clk-conv (450 MHz side) | `CLOCKREGION_X0Y0:X3Y1` |
| DMA SmartConnect + DMA-facing register slices | `CLOCKREGION_X5Y4:X5Y6` |
| NIC / AXIS logic | `CLOCKREGION_X0Y5:X4Y6` |
| AXI-Lite control (APB bridge, GPIO, AXI-L SmartConnect) | unpinned, or HBM-side `X0Y1:X2Y2` |

The DMA→HBM path runs from SLR1 (Y4–Y6) down to SLR0 row Y0, crossing Y3/Y4.
In the per-channel `path_NN` chain, keep the entry register slice in the DMA
zone, let the clock converter straddle ~Y2–Y3, and put the width converter and
`rama` in the HBM zone. The entry slice doubles as the SLR-crossing pipeline —
that is the one place `REG=10` (LAGUNA) belongs.

## The boundary guard-slice ring

The proven lever for closing RP↔static timing on this shell:

1. Put an RP-side register slice on the partition-pin interfaces, right at the
   pin. Guarding all eight is the conservative default and what
   [`../examples/bd/boundary-guard-ring.tcl`](../examples/bd/boundary-guard-ring.tcl)
   does; the seven 512-bit crossings are where the width makes the pin path
   expensive. Dropping one you do not drive is legitimate — flow_reduce omits
   the `m_axibr` slice and still closes its boundary paths — but base that on a
   post-route report, not on convenience.
2. Pin each slice into an `EXCLUDE_PLACEMENT` guard pblock hugging its partpin
   column. au50 has three disjoint regions, so three pblocks. Constraints:
   [`../examples/xdc/guard-pblocks-au50.xdc`](../examples/xdc/guard-pblocks-au50.xdc).

`EXCLUDE_PLACEMENT` reserves each strip for only its boundary slices and pushes
the rest of the RP off the congested edge. This is one of the few places
`EXCLUDE_PLACEMENT` is the right tool — the strips are tiny and hold only their
own cells by design.

Mechanics that each cost a failed build to learn:

- **`SCOPED_TO_REF rp_blk` + `used_in_synthesis false`.** `bd_user` has
  identically-named static-side register slices; an unscoped
  `get_cells -hierarchical` match hits both.
- **The guard XDC is evaluated twice** — captured into the RP checkpoint, then
  re-applied at the abstract-shell link. That produces one `Vivado 12-795`
  "pblock already exists" critical *per pblock*. Keep the file idempotent (no
  `-remove`, no statement whose second application diverges) and treat the
  12-795 count as a checksum.
- **`SNAPPING_MODE OFF` on any pblock nested inside a CLOCKREGION-defined
  parent.** With default snapping the nested SLICE range collapses to empty
  (`HDPR-14` / `HDPR-18`).
- **Boundary slice configs must match `rp_blk.v` exactly** — see
  [02](02-rp-boundary-contract.md). A `RUN=0` pass does not catch a mismatch
  because nothing is synthesised.
- **A guard pblock may span the SLR boundary only if the crossing is real and
  resourced.** One LAGUNA column is 240 sites × 6 = 1440 registers, and one
  512-bit AXI4 `REG=10` crossing eats about 700. A saturated column silently
  spills the next slice into a CLB straddle whose control nets need impossible
  fabric SLR crossings; `route_design` then dies in *initial* routing
  (`Route 35-4445`, unroutable `aresetn`/handshake nets) and no directive saves
  it. Without the LAGUNA budget, split the guard per SLR instead.

## Beyond the boundary: internal congestion

The guard ring fixes RP↔static paths. A different failure is a chunky module
getting scattered by the placer and detouring through a congested region.
Diagnose before constraining — [`../examples/scripts/congestion-report.tcl`](../examples/scripts/congestion-report.tcl)
prints the logic-vs-route split and names the congested cells. The decision rule
(soft pblock vs `EXCLUDE_PLACEMENT`, and why `EXCLUDE_PLACEMENT` is usually
wrong for a connected module) is in
[`../prompts/05-floorplanning-and-timing.md`](../prompts/05-floorplanning-and-timing.md).

A worked example, with the full reasoning preserved in its comments, is
[`../examples/xdc/floorplan-flow-reduce-au50.xdc`](../examples/xdc/floorplan-flow-reduce-au50.xdc).

## Known status of the reference designs on this floorplan

Reported plainly, because the numbers matter more than the story:

| Design | Post-route result |
|---|---|
| `au50_lb_guard` (loopback + guard ring) | closes timing |
| `hbm_loopback` (HBM + DMA + loopback) | closes timing — WNS +0.020 ns, TNS 0 |
| **case-study NF** (`mkVectorAvgNF`) | **misses timing** — WNS −2.423 ns, TNS −9107 ns, 7826 failing endpoints (hold clean) |

The case study's failure is **not** a boundary or floorplan defect: the guard
ring and pblocks are in place and correct, and the worst paths lie *inside* the
vendored cuckoo hash-table IP's victim/delmask logic — 12–14 logic levels,
~6.5 ns data-path delay, which misses even at 200 MHz. That IP was never
pipelined for this frequency. Closing it requires NF/IP work (pipelining the
victim cache, or giving the flow table its own slower domain with a CDC), not
more constraints. A secondary 450 MHz `hbm_axiclk` violation (−0.187 ns) in the
512→256 downsizer is route-delay dominated, i.e. congestion from the large NF
crowding the die — the identical downsizer closes in `hbm_loopback` with a
near-empty RP.
