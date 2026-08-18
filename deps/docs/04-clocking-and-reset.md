# Clocking and reset

## The domains

All shell clocks derive from a single top-level `MMCME4_ADV` fed by the 100 MHz
board `sysclk`, plus the PCIe and GT reference clocks.

| Clock | Frequency | Source | Used by |
|---|---|---|---|
| `pcie_refclk` | 100 MHz | board `pcie_refclk_p/n` | QDMA GT |
| `dma_clk` | 250 MHz | QDMA `axi_aclk` output | top AXI-Lite crossbar, QDMA AXI master/slave |
| **`user_clk`** | **240 MHz** | top MMCM `CLKOUT0` | **the RP**, `user_block`, `bd_user`, all RP-facing MM/stream logic |
| `user_100m_clk` | 100 MHz | top MMCM `CLKOUT2` | the RP's `free_100m_clk` (BUFGCE-gated by `rpen`) |
| `cmac_axil_clk` | 100 MHz | top MMCM `CLKOUT1` | CMAC AXI-Lite, after an SLR-crossing register slice |
| `cmac_clk` | ~322 MHz | CMAC GT TXOUT | CMAC RX/TX streams, CDC'd to `user_clk` by `cmac_eth_cdc` |
| `icap_clk` | 125 MHz | `BUFGCE_DIV` from `dma_clk` | `axi_hwicap`, PR-control GPIO |

### `user_clk` is 240 MHz, not 200

The MMCM is `100 MHz × 12.0 ÷ 1 = 1.2 GHz` VCO, `CLKOUT0_DIVIDE_F = 5.0`, i.e.
**240 MHz** — a 4.167 ns period. That is the number your timing constraints,
your throughput arithmetic, and your post-route reports all use; the case
study's dominant failing clock is reported as `user_clk_m` at 240 MHz.

Several older comments and prose in the shell sources still say "200 MHz",
including the `CLKOUT0` inline comment in `shell_top.v` itself, which reads
`1.2GHz / 6.0 = 200MHz` next to a divider of `5.000`. **Those are stale.**
Derive the frequency from the MMCM parameters or read it off a timing report;
do not trust a comment.

Running your logic slower than 240 MHz is allowed and needs **no shell
resynthesis and no user-side CDC** — the shell does not care what fraction of
the clock you actually use. Running faster is not available without rebuilding
the shell.

## Reset

Resets cascade `pcie_rstn → dma_rstn → user_rstn`. The RP sees `RST_N`,
synchronous to `CLK`, active low.

> **`user_rstn` is driven through an explicit `BUFG` in `shell_top.v`. Do not
> remove it.** Without it Vivado auto-inserts a `*_bufg_place` cell inside the
> XPM CDC during `place_design`, which broke the abstract-shell flow with
> `Vivado 12-7950`. The explicit BUFG keeps fanout = 1 on the XPM and allows
> per-board placement constraints. This is shell-side, but it is the kind of
> thing an ECO is tempted to "clean up".

The RP also gets asynchronous resets from the host: `rp_reset` (soft reset of
your logic) and `rp_detach` (disconnect from the static shell). See
[03](03-address-map-and-control.md).

## Adding a clock inside the RP

You get one domain. If you need another — the common case is HBM, whose AXI side
runs at 450 MHz — you generate it yourself from `free_100m_clk`.

**Use a Clocking Wizard IP cell, not hand-written `MMCME4_ADV` RTL.**

Under the packaged-shell flow, `rp_blk.v` is fixed and shell-supplied, so it
cannot host app RTL; the generator has to live in your block design. And a
`create_bd_cell -type module` RTL cell brings a subtle, expensive failure mode
with it: its inferred pins default to `TYPE=undef` with no `FREQ_HZ`, `TYPE` is
read-only after creation, and `set_property CONFIG.FREQ_HZ` on an undef pin
**silently no-ops**. The symptom surfaces several hops away as
`ERROR: [BD 41-237] Bus Interface property FREQ_HZ does not match between
/some/ip and /another/ip`, naming two IPs you never touched. Catalog IP has its
pins pre-typed and the problem does not exist.

The validated configuration is in
[`../examples/bd/hbm-subsystem.tcl`](../examples/bd/hbm-subsystem.tcl)
(`vnd_hbm_clocks`): 100 MHz reference, 100 MHz APB, 450 MHz AXI, all
`CLKOUTn_DRIVES BUFG`, `USE_LOCKED` and `USE_RESET` on, `RESET_TYPE ACTIVE_LOW`,
plus two `proc_sys_reset` cells gating the AXI and APB resets on `locked`.

### The MMCM site, and the clock-route exception

On au50 the RP may use exactly **one** MMCM site, `MMCM_X0Y0` — `MMCM_X0Y1` and
`MMCM_X0Y4` in the same CMT column are carved out by the static shell. It sits
at the bottom of SLR0, next to the HBM, which is where you want it anyway.

The Clocking Wizard's underlying primitive is named `mmcme4_adv_inst` inside its
generated hierarchy (standard, stable clk_wiz naming), so a `-hierarchical` leaf
match reaches it in both the OOC synthesis context and after the link:

```tcl
set_property LOC MMCM_X0Y0 [get_cells -hierarchical mmcme4_adv_inst]
```

That LOC alone is not enough. `free_100m_clk` is gated by a static BUFGCE that
the abstract shell locks in **SLR1**, while `MMCM_X0Y0` is in **SLR0** — the
BUFGCE→MMCM cascade cannot be vertically adjacent, and placement fails with
`Place 30-718`. The fix is a routing exception applied *after* the link, since
the net only exists once the RP is folded into `shell_top`:

```tcl
set_property CLOCK_DEDICATED_ROUTE BACKBONE \
    [get_nets user_block_inst/rp_100m_clk]
```

See [`../examples/tcl/pr-link-post.tcl`](../examples/tcl/pr-link-post.tcl).

### Consequences of the `rpen` gate

`free_100m_clk` is BUFGCE-gated by `rpen` upstream. On `rp_detach` the MMCM
loses its input and unlocks. That is expected and harmless: partial
reconfiguration destroys RP state anyway, and the post-load re-init sequence
handles it. Do not design around trying to keep an RP-internal clock alive
across a detach.

## Crossing domains

- **Into and out of the RP boundary: don't.** All four AXI-Stream ports and all
  AXI-MM/Lite ports are already on `user_clk`. The shell has done the CDC.
- **Inside the RP:** use `axi_clock_converter` for AXI, and standard XPM CDC
  primitives otherwise. The HBM path in
  [`../examples/bd/hbm-subsystem.tcl`](../examples/bd/hbm-subsystem.tcl) shows
  the canonical arrangement — cross the clock *before* changing the data width,
  and put a register slice on the far side of the CDC (that `slice_b` stage is
  load-bearing: without it TNS blew up to about −880 ns).
