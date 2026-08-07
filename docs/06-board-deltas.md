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
| Guard pblocks | 3 (disjoint partpin regions) | 1 | 1 |
| Boundary guard slices | 8 | 9 | 9 |

> **au280 must be built with Vivado 2023.2.** The part is absent from the 2024.2
> install. Sourcing the wrong `settings64.sh` fails late and confusingly.

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

au280's single guard pblock spans an SLR boundary, and that is only legal
because the crossing is real and resourced: `REG=10` slices plus enough
in-pblock LAGUNA capacity. Budget it — one LAGUNA column is 240 sites × 6 = 1440
registers, and one 512-bit AXI4 `REG=10` crossing consumes roughly 700. Two
crossings per column is the practical limit. Oversubscribe and the next slice
silently spills into a CLB straddle whose control nets cannot cross the SLR
through fabric; `route_design` then dies during *initial* routing with
`Route 35-4445` on `aresetn`/handshake nets, immune to directives.

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
   ranges. They are not transferable.
4. If the guard spans an SLR, budget LAGUNA before assuming it will route.
5. HBM: adjust the pseudo-channel size (au55c) or switch to the shell-provided
   DDR4 ports entirely (au280).
6. Re-check the register-slice REG modes against which paths actually cross an
   SLR on the new device.
