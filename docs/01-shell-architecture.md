# Shell architecture

The VibeNIC shell is a timing-closed, partially-reconfigurable FPGA SmartNIC
base. It occupies a static region pinned to the chip edge and hands the rest of
the die to your logic as a single contiguous reconfigurable partition (RP)
behind standard AXI interfaces.

The point of the shell is *subtraction*: PCIe, DMA queues, 100 GbE MAC bring-up,
clocking, reset trees, and the physical design that makes all of it close timing
are absorbed into a region you never rebuild. What is left in front of you is a
flat set of AXI ports at a fixed frequency.

Two properties follow, and both matter more than they look:

- **The static shell is by itself a working, DPDK-capable NIC.** Traffic flows
  host↔wire with no user logic loaded, or with broken user logic loaded. That is
  what makes on-silicon debug possible — see
  [15](15-host-runtime-and-bringup.md).
- **Each iteration recompiles only your partition.** A place-and-route pass
  targets the RP against a pre-implemented shell checkpoint, not the whole
  device. Shell-side timing is closed once and reused.

## Block structure

```
                pcie_refclk         qsfp_refclk            sysclk
                     │                  │                    │
                     ▼                  ▼                    ▼
        ┌─────────────────────┐  ┌────────────┐   ┌──────────────────┐
host ◄─►│  qdma_wrapper       │  │ cmac_subsys│   │  utop MMCM       │
PCIe x8 │  (QDMA IP + adapter)│  │ ×{1,2}     │   │  → user_clk      │
        │   ├─ m_axil (BAR2)  │  │  GT 100GbE │   │    user_100m_clk │
        │   ├─ m_axib (BAR4)  │  └─────┬──────┘   │    cmac_axil_clk │
        │   ├─ m_axi (DMA-MM) │        │ cmac_clk └──────────────────┘
        │   └─ m_h2c / s_c2h  │        │ (~322 MHz)
        └─┬───────────────────┘        ▼
          │ dma_clk (250 MHz)     cmac_eth_cdc (→ user_clk)
          │                            │
          ▼                            ▼
        axil_xbar_cdc ─► axil_xbar (1×6) ─► CMACs, sysmon, QDMA CSR,
          │                                  static config, RP
          ▼
   ┌──────────────────────── user_block (user_clk) ────────────────────────┐
   │ bd_user  (STATIC — never rebuilt by an app)                           │
   │   pkt_route_N   header match-action router, one per CMAC              │
   │   h2c_dst_trans tdest rewriter on the host→FPGA stream                │
   │   h2c_sw        splits host traffic: wire-bound vs RP-bound           │
   │   nicsw         egress switch, routes by tdest                        │
   │   pr_subsys     axi_hwicap + PR-control GPIO                          │
   │                                                                       │
   │ rp_blk   (THE RECONFIGURABLE PARTITION — your logic)                  │
   │   fixed port list; see 02-rp-boundary-contract.md                     │
   └───────────────────────────────────────────────────────────────────────┘
```

| Component | Role |
|---|---|
| `shell_top` | PCIe/GT/MMCM instantiation, clock and reset trees, top-level wiring. |
| `qdma_wrapper` + `qdma_st_adapter` | Xilinx QDMA v5.0. BAR2 (4 MB) is the host's AXI-Lite window; BAR4 (256 MB, prefetchable) is a host AXI-MM bypass straight into the RP. The adapter enforces a fixed AXI-Stream metadata layout and rate-matches H2C/C2H. |
| `cmac_subsystem` | 100 GbE CMAC plus reset/init glue; `cmac_eth_cdc` crosses the 512-bit RX/TX streams from `cmac_clk` into `user_clk`. |
| `user_block` | Holds the static NIC datapath (`bd_user`) and the RP (`rp_blk`), gated by `rpen` (= `~rp_detach`). |

## Packet dataflow

The static datapath steers traffic between CMAC, host, and RP entirely by
AXI-Stream `tdest`. On a dual-CMAC board:

```
 eth_rx_0 ─► pkt_route_0  ─┬─ m_axis_0 ─► nicsw.S03
                           └─ m_axis_1 ─► ethrx0 ─► RP
 eth_rx_1 ─► pkt_route_1  ─┬─ m_axis_0 ─► nicsw.S04
                           └─ m_axis_1 ─► ethrx1 ─► RP

 QDMA H2C ─► h2c_dst_trans ─► h2c_sw ─┬ tdest 0xFFF0–0xFFFF ─► nicsw.S00
                                      └ tdest 0x0000–0xFFEF ─► rph2c ─► RP

 RP ─► rpout0 ─► nicsw.S01        RP ─► rpout1 ─► nicsw.S02

 nicsw routes by tdest:  0x0000–0xFFEF ─► QDMA C2H (host)
                         0xFFF0        ─► CMAC0 wire
                         0xFFF1        ─► CMAC1 wire
```

The RP boundary is therefore **three streams in** (`rph2c`, `ethrx0`, `ethrx1`)
and **two streams out** (`rpout0`, `rpout1`). On single-CMAC boards (au50) there
is no `pkt_route_1`, no `ethrx1`, no `eth_tx_1`, and `0xFFF1` is unused.

Full `tdest` semantics, including the bypass trap that catches everyone once,
are in [02](02-rp-boundary-contract.md). The router and translator register
models are in [03](03-address-map-and-control.md).

## What the shell hands you

On `user_clk`, with a free-running 100 MHz alongside:

| Port | Kind | Use |
|---|---|---|
| `s_axil` | AXI4-Lite 32/32 | Host MMIO into your logic — one window in BAR2. |
| `s_axi_pcie` | AXI4-MM 64/512 | Host BAR4 bypass: direct host reads/writes into RP memory. |
| `s_axi_dma` | AXI4-MM 64/512 | QDMA MM-mode descriptors land here — bulk host↔RP transfers. |
| `m_axibr` | AXI4-MM 64/512 | RP-initiated writes into host memory, via the QDMA bridge slave. |
| `s_axis_rph2c` | AXI-S 512 | Host→FPGA packet stream routed into the RP. |
| `s_axis_ethrx0` | AXI-S 512 | Wire RX the static router decided belongs to you. |
| `m_axis_rpout0/1` | AXI-S 512 | Two independent egress lanes; `tdest` picks host or wire. |

Everything else — CMAC link bring-up, QDMA queue management, packet steering,
AXI-Lite plumbing, clock generation, the reset tree — is the shell's problem.

## What the shell does *not* give you

- **No external memory on the RP boundary.** HBM (or DDR) is instantiated by
  the app *inside* its own block design, and it costs an HBM controller
  re-implementation on every build plus ~100 ms of init after every partial
  load. See [07](07-vendored-ip-catalog.md) and
  [`../examples/bd/hbm-subsystem.tcl`](../examples/bd/hbm-subsystem.tcl).
- **No CMAC, QDMA, or PCIe primitives inside the RP.** Instantiating any of them
  in your partition is a category error.
- **No second clock.** You get one clock domain and a free-running reference; if
  you need another, you generate it yourself. See
  [04](04-clocking-and-reset.md).

## Boards

| Board | Part | CMAC / QSFP | Memory | Vivado |
|---|---|---|---|---|
| **au50** (primary) | `xcu50-fsvh2104-2-e` | 1 × 100 GbE | HBM 8 GB | 2024.2 |
| au280 | `xcu280-fsvh2892-2L-e` | 2 × 100 GbE | DDR4 | **2023.2** |
| au55c | `xcu55c-fsvh2892-2L-e` | 2 × 100 GbE | HBM 16 GB | 2024.2 |

Differences are in [06](06-board-deltas.md).
