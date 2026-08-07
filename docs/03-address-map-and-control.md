# Address map and control plane

Everything the host reaches on the card goes through one of three PCIe windows.

| BAR | Size | Lands on |
|---|---|---|
| BAR2 | 4 MB | AXI-Lite. Fans out through the top-level crossbar to the map below. |
| BAR4 | 256 MB, prefetchable | AXI-MM straight into the RP's `s_axi_pcie`. |
| — | — | QDMA MM-mode DMA descriptors reach the RP's `s_axi_dma`. |

## BAR2 — the AXI-Lite crossbar

One QDMA AXI-Lite master fans out to six slaves. **This map is identical on
every board.**

| Port | Range | Size | Destination |
|---|---|---|---|
| M00 | `0x000000–0x1FFFFF` | 2 MB | **The RP** (`rp_user_inst/s_axil`) — `rpen`-gated |
| M01 | `0x200000–0x2FFFFF` | 1 MB | Static shell config window |
| M02 | `0x310000–0x31FFFF` | 64 KB | CMAC0 (QSFP0) |
| M03 | `0x320000–0x32FFFF` | 64 KB | CMAC1 (QSFP1) — dual-CMAC boards |
| M04 | `0x308000–0x30FFFF` | 32 KB | System Management wizard |
| M05 | `0x300000–0x307FFF` | 32 KB | QDMA CSR |

The CDC stage masks each window's address to its own width, so a block behind
M00 sees 0-based offsets. Host software still uses the absolute addresses.

M00 is gated by `rpen`, so a detached or blank RP cannot stall the bus.

### Static shell config window (M01)

| Absolute | Sub-offset | Block |
|---|---|---|
| `0x208000–0x208FFF` | `0x8000` | `pkt_route_0` — CMAC0 packet router |
| `0x209000–0x209FFF` | `0x9000` | `pkt_route_1` — CMAC1 router, *dual-CMAC boards only* |
| `0x20C000–0x20CFFF` | `0xC000` | `h2c_dst_trans_i` — H2C `tdest` rewriter |
| `0x20E000–0x20EFFF` | `0xE000` | PR-control GPIO |
| `0x20F000–0x20FFFF` | `0xF000` | `axi_hwicap` — partial bitstream loader |

au50 has one router, so no `0x209000` entry.

### RP window (M00)

Yours to define. The case study's layout, for orientation:

| Offset | Size | Block |
|---|---|---|
| `0x00_0000` | 64 KB | NF control registers |
| `0x01_0000` | 64 KB | `axi_gpio_0` — HBM status readback |
| `0x10_0000` | 16 KB | HBM `SAPB_0` via an APB bridge |

CMAC bring-up at `0x310000` follows the standard Xilinx sequence in PG203. The
per-CMAC sub-map is not board-portable; use PG203, not a copied constant.

## PR control (`0x20E000`)

An `axi_gpio` carrying the partition sideband:

| Bit | Direction | Role |
|---|---|---|
| `rp_reset` | host → RP | Soft-reset the RP's logic without reloading the bitstream. |
| `rp_detach` | host → RP | Disconnect the RP from the static shell; gates `rpen`, drives all AXI handshakes to safe defaults. |
| `bsver` | RP → host, RO | Reads back `0xabcd1234`, a constant baked into the static block design. A sanity check that the shell is alive. |

Partial-load sequence: assert `rp_detach` → wait for the `rpen` domain to
quiesce → stream the partial bitstream through HWICAP at `0x20F000` → deassert
`rp_detach` → pulse `rp_reset`.

## Register models of the steering IPs

These two custom BSV IPs are what make the shell's traffic steering
programmable. All registers are 32-bit, little-endian, word-aligned; offsets are
relative to the block's window.

### `AxisPacketRouterDual` — `pkt_route_N` (`0x208000` / `0x209000`)

A header match-action router. It matches the **first beat** of each packet
against a table, then for the winning entry **replaces** the outgoing `tdest`
and selects which downstream master (`m_axis_0` / `m_axis_1`) the packet leaves
on. The packed variant (`mkAxisPacketRouterCmac27`) is 512-bit, 2 downstream
ports, 8 entries.

| Offset | Access | Layout |
|---|---|---|
| `0x000` | R/W | R: IDENT `[31:8]`=`0xC32956`, `[7:4]`=#downstreams, `[3:0]`=#entries. W: any non-zero = soft reset |
| `0x004` | R/W | force ctrl: `[4]`=force_drop, `[0]`=force_match enable, `[11:8]`=forced entry id |
| `0x008` / `0x00C` | R | upstream packet count, low / high 32 bits |
| `0x010 + 0x10·e` | R/W | entry *e* action word0: `[3:0]`=downstream port, `[31:16]`=TID reload |
| `0x014 + 0x10·e` | R/W | entry *e* action word1: `[15:0]`=**egress `tdest`**, `[31:16]`=metadata |
| `0x018 + 0x10·e` / `0x01C + 0x10·e` | R | entry *e* matched-packet count, low / high |
| `0x100 + 0x80·(e−1)` | R/W | entry *e* (≥1) 512-bit header **match value**; `[5:2]` = 32-bit word index 0–15 |
| `0x140 + 0x80·(e−1)` | R/W | entry *e* (≥1) 512-bit **mask**; `[5:2]` = word index |

A beat matches entry *e* when `(data & mask) == (header & mask)` over the kept
bytes. Entry 0 is the miss/default action; entries 1…N−1 are header entries and
**lowest index wins**.

> **Reset quirk.** Entries reset to `{port 0, tdest 0, mask 0, header 0}`, and a
> **zero mask matches every packet**. So at reset entry 1 catches all traffic
> and forwards it to downstream port 0 with `tdest 0`. To change default
> behaviour you must reprogram **entry 1**, not entry 0 — writing entry 0 alone
> does nothing while a maskless entry 1 still matches everything.

### `AxisDestTrans` — `h2c_dst_trans_i` (`0x20C000`)

An inline `tdest` translator (ternary CAM). Every beat passes through unchanged
except `tdest`, which is rewritten from the **first beat's** value and applied to
the whole packet. The packed variant has 15 entries.

| Offset | Access | Layout |
|---|---|---|
| `0x000` | R | IDENT `[31:8]`=id prefix, `[7:0]`=entry count |
| `0x004` | R/W | `DEFAULT_TRANS` (miss action): `[31:16]`=mask, `[15:0]`=value |
| `0x008 + 8·i` | R/W | `ENT_MATCH[i]`: `[31:16]`=match_mask, `[15:0]`=match_value |
| `0x00C + 8·i` | R/W | `ENT_TRANS[i]`: `[31:16]`=trans_mask, `[15:0]`=trans_value |

An entry is enabled only when **both** masks are non-zero; lowest index wins; on
a miss `DEFAULT_TRANS` applies. Result:
`tdest_out = (tdest_in & ~trans_mask) | (trans_value & trans_mask)`.

Reset is all-zero, i.e. identity passthrough — a transparent wire.

### An RP-side router

au50 and au55c's stock RP carries its own `AxisPacketRouterDual_0`, which is how
an RP-range packet gets its egress `tdest` rewritten to `0xFFF0` for the wire.
It is **not** on the AXI-Lite crossbar — it sits in the QDMA AXI-MM space at
`0x08200000`, reached through BAR4 (`s_axi_pcie`) or an MM DMA.

au280's stock RP instead has a fixed `axis_switch` that splits by `tdest[15]` and
cannot rewrite `tdest`, so it can only return host-range traffic to C2H. A
custom RP fixes that; see [06](06-board-deltas.md).

The IP itself is vendored at [`../libs/ip/pktrte_dual`](../libs/ip/pktrte_dual)
and is instantiable inside your own RP block design.

## Worked bring-up sequences

Concrete register writes for steering traffic through the RP are in
[15 — Host runtime and bring-up](15-host-runtime-and-bringup.md).
