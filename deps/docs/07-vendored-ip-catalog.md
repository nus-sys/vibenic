# Vendored IP catalog

Every vendor IP the validated designs instantiate, with the configuration that
is known to work and the failure mode that is known to bite. Prefer catalog IP
over hand-rolled RTL for anything the catalog already does — it is less code, it
arrives with correct interface metadata, and a whole class of block-design bugs
does not exist for it (see [`../prompts/03-vivado-bd-clamp.md`](../prompts/03-vivado-bd-clamp.md)).

Runnable instantiations:
[`../examples/bd/hbm-subsystem.tcl`](../examples/bd/hbm-subsystem.tcl),
[`../examples/bd/boundary-guard-ring.tcl`](../examples/bd/boundary-guard-ring.tcl),
and the two complete designs in [`../examples/bd/`](../examples/bd/).

---

## `xilinx.com:ip:hbm:1.0` — HBM controller

**Not shell-provided.** The RP boundary has no HBM ports; an app that wants HBM
instantiates the controller inside its own `rp_user` block design. The price is
an HBM controller re-implementation on every partial build (it dominates synth
time) and ~100 ms of init/scrub after every partial bitstream load before
traffic may flow.

Known-good au50 configuration (one stack, LEFT, 4 GB, MCs 0–2, ECC bypass):

```tcl
CONFIG.USER_HBM_DENSITY            {4GB}
CONFIG.USER_HBM_STACK              {1}
CONFIG.USER_SINGLE_STACK_SELECTION {LEFT}
CONFIG.USER_AUTO_POPULATE          {yes}
CONFIG.USER_DIS_REF_CLK_BUFG       {TRUE}   ;# ref clock is already BUFG'd by clk_wiz
CONFIG.USER_APB_EN                 {true}
CONFIG.USER_HBM_REF_CLK_0          {100}
CONFIG.USER_AXI_CLK_FREQ           {450}
CONFIG.USER_AXI_INPUT_CLK_FREQ     {450}
CONFIG.USER_SWITCH_ENABLE_00       {FALSE}  ;# lateral switch OFF
CONFIG.USER_MC_ENABLE_NN / USER_PHY_ENABLE_NN  per enabled MC
CONFIG.USER_MCn_ECC_BYPASS         {true}
```

**Addressing.** With the lateral switch OFF, each used *even* SAXI commands its
whole memory controller and the IP fixes `SAXI_NN`'s window at `NN × PC` bytes.
Pseudo-channel `PC` = **256 MB on 8 GB parts** (au50, au280), **512 MB on
16 GB** (au55c). Because the host preload path and the RP's read masters use the
same fixed offsets, an offset stored in a lookup table is an HBM-absolute byte
address for both — a symmetric contract worth preserving in your own designs.

Two channel-selection conventions exist and both are defensible: every-other
SAXI (00, 02, 04, …), one per MC, maximises per-channel bandwidth; sequential
(00, 01, 02, …) maximises channel count but makes two SAXIs of one MC contend.
The reference designs use every-other.

> **Trap: unused SAXI ports stall the controller.** An enabled MC's second
> pseudo-channel still needs a legally idle AXI3 master. Null-tie them (see
> `xlconstant` below). This costs one hour the first time you meet it.

---

## `xilinx.com:ip:clk_wiz:6.0` — Clocking Wizard

The way to make a clock inside the RP. Full configuration and the two
constraints that must accompany it (`LOC MMCM_X0Y0`,
`CLOCK_DEDICATED_ROUTE BACKBONE`) are in [04](04-clocking-and-reset.md).

> **Use this instead of a hand-written `MMCME4_ADV` module cell.** A
> `create_bd_cell -type module` RTL cell gets pins with `TYPE=undef` and no
> `FREQ_HZ`; `TYPE` is read-only after creation and `set_property
> CONFIG.FREQ_HZ` on an undef pin **silently no-ops**. The failure surfaces
> later as `BD 41-237` naming two IPs you never touched. clk_wiz's pins come
> pre-typed with `FREQ_HZ` already set from `CLKOUTn_REQUESTED_OUT_FREQ`.

The underlying primitive is still LOC-able: it is named `mmcme4_adv_inst` in the
generated hierarchy, matched with `get_cells -hierarchical`.

---

## `xilinx.com:ip:axi_register_slice:2.1` / `axis_register_slice:1.1`

The most-used IP here, and the one with the sharpest trap.

**REG mode selection:**

| Path | Setting | Why |
|---|---|---|
| Real SLR crossing, AXI-MM | `REG_AR/AW/B/R/W = 10` (or `15` + `USE_AUTOPIPELINING`) | Forces LAGUNA, which is what you want across an SLR. |
| Real SLR crossing, AXI-Stream | `REG_CONFIG = 12` | SLR-crossing mode. |
| Everything else, AXI-MM | `REG_AR/AW/B = 7`, `REG_R/W = 1` or `7` | Light forward/reverse pipelining, no LAGUNA. |
| Boundary guard, AXI-Stream | `REG_CONFIG = 8` | Full register. |

> **`REG` 15 and 10 mandate LAGUNA primitives. Using them where no SLR boundary
> is crossed forces a hop that makes timing *worse*.** Before adding or copying
> a slice config, check whether the producer and consumer pblocks actually
> straddle an SLR. If they do not, use the light config. This exact mistake —
> copying au280's heavy config onto every new slice — was caught in review.

**LAGUNA budget** when you do cross: one column = 240 sites × 6 = 1440
registers; one 512-bit AXI4 `REG=10` crossing consumes ~700. Oversubscribe and
`route_design` dies in initial routing with `Route 35-4445`.

**Boundary slices must match the `rp_blk.v` signal set exactly** — `HAS_REGION 0`
and `SUPPORTS_NARROW_BURST 1` on the AXI-MM ports, `HAS_PROT 0` and
`HAS_WSTRB 0` on `s_axil`. A mismatch breaks the abstract-shell link, and
`RUN=0` does not catch it because nothing is synthesised. Validated configs:
[`../examples/bd/boundary-guard-ring.tcl`](../examples/bd/boundary-guard-ring.tcl).

---

## `xilinx.com:ip:axi_clock_converter:2.1`

Asynchronous AXI CDC. In the HBM path it crosses `user_clk` → `hbm_axiclk`.
Cross the clock **before** changing the data width, and put a register slice on
the far side: in `hbm_loopback`'s bring-up, the `slice_b` (`REG=7`, 450 MHz)
stage between the CDC and the downsizer was load-bearing — without it TNS blew
up to about −880 ns.

## `xilinx.com:ip:axi_dwidth_converter:2.1`

512 → 256 for the HBM native width. Splits arbitrary AXI4 bursts correctly, so
you do not have to pre-chunk on its account (you *do* have to respect HBM's
8-beat burst limit on the master side — see [12](12-bsv-axi-transactions.md)).

```tcl
CONFIG.SI_DATA_WIDTH.VALUE_SRC USER   CONFIG.SI_DATA_WIDTH {512}
CONFIG.MI_DATA_WIDTH.VALUE_SRC USER   CONFIG.MI_DATA_WIDTH {256}
```

## `xilinx.com:ip:rama:1.1` — reordering memory adapter

Sits between the width converter and `hbm_0/SAXI_NN`, absorbing HBM access
reordering. Configuration: `G_MEM_INTERLEAVE_TYPE per_memory`,
`G_MEM_COUNT 32`, `G_REORDER_QUEUE_DEPTH 512`.

---

## `xilinx.com:ip:smartconnect:1.0`

AXI interconnect. Occupies roughly 1–2 clock regions — budget the area and place
it toward the side with the most or highest-bandwidth ports.

> **Never trade a SmartConnect's mode (High-performance ↔ Low-Area) or its
> outstanding-transaction depth for timing.** Relieve congestion by
> floorplanning. Shrinking infrastructure IP to buy slack costs throughput and
> usually does not close timing anyway.

## `xilinx.com:ip:axis_switch:1.1`

> **Trap, with a measured cost.** Setting `ARB_ON_TLAST 1` while leaving
> `ARB_ON_MAX_XFERS` at its IP default of **1** makes the switch re-arbitrate
> every **beat**, not every packet: internally `ARB_DONE = tlast_done |
> xfer_done`, and `MAX_XFERS=1` fires `xfer_done` on every transfer. Each
> re-arbitration costs a dead cycle → 2 cycles/beat.
>
> Measured on hardware: 60 Mpps for 128 B packets against 82.2 offered; xsim of
> the shipped RTL reproduced 4.00 vs 2.99 cycles/packet. It is also a
> *correctness* bug — per-beat round-robin interleaves concurrent packets from
> different slave interfaces to the same master, corrupting frames. It went
> unnoticed only because tests drove one source at a time.
>
> **Set `CONFIG.ARB_ON_MAX_XFERS {0}`.** One bubble per packet at TLAST remains
> inherent to a multi-slave master; packets ≥ 192 B reach line rate regardless.

## `xilinx.com:ip:axi_apb_bridge:3.0`, `axi_gpio:2.0`

Status and control plumbing. The HBM subsystem uses the APB bridge for
`hbm_0/SAPB_0` (16 KB aperture is enough for init-complete, status, ECC, and
temperature) and an `axi_gpio` to expose `{30'h0, cattrip, init_complete}` so
the host can poll HBM readiness without touching APB. See `vnd_hbm_status` in
[`../examples/bd/hbm-subsystem.tcl`](../examples/bd/hbm-subsystem.tcl).

## `xilinx.com:ip:xlconstant:1.1`, `xlconcat:2.1`

Tie-offs and status packing. The null-tie idiom is worth internalising:

> The constituent signals of a bundled AXI interface pin **are** individually
> reachable with `get_bd_pins`, but under a different name than you would
> guess: `hbm_0/SAXI_01`'s physical pins are `hbm_0/AXI_01_ARVALID`, **not**
> `SAXI_01_ARVALID`. The interface pin's own name is not the physical-pin
> prefix. Always enumerate with
> `get_bd_pins -of_objects [get_bd_intf_pins hbm_0/SAXI_01]` first. Doing this
> lets you tie off straight to the cell's pins with no external "null master"
> port at all. Emits benign `BD 41-1306` "connection overridden" warnings.

## `xilinx.com:ip:blk_mem_gen:8.4` + `axi_bram_ctrl`

A small BRAM scratchpad behind BAR4 gives the host a safe poke target that does
not contend with the DMA path. `hbm_loopback` and the case study both carry a
4 KB one.

## `xilinx.com:ip:axi_hwicap` (shell-side)

The partial bitstream loader, at AXI-Lite `0x20F000`. You do not instantiate it;
you drive it from the host. See [15](15-host-runtime-and-bringup.md).

---

## In-repo custom IP

### `AxisPacketRouterDual` — [`../libs/ip/pktrte_dual`](../libs/ip/pktrte_dual)

The header match-action router the shell uses for `pkt_route_N`, and which au50
and au55c's stock RPs also instantiate internally so an RP-range packet can have
its egress `tdest` rewritten for the wire. Packed variant
`mkAxisPacketRouterCmac27`: 512-bit, 2 downstream ports, 8 entries. Register
model in [03](03-address-map-and-control.md). Full throughput — it is not the
source of the `axis_switch` bubble above.

Instantiate it in your RP when you need programmable egress steering; `au280`
needs it for wire egress at all.

### `AxisDestTrans`

The inline `tdest` translator on the H2C stream. Shell-side only; register model
in [03](03-address-map-and-control.md).
