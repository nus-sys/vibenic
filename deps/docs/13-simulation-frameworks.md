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

**What Bluesim is not for: replaying a recorded trace.** A trace has to be
compiled *into* the BSV to get there, and a few hundred entries returning
`Bit#(512)` is a large ROM synthesised into simulation-only logic — slow to
elaborate and awkward to extend. Reference traces belong in the cocotb tier,
where Python feeds them for free and can afford far more of them. Keep Bluesim
for benches that generate their own stimuli: smoke tests, self-checking stress
loops, and exhaustive sweeps over a small parameter space.

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
> `AxiStreamSink` the design was byte-exact under random backpressure and needed
> no change. Use the library agents; they are the reference implementation of the
> protocol you are testing against.

> **cocotbext-axi silently drops optional signals it can't bind
> case-sensitively.** With bsc's uppercase AXI port names (`WSTRB`, `BRESP`,
> …), the agent's optional-signal binder never matches them, and it then
> reports a default (full strobe, `OKAY`) instead of erroring or warning.
> A test that reads `write_if.wstrb` or injects a `BRESP` error through the
> agent's normal API will pass even when the DUT is wrong. The failure also
> inverts the apparent fault: an unbound `wstrb` reads as *absent*, so the model
> substitutes a full strobe and clobbers memory outside every write's range —
> a correct DUT looks destructively broken. This is not specific to one
> interface: **any cocotb test against a bsc-generated AXI port is affected.** Bind the affected signals explicitly by their exact
> uppercase name, and prefer asserting at the DUT pin or a protocol monitor
> over trusting the transaction object's field for anything optional.

> **A memory latency model is not optional equipment.** Against a zero-latency
> `AxiRam`, a read master's outstanding-burst depth is unobservable: bursts
> retire as fast as they are issued, so a perfect 16-deep pipeliner and a
> strictly serial one both measure 4. Nothing about the master's pipelining is
> visible without latency. Delay each burst between address and data — 100
> cycles is a reasonable HBM stand-in — and the depth becomes a measurement.
>
> Be aware of what that costs: `cocotbext-axi` services one burst at a time, so
> a per-burst delay also serialises them and aggregate bandwidth collapses. That
> is pessimistic, never optimistic, so correctness results stay sound — but it
> is the wrong instrument for a **throughput** target, which needs a slave that
> services bursts concurrently.
>
> The general rule the latency model teaches: **when a measurement accuses the
> design, check the instrument first.** A sink that drives `READY` from having a
> consumer parked in `recv()` will show a master stalled on `ARVALID` for
> thousands of cycles — which reads exactly like a master that will not
> pipeline, and is actually a sink that was off sleeping out its own latency.

> **Give every test that can deadlock an explicit timeout.** Without one, a
> wedged DUT looks like a slow test, and the cost is measured in hours rather
> than in a failed assertion. `@cocotb.test(timeout_time=5, timeout_unit="ms")`
> is enough. Note what a *sim-time* timeout can and cannot catch: it fires on a
> deadlock that leaves the clock toggling, which covers the common case, but a
> deadlock that also stops simulation time needs a wall-clock guard instead.

> **If the DUT cannot be returned to a cold state, run one simulator process
> per scenario.** Pulsing `RST_N` between `@cocotb.test()` cases in one process
> is only equivalent to a fresh start if every piece of state honours reset —
> and the vendored cuckoo table's valid-RAM wipe famously does not, so the
> previous case's keys survive and the next case sees phantom hits. The symptom
> is diagnostic: cases that fail in a shared process and pass when run alone.
> On hardware the question does not arise, because a partial reconfiguration
> destroys the partition outright; a fresh process per scenario is the faithful
> arrangement, not a workaround.

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
cycle after reset. **Idle `2**htSizeLog2` cycles after `RST_N` deasserts before
issuing any command** — ~2600 for the corpus default's 1024 entries, and
proportionally longer for a bigger table — or early inserts are wiped and every
lookup misses. The insert
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

These are the versions the corpus is validated against. Newer `bsc` and
Verilator releases generally work; `cocotbext-axi` is the one worth pinning,
because its optional-signal binding is the subject of the trap above.

## What is out of scope for simulation

Timing closure, static timing analysis, post-place-and-route gate-level
simulation, performance modelling beyond simulator cycle counts, and HBM
controller internals (behavioural AXI slaves are sufficient — the wrapper
presents AXI to your logic either way). For the physical side see
[05](05-floorplan-au50.md) and
[`../prompts/06-build-debug-iteration.md`](../prompts/06-build-debug-iteration.md).
