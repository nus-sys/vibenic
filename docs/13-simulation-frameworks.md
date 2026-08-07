# Simulation frameworks

Two tiers, and the choice between them is **forced by the design, not by
preference**. Getting it wrong wastes an afternoon on a toolchain error that
looks like a code error.

| Tier | Simulator | Use for |
|---|---|---|
| **Bluesim** | `bsc -sim` | Pure-logic modules — no `import "BVI"` anywhere in the closure. |
| **cocotb + Verilator** | `verilator --cc` via `cocotb.runner` | Anything AXI-facing, anything with a BVI import, and every end-to-end test. |

What each tier *must* cover is a policy question, answered in
[`../prompts/04-simulation-mandates.md`](../prompts/04-simulation-mandates.md).
This document is the mechanics.

## Why the split is forced

A BVI module is a Verilog black box. Bluesim cannot execute it, so any testbench
whose closure includes one has to go through generated Verilog. That much is
expected. What is not obvious is *which* Verilog simulator:

- **iverilog 10.3 cannot parse the vendored SystemVerilog.** `cached_cuckoo.sv`
  and friends use SV-2012 constructs (`always_ff` inside `generate`) that it
  rejects.
- **`verilator --binary --timing` needs a C++20 compiler.** The reference
  machine has g++ 10.5, so that path fails to build.
- **cocotb's Verilator backend uses `verilator --cc`** — no `--binary`, no
  `--timing`, C++14 — which g++ 10.5 compiles fine.

So: BVI ⇒ cocotb on Verilator. This is not a style choice, and a variant that
rediscovers it from scratch has burned iterations for nothing.

In the case study's module set, 7 of 8 unit testbenches are pure logic and run
in Bluesim; only the flow-table wrapper (which instantiates the cuckoo BVI) and
the NF top go through cocotb.

## Tier 1 — Bluesim

```bash
make bsim PKG=SimFourWayAverager MOD=mkSimFourWayAverager
make bsim-all      # all 7 pure-logic testbenches
```

Under the hood:

```bash
bsc -sim <flags> -g mkSimX test/SimX.bsv
bsc -sim <flags> -e mkSimX -o build/mkSimX.bexe
./build/mkSimX.bexe
```

A Bluesim testbench is BSV: a `mkSimX` module that instantiates the DUT, drives
it from rules, and `$display`s a verdict. Fast — the whole 7-module suite runs
in seconds — with native BSV types, so you compare `Vector#(32, Int#(16))`
against `Vector#(32, Int#(16))` rather than picking bits out of a bus.

Worked testbenches:
[`../examples/case-study-nf/test`](../examples/case-study-nf/test).

**What Bluesim will not show you.** It executes the BSV schedule, so it hides
exactly the class of bug that lives in the gap between schedule and protocol:
AXI handshake violations, `tready`/`tvalid` interaction under backpressure, and
anything about the generated Verilog's cycle behaviour. It also happily passes a
self-consistent-but-wrong data convention — the case study's byte-order bug was
invisible to every per-module Bluesim test because each generated its own
little-endian vectors and checked them against itself.

## Tier 2 — cocotb + Verilator

```bash
make compile                                  # bsc -> verilog/mkVectorAvgNF.v
python3 tests/cocotb/run_vecavg_e2e.py
```

The runner is plain Python:

```python
from cocotb.runner import get_runner
runner = get_runner("verilator")
runner.build(verilog_sources=SOURCES, hdl_toplevel="mkVectorAvgNF",
             build_args=BUILD_ARGS, build_dir=..., always=True)
runner.test(hdl_toplevel="mkVectorAvgNF", test_module="test_vecavg_e2e",
            test_dir=..., build_dir=...)
```

with the build arguments that matter:

```python
BUILD_ARGS = [
    "-Wno-fatal",
    "-y", <libs/verilog>,     # CachedCuckoo.v + the cuckoo SV closure
    "-y", <bsc lib Verilog>,  # bsc primitives: FIFO2, FIFOL1, SizedFIFO, BRAM*
    "+libext+.v+.sv",
    "--no-timing",
]
```

List only the DUT's own generated `.v` files explicitly; the BVI closure and the
bsc primitives resolve from the `-y` library directories. In this corpus that is
factored into
[`../examples/case-study-nf/tests/cocotb/_paths.py`](../examples/case-study-nf/tests/cocotb/_paths.py),
which also locates the bsc Verilog library from `$BSC_VERILOG_LIB`, then from
`bsc` on `PATH`, then from a default — so no absolute path is baked in.

### The agent inventory (cocotbext-axi)

Everything crossing the RP boundary is AXI, so every external interface is
driven by a stock agent. Do not hand-roll these.

| Interface | Agent |
|---|---|
| `s_axis_ethrx0`, `s_axis_rph2c` | `AxiStreamSource` |
| `m_axis_rpout0/1` | `AxiStreamSink` |
| HBM read masters (per channel) | `AxiSlave` backed by a Python `bytearray` |
| `s_axil` | `AxiLiteMaster` |
| `m_axibr` | `AxiSlave` backed by a `bytearray` (models host memory) |
| any of the above | the matching protocol **monitor** — assert zero violations |

`AxiStreamSource` supports gapped `tvalid`; `AxiStreamSink` supports random
`tready` backpressure; `AxiSlave` supports configurable per-burst latency and
`RRESP` error injection. Those three knobs cover most of the interesting test
space.

> **Never hand-roll an AXI-Stream collector.** The case study lost a long
> investigation to a "~27 % header drop" that turned out to be a testbench
> artifact: a hand-written egress collector drove `tready` itself and sampled in
> `ReadOnly`, mis-scoring transfers by one cycle under backpressure, so it
> recorded beats as not-taken that the DUT had actually transferred. Re-run with
> `AxiStreamSink`, the design was byte-exact, 432/432 beats, 48/48 frames, in
> order, under ~45 % random backpressure. The NF needed no change. Use the
> library agents; they are the reference implementation of the protocol you are
> testing against.

CMAC and QDMA are never simulated as IPs — only their AXI-Stream contracts are.

### The golden model

The reference implementation lives in Python + numpy, shared by every cocotb
test, and is used **both** to seed inputs and to score outputs:

```python
compute_result(input_packet, table_state, sequence_num)
    -> (result_packet, notification_or_none, counter_deltas)
```

See [`../examples/case-study-nf/tests/golden/vecavg_golden.py`](../examples/case-study-nf/tests/golden/vecavg_golden.py)
and its self-check. A byte-for-byte diff of the emitted packet against this
model is what pins data-format decisions — byte order, rounding, field
placement — to the specification. Nothing else does.

Packets are constructed with `scapy`.

### The warmup nobody expects

The vendored cuckoo table's `uram_bank.sv` clears its valid RAM one entry per
cycle after reset. **Idle ~2600 cycles after `RST_N` deasserts before issuing
any command**, or early inserts are wiped and every lookup misses. The insert
FSM is also eventually-consistent over several cycles, so allow settling time
after an upsert before the matching lookup. A test that skips this looks like a
broken table.

## Toolchain, as validated

| Tool | Version |
|---|---|
| `bsc` | 2024.01-20-g9a97f9d0 |
| Verilator | 5.020 |
| cocotb | 1.9.2 |
| cocotbext-axi | 0.1.24 |
| Python | 3.8 |

Pins and their resolution are in [`../PROVENANCE.md`](../PROVENANCE.md).

## What is out of scope for simulation

Timing closure, static timing analysis, post-place-and-route gate-level
simulation, performance modelling beyond simulator cycle counts, and HBM
controller internals (behavioural AXI slaves are sufficient — the wrapper
presents AXI to your logic either way). For the physical side see
[05](05-floorplan-au50.md) and
[`../prompts/06-build-debug-iteration.md`](../prompts/06-build-debug-iteration.md).
