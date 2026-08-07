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
  Y7   [--------- pb_cmac (static) ---------]        ┐
  Y6                                    QDMA static  │ SLR1
  Y5                                    QDMA static  │ (Y4–Y7)
  Y4                                    QDMA static  ┘
  ── SLR boundary — pipeline anything crossing here ──
  Y3                                                 ┐
  Y2                                                 │ SLR0
  Y1                                                 │ (Y0–Y3)
  Y0   [============ HBM along the bottom edge =====] ┘
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
| NIC / AXI-Stream | `pb_cmac` = CR `X0Y7:X4Y7` | top of `pb_user`, CR ≈ `X1Y6` | `CLOCKREGION_X0Y5:X4Y6` |
| DMA / AXI-MM + AXI-L | `pb_qdma_aximst` = CR `X6Y4:X6Y6` | CR `X5Y4:X5Y6` | `CLOCKREGION_X5Y4:X5Y6` |
| HBM | bottom edge row Y0 (X0–X7); LEFT-stack MC0–3 bottom-left | n/a (internal) | `CLOCKREGION_X0Y0:X3Y1` |

The three partition-pin regions, as exact SLICE rectangles:

| Region | Partpins | Guard pblock rectangle |
|---|---|---|
| AXI-MM (`s_axi_dma`, `s_axi_pcie`, `s_axil`, `m_axibr`) | `SLICE_X162Y240:X175Y389` | `SLICE_X160Y180:X175Y389` |
| AXIS-in (`s_axis_rph2c`, `s_axis_ethrx0`) | `SLICE_X42Y375:X51Y409` | `SLICE_X41Y360:X52Y418` |
| AXIS-out (`m_axis_rpout0/1`) | `SLICE_X129Y375:X140Y409` | `SLICE_X128Y360:X141Y418` |

Trust these ranges, not a sibling design's comment header — several of those are
stale. The authoritative source is the shell's `boards/au50/base.xdc`, and the
ranges above are what the validated builds actually used.

## The clock column

`MMCM_X0Y0` is the **only** MMCM site in the X0 CMT column that the RP may use.
`MMCM_X0Y1` and `MMCM_X0Y4` are carved out by the static shell for sysclk,
`pcie_rstn`, and `hbm_cattrip`. See [04](04-clocking-and-reset.md) for the LOC
and the `CLOCK_DEDICATED_ROUTE BACKBONE` exception that must go with it.

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
