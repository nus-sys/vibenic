# The RP boundary contract

**Authoritative source: [`../libs/shell/rp_blk.v`](../libs/shell/rp_blk.v).**
That file's port list *is* the contract. Every name, width, and direction must
match exactly or the abstract-shell link fails `pr_verify`. This document is a
readable rendering of it plus the semantics the Verilog cannot express — read
both.

The port list below is for **Alveo U50** with its shipped
[`board_config.au50.vh`](../libs/shell/board_config.au50.vh), where
`HAS_2ND_QSFP`, `HAS_DDR`, and `HAS_HBM` are all undefined. `rp_blk.v` also
carries `` `ifdef ``-guarded `s_axis_ethrx1` (second CMAC) and `ddrc0/1_axi`
(DDR4) sections that are **absent on au50** — see [06](06-board-deltas.md).

Under the packaged-shell flow you do not author `rp_blk.v`: it arrives in the
shell support package and your app supplies only the `rp_user` block design
behind it.

## Ports

### Clocks and reset

| Port | Dir | Width | Meaning |
|---|---|---|---|
| `CLK` | in | 1 | `user_clk` — the single RP clock domain. |
| `RST_N` | in | 1 | Synchronous active-low reset, `CLK` domain. |
| `free_100m_clk` | in | 1 | Free-running 100 MHz reference for an RP-internal MMCM. |

### JTAG debug bridge

| Port | Dir | Width |
|---|---|---|
| `S_BSCAN_{bscanid_en,capture,drck,reset,runtest,sel,shift,tck,tdi,tms,update}` | in | 1 each |
| `S_BSCAN_tdo` | out | 1 |

12 signals. Tie `S_BSCAN_tdo` low if you do not use a debug bridge; the rest may
be left unconnected inside the BD, but **the ports must exist**.

> Note a discrepancy in the shipped file, reported here rather than explained
> away: `rp_blk.v`'s own `rp_user_wrapper` instantiation has all twelve
> `S_BSCAN_*` connections commented out, so `S_BSCAN_tdo` — an output — is left
> undriven, which is what rule 1 below says not to do. The reference designs
> build and link this way, so something makes it benign for this group, but the
> corpus has not established what. Tie `S_BSCAN_tdo` low in your own BD: it
> costs nothing and does not depend on the answer.

### AXI4-Lite — host MMIO (`s_axil`)

Slave, 32-bit address, 32-bit data, 16 signals.

```
  in  [31:0] s_axil_awaddr    out s_axil_awready   in  s_axil_awvalid
  in  [31:0] s_axil_wdata     out s_axil_wready    in  s_axil_wvalid
  out [1:0]  s_axil_bresp     in  s_axil_bready    out s_axil_bvalid
  in  [31:0] s_axil_araddr    out s_axil_arready   in  s_axil_arvalid
  out [31:0] s_axil_rdata     out [1:0] s_axil_rresp
  in  s_axil_rready           out s_axil_rvalid
```

> **This interface has no `awprot`, no `arprot`, and no `wstrb`.** Every write is
> a full 32-bit word. Any register slice you place on it must be configured
> `HAS_PROT 0`, `HAS_WSTRB 0`, or the link mismatches — and `RUN=0` will not
> catch it, because nothing is synthesised.

### AXI4-MM slaves — `s_axi_dma`, `s_axi_pcie`

Two identical 64-bit-address / 512-bit-data AXI4 slaves, 37 signals each.

| Channel | Signals |
|---|---|
| AW | `awaddr[63:0] awburst[1:0] awcache[3:0] awid[1:0] awlen[7:0] awlock[0:0] awprot[2:0] awqos[3:0] awsize[2:0] awvalid` → `awready` |
| W | `wdata[511:0] wstrb[63:0] wlast wvalid` → `wready` |
| B | ← `bid[1:0] bresp[1:0] bvalid`, `bready` |
| AR | `araddr[63:0] arburst[1:0] arcache[3:0] arid[1:0] arlen[7:0] arlock[0:0] arprot[2:0] arqos[3:0] arsize[2:0] arvalid` → `arready` |
| R | ← `rdata[511:0] rid[1:0] rlast rresp[1:0] rvalid`, `rready` |

- `s_axi_dma` — QDMA MM-mode descriptors target this port; the path for bulk
  host↔RP transfer (e.g. preloading reference data into HBM).
- `s_axi_pcie` — the host's BAR4 (256 MB, prefetchable) lands here for direct
  load/store access into RP-side memory or registers.

> **There is no `region` signal on either port.** A register slice on them needs
> `HAS_REGION 0` and `SUPPORTS_NARROW_BURST 1`, `ID_WIDTH 2`.

### AXI4-MM master — `m_axibr`

RP→host writeback through the QDMA bridge slave. 29 signals: 64-bit address,
512-bit data, `arid/awid/bid/rid` **[3:0]**, no `cache/lock/prot/qos/region`.

> The shell only observes ID bits `[1:0]`; the upper two are unobserved outputs.
> This is an intentional, whitelisted asymmetry — do not "fix" it.

### AXI-Stream — `s_axis_rph2c`, `s_axis_ethrx0`, `m_axis_rpout0`, `m_axis_rpout1`

All four have the identical 9-signal shape:

```
  tdata[511:0]  tkeep[63:0]  tstrb[63:0]  tlast  tvalid  tready
  tid[15:0]     tdest[15:0]  tuser[31:0]
```

| Port | Dir | Role |
|---|---|---|
| `s_axis_rph2c` | in | Host H2C lane — descriptors `h2c_dst_trans` rewrote into the RP range. |
| `s_axis_ethrx0` | in | Wire RX the static `pkt_route_0` matched to your lane. |
| `m_axis_rpout0` | out | Egress lane 0 into `nicsw`. |
| `m_axis_rpout1` | out | Egress lane 1 into `nicsw`, independent of lane 0. |

## AXI-Stream metadata layout

The QDMA adapter fixes the sideband encoding. It is the same on every stream
crossing the RP boundary:

| Field | Layout |
|---|---|
| `tid[15:0]` | Packet ID — monotonic, assigned by the shell. |
| `tdest[15:0]` | `{[15] rsv, [14:12] port_id, [11] rsv, [10:0] qid}` |
| `tuser[31:0]` | `{[31:16] mdata_lsb, [15:0] len_nbytes}` |

`len_nbytes` is **authoritative**: the shell has already length-policed the
packet, so you do not need to re-derive length by counting beats or scanning
`tkeep`. A wire-length filter can read it directly.

`tkeep` and `tstrb` are both present. On ingress, AND them before using the byte
mask (`mkAxisSlaveAdapterS` in [`../libs/bsv/AxisGetPut.bsv`](../libs/bsv/AxisGetPut.bsv)
already does this).

## `tdest` routing — and the one trap

Egress `tdest` on `m_axis_rpout*` selects the destination in `nicsw`:

| `tdest` | Destination |
|---|---|
| `0x0000–0x7FFF` | Host, via QDMA C2H. **Use this range for results going to host software.** |
| `0x8000–0xFFEF` | Also host-range at `nicsw`, but loops back toward the RP at `h2c_sw`. |
| `0xFFF0` | CMAC0 TX — out the wire. |
| `0xFFF1` | CMAC1 TX (dual-CMAC boards only; unused on au50). |

> **The trap.** `0xFFF0`/`0xFFF1` are exactly the values that make `h2c_sw`
> **bypass the RP entirely** and go straight to `nicsw`. So a host-injected
> packet must enter with `tdest ≤ 0xFFEF` to reach your logic at all — and if
> you want it to leave toward the wire afterwards, something *inside* the RP
> must rewrite the egress `tdest` to `0xFFF0`. There is no way to have both a
> single fixed `tdest` that enters the RP and exits to the wire.

## Rules that are not visible in the port list

1. **Every output must be driven.** An undriven output synthesises to a constant
   and collides with the static side's driver at link time: Vivado reports
   `DRC MDRV-1` with hundreds of flip-flop outputs and GND both driving the same
   net. Tie off every interface you do not use — including `m_axibr` if you
   never write to host memory. This is not optional and it is not caught by a
   `RUN=0` validation pass.
2. **The RP is gated by `rpen`.** The host can assert `rp_detach` (see
   [03](03-address-map-and-control.md)), which disconnects your partition and
   drives all AXI-side handshakes to safe defaults. During that window your
   logic sees no traffic; after reattach, expect a `rp_reset` pulse.
3. **A partial reconfiguration destroys all RP state**, including anything in
   HBM behind an RP-instantiated controller. Post-load re-initialisation is the
   host's job.
4. **Boundary register slices must match the contract exactly.** The signal set
   above dictates their configuration; see
   [`../examples/bd/boundary-guard-ring.tcl`](../examples/bd/boundary-guard-ring.tcl)
   for the validated settings and [05](05-floorplan-au50.md) for why you want
   them.

## Checking your work

[`../examples/scripts/check_axi.py`](../examples/scripts/check_axi.py) validates
AXI port directions and cross-module width consistency:

```bash
python3 examples/scripts/check_axi.py --src-dir libs/shell
```

It enforces the `m_` = master / `s_` = slave convention per signal suffix and
whitelists the two intentional asymmetries (DDR address width, PCIe bridge ID
truncation). Run it before a build, not after one fails.
