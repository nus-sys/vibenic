# VibeNIC

**An FPGA SmartNIC platform designed so that a datapath can be built by
describing it.**

A conventional FPGA NIC design puts board bring-up, PCIe, 100 GbE, memory
controllers, floorplanning and a multi-hour place-and-route between an idea and
a packet on the wire. VibeNIC moves all of that behind a static, timing-closed
shell and exposes the part that is actually your design — a reconfigurable
partition with standard AXI-Stream, AXI4-MM and AXI-Lite interfaces — as the
only thing you write and the only thing that recompiles.

Three pieces make that work, and this repository is the umbrella over all
three:

| | | |
|---|---|---|
| **[`qnic-shell/`](qnic-shell)** | the hardware platform | QDMA PCIe 4.0 host DMA, 100 GbE CMAC, the NIC datapath, and a DFX reconfigurable partition for user logic. Alveo U50, U280, U55C. |
| **[`qnic-driver/`](qnic-driver)** | the host software | Linux kernel module with a netdev, a DPDK userspace library, partial-reconfiguration loading, and the `qnic-smi` management CLI. |
| **[`deps/`](deps)** | the grounding corpus | **D**ocumentation, **E**xamples and **P**rompts: the shell and library contracts, a complete validated network function, and the working clamps that keep generated designs on paths known to build. |

The first two are the platform. The third is what makes it usable by a
developer — human or LLM agent — who has not spent a year inside it.

## Why the corpus is a first-class component

The shell deliberately restricts almost nothing: nearly the whole partition
stays reconfigurable, and that is the point. But a large, permissive design
space leaves generation underdetermined, and every unvetted microarchitectural
choice is a fresh opportunity to invent something that has never been built on
this platform.

[`deps/`](deps) answers that with **guidance density** rather than restriction.
It states what is true about the platform ([`deps/docs/`](deps/docs)), shows
what has actually been built and validated ([`deps/examples/`](deps/examples)),
and clamps working habits — not capability — to patterns that close
([`deps/prompts/`](deps/prompts)). Rules are marked MUST or SHOULD, and each
MUST is there because violating it has already cost someone a build.

## Getting started

```bash
git clone --recurse-submodules <this-repo> vibenic
cd vibenic
make init          # if you cloned without --recurse-submodules
```

**Building a datapath.** Read [`AGENTS.md`](AGENTS.md) — it is the entry point
for anyone, or anything, writing a network function against this shell. It
names the non-negotiables and routes you to the document that covers what you
are about to do.

**Checking the toolchain.** From the repository root:

```bash
make check         # compiles and simulates the corpus case study end to end
```

This needs `bsc`, Verilator and cocotb, and takes a few minutes. It needs no
Vivado, no board, and no shell package. If it passes, your environment can
build and verify a network function.

**Running a card.** Build and install the driver from
[`qnic-driver/`](qnic-driver), then use `qnic-smi` to enumerate boards, bring up
CMAC ports, and load a partial bitstream onto a running shell.

## How a design gets onto the card

```
  spec / refarch / test-plan          deps/prompts/08-spec-authoring.md
            │
            ▼
  BSV datapath  +  rp_user.tcl        deps/prompts/02, deps/prompts/03
            │
            ▼
  Bluesim  and  cocotb + Verilator    deps/prompts/04  — before any synthesis
            │
            ▼
  make app  against a shell package   deps/docs/14  — partial bitstream only
            │
            ▼
  qnic-smi load  →  on-card bring-up  deps/docs/15
```

The shell is built once and stays loaded. Each design iteration produces a
partial bitstream that is linked against the shell's abstract checkpoint and
reconfigured onto the running card, so the host, the PCIe link and the network
ports never go down.

## Supported boards

| Board | Part | 100 GbE | Memory | Vivado |
|---|---|---|---|---|
| Alveo U50 | `xcu50-fsvh2104-2-e` | 1 × QSFP | HBM | 2024.2 |
| Alveo U280 | `xcu280-fsvh2892-2L-e` | 2 × QSFP | DDR4 | 2023.2 |
| Alveo U55C | `xcu55c-fsvh2892-2L-e` | 2 × QSFP | HBM | 2024.2 |

U50 is the primary target throughout the corpus; the differences that matter
for the other two are in [`deps/docs/06-board-deltas.md`](deps/docs/06-board-deltas.md).

## Repository layout

```
AGENTS.md        entry point for building a network function on this platform
deps/            the DEPs corpus — docs, examples, libs, prompts, self-checks
qnic-shell/      submodule: the FPGA shell and its build flow
qnic-driver/     submodule: kernel module, DPDK library, management tools
build/           local workspace for your own designs (never tracked)
```

## License

The umbrella repository is dual-licensed by content type:

- **Prose** — `deps/docs/`, `deps/prompts/`, and the READMEs — under
  [CC-BY-4.0](LICENSE-CC-BY-4.0).
- **Code** — `deps/examples/`, `deps/libs/`, `deps/tools/` — under
  [Apache-2.0](LICENSE-Apache-2.0).

Vendored third-party sources keep their original terms; see [`NOTICE`](NOTICE).
The submodules carry their own licenses: `qnic-shell` is Apache-2.0, and
`qnic-driver` is GPL-2.0 for its kernel code and Apache-2.0 for userspace.
