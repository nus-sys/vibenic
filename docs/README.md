# Documentation

Informational context: what is true about the VibeNIC shell, the device, the
vendored IP, and the toolchain. Documentation states facts and contracts; it
does not tell you how to work — that is [`../prompts/`](../prompts/) — and it
does not contain runnable designs — that is [`../examples/`](../examples/).

Primary target throughout is the **Alveo U50** (`xcu50-fsvh2104-2-e`), the board
of the case study. Other boards are covered in [06](06-board-deltas.md).

## Read this before you do that

| Before you… | Read |
|---|---|
| touch **any** shell interface, or write a port list | [02 — RP boundary contract](02-rp-boundary-contract.md) |
| write host software or pick a register offset | [03 — Address map and control plane](03-address-map-and-control.md) |
| instantiate a clock, MMCM, or CDC | [04 — Clocking and reset](04-clocking-and-reset.md) |
| write a pblock, place an IP, or debug timing | [05 — Floorplan (U50)](05-floorplan-au50.md) |
| instantiate any vendor IP in a block design | [07 — Vendored IP catalog](07-vendored-ip-catalog.md) |
| write a line of BSV | [09](09-bsv-language-essentials.md), then [10](10-bsv-dataflow-handshaking.md) |
| parse or emit packets | [11 — Per-beat packet processing](11-bsv-packet-per-beat.md) |
| issue an AXI read or write from BSV | [12 — AXI/TLM transactions](12-bsv-axi-transactions.md) |
| write a testbench | [13 — Simulation frameworks](13-simulation-frameworks.md) |
| launch a build | [14 — Build and load flow](14-build-and-load-flow.md) |
| bring a design up on hardware | [15 — Host runtime and bring-up](15-host-runtime-and-bringup.md) |
| reach for something that might already exist | [08 — BSV library catalog](08-bsv-library-catalog.md) |

## Index

**The platform**

1. [Shell architecture](01-shell-architecture.md) — what the shell is, what it
   absorbs, and what it hands you.
2. [RP boundary contract](02-rp-boundary-contract.md) — the exhaustive port
   list, the AXI-Stream metadata layout, and the `tdest` routing map. The single
   most important document here.
3. [Address map and control plane](03-address-map-and-control.md) — BAR windows,
   the AXI-Lite crossbar, and the register models of the shell's steering IPs.
4. [Clocking and reset](04-clocking-and-reset.md) — clock domains, the free
   100 MHz reference, and the rules for adding a clock inside the RP.
5. [Floorplan — Alveo U50](05-floorplan-au50.md) — clock-region grid, SLR split,
   partition-pin geometry, and where each kind of logic must live.
6. [Board deltas](06-board-deltas.md) — au280 and au55c differences.

**The building blocks**

7. [Vendored IP catalog](07-vendored-ip-catalog.md) — every vendor IP the
   validated designs use, its known-good configuration, and its trap.
8. [BSV library catalog](08-bsv-library-catalog.md) — what lives in
   [`../libs/bsv`](../libs/bsv), including the flow-table IP contract.

**Writing the logic**

9. [BSV language essentials](09-bsv-language-essentials.md) — the subset that
   matters here, plus the hallucination trap list.
10. [Dataflow and FIFO handshaking](10-bsv-dataflow-handshaking.md)
11. [Per-beat packet processing](11-bsv-packet-per-beat.md)
12. [AXI / TLM transactions](12-bsv-axi-transactions.md)

**Getting it to run**

13. [Simulation frameworks](13-simulation-frameworks.md) — the two tiers, the
    toolchain constraints that force the choice, and the available APIs.
14. [Build and load flow](14-build-and-load-flow.md) — packaged-shell app build,
    partial bitstream, and load.
15. [Host runtime and bring-up](15-host-runtime-and-bringup.md) — NIC usage,
    traffic steering, memory preload, and on-silicon debug.
