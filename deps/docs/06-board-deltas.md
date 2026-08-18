# Board deltas

Everything else in this corpus targets **Alveo U50**. The shell also supports
au280 and au55c; this document records what changes. The RP boundary contract,
the BAR2 address map, the `tdest` convention, and the build flow are identical
across all three.

| | au50 (primary) | au280 | au55c |
|---|---|---|---|
| Part | `xcu50-fsvh2104-2-e` | `xcu280-fsvh2892-2L-e` | `xcu55c-fsvh2892-2L-e` |
| CMAC / QSFP | 1 × 100 GbE | 2 × 100 GbE | 2 × 100 GbE |
| External memory | HBM, 8 GB (2 stacks) | DDR4 | HBM, 16 GB |
| **Vivado** | **2024.2** | **2023.2** | **2024.2** |
| SLRs | 2 | 3 | 3 |
| `board_config.vh` macros | none set | `HAS_2ND_QSFP`, `HAS_DDR` | `HAS_2ND_QSFP` |
| Partpin regions | 3 disjoint | 3 disjoint (2 AXI-MM ranges share slice columns) | 1 contiguous strip |
| `EXCLUDE_PLACEMENT` guards | 3 | 3 (AXI-MM guard joins both SLR ranges) | 1 |
| Non-exclusive placement guides | 0 | 2 (`pb_axi_xbar`, `pb_pktrte`) | 2 (`pb_axi_xbar`, `pb_pktrte`) |
| Boundary guard slices | 8 | 9 | 9 |

> **au280 must be built with Vivado 2023.2.** The part is absent from the 2024.2
> install. Sourcing the wrong `settings64.sh` fails late and confusingly.

## Clock-region maps

Both non-au50 boards are **VU37P**: a clock-region grid of **X0–X7 × Y0–Y11**
(8 × 12, 96 regions) in **three SLRs**. au50's VU35P is the same die minus SLR2.

| | au50 (VU35P) | au280 / au55c (VU37P) |
|---|---|---|
| Grid | X0–X7 × Y0–Y7 | X0–X7 × Y0–Y11 |
| SLR0 / SLR1 / SLR2 | Y0–Y3 / Y4–Y7 / — | Y0–Y3 / Y4–Y7 / Y8–Y11 |
| SLR boundaries | Y3↔Y4 | Y3↔Y4 **and** Y7↔Y8 |
| SLICE / LUT | 108 960 / 871 680 | 162 960 / 1 303 680 |
| BRAM36 / URAM / DSP | 1344 / 640 / 5952 | 2016 / 960 / 9024 |

**The per-column resource table in
[05 § What a clock region actually holds](05-floorplan-au50.md#what-a-clock-region-actually-holds)
applies unchanged to all three parts** — same column architecture, same SLICE X
ranges, same CMT column at X4, same URAM/BRAM/DSP distribution, same
`SLICE_*Y(60n)`–`Y(60n+59)` row arithmetic. Only the number of rows differs. The
two corrections there apply too, with more rows affected: the −120 SLICE
correction now hits rows **Y3, Y4, Y7, Y8 and Y11**, and LAGUNA exists in
**Y3, Y4, Y7 and Y8**.

Regenerate any of this with
[`../examples/scripts/device-grid.tcl`](../examples/scripts/device-grid.tcl)
(remember: 2023.2 for au280).

### au280 — static blocks and the RP

```
        X0   X1   X2   X3   X4   X5   X6   X7
  Y11  [-- pb_cmac --][--- pb_eth_sw ---]         ┐ SLR2
  Y10  [-- pb_cmac --][--- pb_eth_sw ---]         │ (Y8–Y11)
  Y9                                       slrx   │
  Y8                                       slrx   ┘
  ── SLR1/SLR2 boundary ──
  Y7                                       slrx   ┐
  Y6                       ddr1 [-- pb_dma --]    │ SLR1
  Y5                       ddr1 [-- pb_dma --]    │ (Y4–Y7)
  Y4                       ddr1 [-- pb_dma --]    ┘
  ── SLR0/SLR1 boundary ──
  Y3                       ddr0 [-- pb_dma --]    ┐
  Y2                       ddr0 [-- pb_dma --]    │ SLR0
  Y1                       ddr0 [-- pb_dma --]    │ (Y0–Y3)
  Y0                       ddr0                   ┘
```

| Pblock | Clock regions | CRs |
|---|---|---|
| `pb_user` (the RP) | `X0Y0:X3Y6` + `X0Y7:X6Y9` | 49 |
| `pb_dma` (`pb_qdma_pciebr` `X5Y1:X7Y3`, `pb_qdma_dma` `X5Y4:X7Y6`) | `X5Y1:X7Y6` | 18 |
| `pb_ddr0_s0ifc` | `X4Y0:X4Y3` | 4 |
| `pb_ddr1_s1ifc` | `X4Y4:X4Y6` | 3 |
| `pb_cmac` | `X0Y10:X2Y11` | 6 |
| `pb_eth_sw` | `X2Y10:X6Y11` | 10 |
| `pb_eth_slrx` | `X7Y7:X7Y9` | 3 |
| unclaimed | `X5Y0` `X6Y0` `X7Y0` `X7Y10` `X7Y11` | 5 |

`pb_user` budget: **83 580 SLICE / 668 640 LUT / 1104 BRAM36 / 464 URAM /
4752 DSP** — 51 % of the die, notably less than au50's 71 %, because the DDR4
interfaces and the two-CMAC Ethernet switch claim whole columns.

Its shape is the thing to plan around: a **tall narrow SLR0+SLR1 body** (columns
X0–X3, rows Y0–Y6) with a **wide SLR2 head** (columns X0–X6, rows Y7–Y9). The
DMA is in SLR1 at the far right of the body, the NIC is in SLR2 above the head.
That is why au280's register slices are configured heavier than au50's — see
[au280 register-slice policy](#au280-register-slice-policy).

| Interface | Partpins | Clock regions |
|---|---|---|
| AXI-MM SLR1 (`s_axi_dma`, `s_axil`, `ddrc1_axi`) | `SLICE_X107Y240:X116Y419` | `X3Y4:X3Y6` |
| AXI-MM SLR0 (`s_axi_pcie`, `m_axibr`, `ddrc0_axi`) | `SLICE_X107Y60:X116Y239` | `X3Y1:X3Y3` |
| AXIS-in (`s_axis_*`) | `SLICE_X77Y540:X92Y599` | `X2Y9` |
| AXIS-out (`m_axis_*`) | `SLICE_X129Y540:X140Y599` | `X4Y9` |

The two AXI-MM ranges are the *same slice columns* stacked vertically, one per
SLR — which is why they can be guarded as one strip, and why that strip crosses
the Y3/Y4 boundary. Its LAGUNA is `LAGUNA_X12`–`X15` (CR column X3), `Y0`–`Y239`.

Note the head row **Y9 has no LAGUNA** but sits directly under the static SLR2
Ethernet blocks in Y10–Y11: RP→CMAC traffic crosses the Y7/Y8 boundary *inside*
`pb_user` (rows Y7→Y8), not at the partition pins.

### au55c — static blocks and the RP

au55c gives the RP far more of the die than au280 does — 72 of 96 regions,
including all of SLR2 and the whole bottom row.

```
        X0   X1   X2   X3   X4   X5   X6   X7
  Y11                                             ┐ SLR2
  Y10                                             │ (Y8–Y11)
  Y9                                              │  all RP
  Y8                                              ┘
  ── SLR1/SLR2 boundary ──
  Y7   [pb_cmac]                                  ┐
  Y6   [pb_cmac]          [------ pb_dma ------]  │ SLR1
  Y5   [pb_cmac]          [------ pb_dma ------]  │ (Y4–Y7)
  Y4                      [------ pb_dma ------]  ┘
  ── SLR0/SLR1 boundary ──
  Y3                      [------ pb_dma ------]  ┐
  Y2                      [------ pb_dma ------]  │ SLR0
  Y1                      [------ pb_dma ------]  │ (Y0–Y3)
  Y0   [============ HBM along the bottom edge ==] ┘
```

| Pblock | Clock regions | CRs |
|---|---|---|
| `pb_user` (the RP) | `X0Y0:X7Y0` + `X0Y1:X4Y4` + `X2Y5:X4Y6` + `X2Y7:X7Y7` + `X0Y8:X7Y11` | 72 |
| `pb_dma` (flat — no child pblocks, unlike au50/au280) | `X5Y1:X7Y6` | 18 |
| `pb_cmac` | `X0Y5:X1Y7` | 6 |

`pb_user` budget: **122 340 SLICE / 978 720 LUT / 1584 BRAM36 / 720 URAM /
6720 DSP** — 75 % of the die, the most generous of the three boards. All of SLR2
(`X0Y8:X7Y11` = 54 000 SLICE, 672 BRAM36, 320 URAM, 3072 DSP) is unbroken RP, so
it is the natural home for a large NF; the HBM row Y0 is RP across the full
width.

| Interface | Partpins | Clock regions |
|---|---|---|
| AXI-MM SLR0 | `SLICE_X133Y120:X145Y239` | `X4Y2:X4Y3` |
| AXI-MM SLR1 | `SLICE_X133Y240:X145Y299` | `X4Y4` |
| AXIS-out (`m_axis_*`) | `SLICE_X135Y300:X145Y359` | `X4Y5` |
| AXIS-in (`s_axis_*`) | `SLICE_X135Y360:X145Y449` | `X4Y6:X4Y7` |

All four are **one continuous vertical strip on the right edge of CR column X4**,
`SLICE_X133Y120:X145Y449` = CR `X4Y2:X4Y7`. That is why au55c needs only one
guard pblock where au50 needs three. Two consequences:

- The strip crosses the **Y3/Y4** boundary, so its guard must include LAGUNA.
  Column X4's LAGUNA is `LAGUNA_X16`–`X19`, and only `X18`/`X19` (between
  `SLICE_X138` and `X139`) fall inside a strip starting at `SLICE_X128` — 1440
  registers. `Y0`–`Y239` is the SLR0/SLR1 crossing; `Y240`–`Y479` belongs to the
  Y7/Y8 crossing and is unreachable under `pb_user`'s `CONTAIN_ROUTING`.
- X4 is the **CMT column**, and `base.xdc` trims `SLICE_X117Y60:X119Y119`
  (`MMCM_X0Y1`, CR `X4Y1`) out of `pb_user` immediately below the strip. Do not
  extend a guard down into `X4Y1`.

## Dual-CMAC boards (au280, au55c)

The second QSFP adds, everywhere:

- A second packet router `pkt_route_1` at AXI-Lite `0x209000`; the static config
  SmartConnect goes to `NUM_MI=5` (au50 stays at 4).
- A third RP input stream, `s_axis_ethrx1`, guarded by `` `ifdef HAS_2ND_QSFP ``
  in `rp_blk.v` — same 9-signal shape as the other streams. Your BD must expose
  and tie it off even if unused.
- `tdest 0xFFF1` becomes live, selecting CMAC1 TX. On au50 it is unused.
- `nicsw` grows to 5 SI × 3 MI (au50: 4 SI × 2 MI).
- A ninth boundary guard slice, `axis_regsl_ethrx1`.

## au280 — DDR4 instead of HBM

`rp_blk.v` exposes `ddrc0_axi` and `ddrc1_axi` under `` `ifdef HAS_DDR ``: two
AXI4 masters, 33-bit address, 512-bit data, 4-bit ID, driven *out* of the RP to
the shell's `ddr4_wrapper`. Unlike HBM, DDR4 **is** shell-provided on au280 —
you do not instantiate a controller.

> One intentional, whitelisted width asymmetry: `user_block.sv` declares
> `ddrc0/1_axi_awaddr` and `araddr` as `[33:0]` while `rp_blk.v` declares
> `[32:0]`. `user_block` hardwires bit `[33]` to 0 and passes `[32:0]` down; the
> full 34-bit bus goes to `ddr4_wrapper`, which expects it. Do not "fix" this —
> `check_axi.py` whitelists it.

### au280 register-slice policy

au280 keeps heavier SLR-crossing slices than au50, because its NIC datapath
lives in SLR2 and the QDMA in SLR1:

| Slice | au50 | au280 |
|---|---|---|
| `axil_regsl_pktrte[1]` | `REG_R/W=7` | `REG_AR/AW/B/R/W=15` + `USE_AUTOPIPELINING=1` (real SLR1→SLR2 crossing) |
| `axis_regsl_h2c/c2h` | `REG_CONFIG=12` | `REG_CONFIG=12` (SLR-crossing) |
| `axil_regsl_dstran` | `REG_R/W=7` | `REG_AR/AW/B=7, REG_R/W=1` — **intra-pblock, no crossing** |

That last row is the point: `REG=15` and `REG=10` mandate LAGUNA instantiation.
On a path that does not actually cross an SLR they force a hop that makes timing
*worse*. Copying au280's heavy config onto every new slice is a mistake. See
[07](07-vendored-ip-catalog.md) § register slices.

### au280 and the wire-egress path

au280's **stock** RP cannot send an RP-range packet out the wire. Its egress is a
fixed `axis_switch` that splits by `tdest[15]` and has no `tdest` rewrite and no
config register, so an RP-range packet always returns to C2H. RX → RP → host
works fine; H2C → RP → wire does not.

The fix is a custom RP that swaps that switch for an `AxisPacketRouterDual`, the
way au50 and au55c's stock RPs do. The `au280_lb_guard` reference app is exactly
that, and with it loaded the wire-egress path works on au280 too. The IP is
vendored at [`../libs/ip/pktrte_dual`](../libs/ip/pktrte_dual).

### au280 SLR-crossing guards

au280's AXI-MM guard pblock joins both SLR0 and SLR1 partpin ranges into one
strip spanning the Y3/Y4 boundary, and that is only legal because the crossing is
real and resourced: `REG=10` slices plus enough in-pblock LAGUNA capacity, added
to the pblock **explicitly** — a SLICE-only rectangle contains no LAGUNA at all.
Budget it — one LAGUNA column is 240 sites × 6 = 1440 registers, and one 512-bit
AXI4 `REG=10` crossing consumes roughly 700. Two crossings per column is the
practical limit.

The au280 strip sits in CR column X3, whose LAGUNA is `LAGUNA_X12`–`X15`
(the column↔column map is in
[05 § LAGUNA](05-floorplan-au50.md#laguna-the-slr-crossing-budget-and-how-to-name-it)).
It carries **three** `REG=10` 512-bit crossings — `ddrc0` (687 registers),
`pcibr` (727) and `pcie` — about 2100 in total. With only `LAGUNA_X12`–`X13`
(1440) the first two saturated the column exactly and `pcie` got the 26
leftovers; it spilled into CLBs straddling the boundary and `route_design` died
in initial routing on three `aresetn` nets. Widening the strip left to reach
`LAGUNA_X12Y0:X15Y239` (2880) fixed it.

That failure mode is the one to recognise: oversubscribe the SLLs and the next
slice spills *silently* into a CLB straddle whose control nets cannot cross the
SLR through fabric. `route_design` then dies during *initial* routing with
`Route 35-4445` on `aresetn`/handshake nets, immune to directives. Nothing in
placement warns you first.

A cheaper and often more effective au280 trick: a **non-exclusive** guide pblock
pinning the AXI SmartConnect into the SLR between its clients took that board
from WNS −0.2 to positive at placement.

## au55c — HBM with a larger pseudo-channel

au55c is the dual-CMAC HBM board, 16 GB. The only arithmetic change from au50 is
the pseudo-channel size: **512 MB on 16 GB parts, 256 MB on 8 GB parts** (au50,
au280). Anywhere a channel base address is computed as `NN × PC`, that constant
moves. In [`../examples/bd/hbm-subsystem.tcl`](../examples/bd/hbm-subsystem.tcl)
it is the density/stack configuration plus your own offset arithmetic.

au55c's default RP block design already instantiates its own
`AxisPacketRouterDual_0` at RP AXI-MM `0x08200000`, so it has the same
wire-egress capability as au50.

Its floorplan and clock-primitive pinning for the RP stream expansion are
board-specific; the shell's `boards/au55c/base.xdc` and `pre_place.tcl` are
authoritative.

## Porting checklist

When moving a validated au50 app to another board:

1. Source the right Vivado (2023.2 for au280).
2. Add `s_axis_ethrx1` to the BD and tie it off, or use it. Add the ninth guard
   slice.
3. Re-derive the guard pblock rectangles from that board's `base.xdc` partpin
   ranges. They are not transferable — the maps above are the starting point,
   the `base.xdc` is the authority.
4. If the guard spans an SLR, budget LAGUNA before assuming it will route, and
   add the `LAGUNA_*` range to the pblock explicitly.
   [05 § LAGUNA](05-floorplan-au50.md#laguna-the-slr-crossing-budget-and-how-to-name-it)
   has the CR-column → LAGUNA-column map.
5. HBM: adjust the pseudo-channel size (au55c) or switch to the shell-provided
   DDR4 ports entirely (au280).
6. Re-check the register-slice REG modes against which paths actually cross an
   SLR on the new device.
