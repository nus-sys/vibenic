# VibeNIC DEPs

**D**ocumentation, **E**xamples, and **P**rompts for building FPGA SmartNIC
datapaths on the VibeNIC shell.

The shell absorbs board-level complexity into a timing-closed static region
behind standard interfaces, so each iteration is a user-partition-only
recompile and most of the design space stays reconfigurable. A building-block
library on top lets a developer compose rather than microarchitect.

This corpus is the third piece: what grounds a developer — human or agent — in
the shell and library contracts. The design space stays large and permissive;
the DEPs supply **guidance density** instead of restriction.

The working entry point for a build is the repository root's
[`AGENTS.md`](../AGENTS.md). Start there; come here for the substance.

## The split

| | | |
|---|---|---|
| **[docs/](docs/)** | *what is true* | Shell architecture and the RP boundary contract, address maps, clocking, the U50 floorplan, the vendored IP catalog, the BSV library, simulation frameworks, build flow, host runtime. |
| **[examples/](examples/)** | *what is validated* | A complete, buildable network function; block-design and constraint Tcl; simulation harnesses and a golden model; diagnostic scripts. |
| **[prompts/](prompts/)** | *how to work* | Workflow, decomposition, the BSV and Block-Design clamps, simulation mandates, floorplanning and timing, build/debug iteration, dos and don'ts, spec authoring. |
| **[libs/](libs/)** | *what you build on* | The BSV building-block library, the vendored Verilog/SV IP, the packaged stream router, and a read-only copy of the boundary contract. |

## Quickstart

```bash
# 1. Prove the toolchain and the library/example split work
make check-bsv         # bsc: compile the case-study NF against libs/
make check-sim         # golden model + Bluesim tier + cocotb/Verilator tier

# 2. Read, in this order
#    docs/02-rp-boundary-contract.md    the contract you must not break
#    prompts/02-bsv-coding-clamp.md     how the logic gets written
#    examples/case-study-nf/            what a finished one looks like
```

`make check` runs all of the above plus `check-links` (every relative link
resolves), `check-paths` (no absolute host paths anywhere in the tree), and
`check-axi` (the boundary linter against `libs/shell`). None of it needs Vivado.

## Layout

```
docs/          15 documents, numbered in reading order
examples/
  case-study-nf/   the paper's HBM vector-reduce NF — buildable in place
    spec/          its specification, reference architecture, and test plan
    src/           10 BSV modules
    test/          8 testbenches — 7 pure-logic (Bluesim), 1 needs Verilator
    tests/         4 cocotb suites + the numpy golden model
  bd/          Vivado block-design Tcl: HBM subsystem, boundary guard ring,
               and two complete rp_user designs
  xdc/         floorplan constraints: reusable guard pblocks + two as-built files
  tcl/         app build, post-link hook, BSV→IP packaging
  scripts/     AXI boundary linter, congestion/timing triage, device census
libs/
  bsv/         the BSV building-block library
  verilog/     vendored cuckoo hash-table IP, HLS hashers, bsc primitives
  ip/          AxisPacketRouterDual, packaged for Vivado
  shell/       rp_blk.v — the authoritative boundary. Read-only.
prompts/       9 documents
tools/         link checker
```

## The case study

[`examples/case-study-nf/`](examples/case-study-nf/) is the network function the
VibeNIC paper reports: a stateful per-flow tensor-mixing datapath on Alveo U50.
Each UDP packet carries a 256-element `int16` query vector; on a flow-table hit
the design reads three reference vectors from separate HBM channels, emits their
four-way average to the host, and reports misses to a host notification ring.

It is here because it is *validated*, and its status is stated plainly:

- **Functionally complete and byte-exact in simulation**, including an
  end-to-end diff against an independent golden model under backpressure and
  memory latency.
- **Its last U50 build misses timing**: post-route WNS −2.423 ns. The worst
  paths are inside the *vendored* cuckoo hash-table IP's victim/delmask logic —
  12–14 logic levels at ~6.5 ns, which misses even at 200 MHz — **not** at the
  partition boundary, whose guard-slice floorplan is correct and closes.

Closing it needs IP-level pipelining or a slower clock domain for the table, not
more constraints. See [`docs/05-floorplan-au50.md`](docs/05-floorplan-au50.md).

## What is not here

- **The shell sources.** This corpus consumes a shell *support package*;
  [`libs/shell/rp_blk.v`](libs/shell/rp_blk.v) is a read-only copy of the
  boundary contract, not a buildable source tree. The shell itself is the
  [`qnic-shell`](../qnic-shell) submodule.
- **The host driver.** [`docs/15`](docs/15-host-runtime-and-bringup.md) documents
  its usage and the register sequences, not its implementation; the driver is
  the [`qnic-driver`](../qnic-driver) submodule.
- **An evaluation harness.** Scoring rubrics and conformance oracles grade a
  developer and deliberately live elsewhere; the reusable practice distilled
  from them is in [`prompts/`](prompts/).

## Requirements

`bsc` 2024.01, Verilator 5.020, cocotb 1.9.2 + cocotbext-axi 0.1.24, Python 3.8,
numpy, scapy — for everything except the FPGA build. Vivado 2024.2 (2023.2 for
au280) and a shell support package for that.

## License

Prose (`docs/`, `prompts/`, and the READMEs) is CC-BY-4.0; code (`examples/`,
`libs/`, `tools/`) is Apache-2.0. Vendored third-party sources under
`libs/verilog` and `libs/ip` keep their own terms — see [`../NOTICE`](../NOTICE).
