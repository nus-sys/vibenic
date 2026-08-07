# Simulation mandates

What must exist before you spend hours on synthesis. These are entry conditions,
not suggestions: a build is a slow, low-resolution way to learn something a
simulation would have told you in seconds.

Mechanics, APIs, and toolchain constraints:
[`../docs/13-simulation-frameworks.md`](../docs/13-simulation-frameworks.md).

## Tier selection is not a choice

**MUST: pick the tier from the interface, not from preference.**

| The module… | Tier |
|---|---|
| is pure logic — no `import "BVI"` in its closure | **Bluesim** |
| presents or consumes AXI, AXI-Lite, or AXI-Stream | **cocotb + Verilator** |
| instantiates a BVI module (e.g. the cuckoo table) | **cocotb + Verilator** |
| is the integrated top | **cocotb + Verilator** |

Every *external* interface of an RP top is AXI, so the top test is always
cocotb. Bluesim executes the BSV schedule and therefore cannot see protocol
violations, `tready`/`tvalid` interaction, or generated-Verilog cycle behaviour —
it is fast and precise about logic, and blind to exactly the class of bug that
lives at a bus.

**MUST: test each module in exactly one tier.** Duplicating a test across tiers
costs maintenance and tells you nothing new; skipping a tier because "the other
one passed" is how protocol bugs reach the board.

## Use the library agents

**MUST NOT: hand-roll an AXI or AXI-Stream driver, monitor, or collector.** Use
`cocotbext-axi`: `AxiStreamSource`, `AxiStreamSink`, `AxiMaster`, `AxiSlave`,
`AxiLiteMaster`, and the protocol monitors.

> The case study lost a long investigation to a "~27 % header drop under
> backpressure" that did not exist. A hand-written egress collector drove
> `tready` itself and sampled in `ReadOnly`, mis-scoring AXI-Stream transfers by
> one cycle under backpressure — recording beats as not-taken that the design
> had actually transferred, which looked exactly like short frames. Re-run with
> `AxiStreamSink`, the design was byte-exact: 432/432 beats, 48/48 frames, in
> order, under ~45 % random backpressure plus memory latency. The design needed
> no change.
>
> The library agents are the reference implementation of the protocol you are
> testing against. A bug in your testbench and a bug in your design look
> identical from the outside, and the testbench is the one you have less reason
> to trust.

**MUST: assert zero protocol violations** from the monitors on every AXI
interface, in every test.

## The end-to-end golden diff is mandatory

**MUST: have a byte-exact end-to-end test against an independent golden model,
and keep it green.**

- The model is Python + numpy, expressed directly from the specification, and
  used **both** to seed inputs and to score outputs.
- The comparison is byte-for-byte on the emitted packet — not field-by-field,
  not "looks right".

This test is the only thing that pins byte order, rounding, and field placement
to the specification. Per-module tests cannot do it: each one generates its own
self-consistent data and validates against itself, so a design that is
consistently wrong passes all of them. That is precisely how the case study's
lane byte-order bug survived every unit test and was caught here.

Reference:
[`vecavg_golden.py`](../examples/case-study-nf/tests/golden/vecavg_golden.py)
and [`test_vecavg_e2e.py`](../examples/case-study-nf/tests/cocotb/test_vecavg_e2e.py).

## Mandatory scenario axes

**MUST: exercise every one of these before synthesis.** Each corresponds to a
failure mode that only appears under it.

| Axis | What to drive | Catches |
|---|---|---|
| **Egress backpressure** | random `tready` on the sink | packet-atomicity loss, dropped beats, spurious `tlast` |
| **Gapped ingress** | random `tvalid` deassertion mid-packet | beat-counter FSMs that assume contiguity |
| **Variable memory latency** | `AxiSlave` with random 10–200-cycle per-burst latency | join logic that assumes fixed timing, undersized buffers |
| **Error injection** | `RRESP = SLVERR` on a random burst | error path; **and that the pipeline does not stall** |
| **Full / overflow** | hold a ring's tail static, overflow a command queue | drop accounting, status bits, and recovery after the condition clears |
| **State churn under traffic** | table upsert/delete while streaming | false hits and false misses across transitions |
| **Cold start** | empty state, then install, then re-send | the miss → install → hit round trip |
| **Sustained rate** | thousands of packets back to back | throughput, ordering, counter integrity at scale |

**SHOULD: run each scenario across ≥ 5 seeds** where randomisation is involved.
A single-seed pass on a randomised test is weak evidence.

## Counter conservation after every scenario

**MUST: check the conservation laws at the end of each scenario**, not only at
the end of the suite:

```
CNT_RX   == CNT_DROP_FILTER + CNT_HIT + CNT_MISS
CNT_HIT  == CNT_PROCESSED + CNT_HBM_ERR
CNT_MISS == notifications_written + CNT_NOTIFY_DROP
```

Near-zero cost, and they catch lost packets and double-counts that no output
comparison will notice — because a *missing* packet produces no wrong bytes to
compare.

## Per-interface checklists

**AXI-Stream (in):** line-rate good traffic; every filter/reject class;
gapped `tvalid`; downstream-full backpressure with no loss after it drains;
rejected packets' tails consumed so the stream stays frame-aligned.

**AXI-Stream (out):** exact byte map of the emitted packet; `tlast` on the
right beat; monotonic sequence fields with no skips over thousands of packets;
random `tready` preserving packet atomicity; an input gap mid-packet not
producing a spurious `tlast`.

**AXI4 master (memory):** single-burst correctness against a model memory;
maximum outstanding bursts on one ID returned in order; multiple channels
concurrent with drift permitted; variable latency; `RRESP` error injection with
the pipeline still running afterwards.

**AXI4 master (host writeback):** payload byte-exact against the host-side
struct; index/head advance; full condition dropping without a spurious write;
recovery when the consumer advances; clean backpressure when the slave stalls
AW/W.

**AXI-Lite slave:** write/readback on every RW register; RO registers ignore
writes; **atomic commit semantics** — scratch updates invisible until the commit
write, exactly one command captured, with the values present at the commit
cycle; reserved bits read zero.

**A stateful table:** insert/lookup/delete; lookup on empty; fill to capacity
and verify all; delete half and verify misses; concurrent update and lookup
without corruption; queue overflow flagged and counted.

## Two traps that look like design bugs

**MUST: warm up ~2600 cycles after reset before issuing table commands.** The
vendored cuckoo IP's `uram_bank.sv` clears its valid RAM one entry per cycle
after reset. Skip the warmup and early inserts are silently wiped, every lookup
misses, and the table looks broken when it is not. Allow settling time after an
upsert before the matching lookup too — the insert FSM is eventually consistent.

**MUST NOT: conclude a data-format bug from a test that generated its own
data.** If the golden model and the stimulus come from the same assumption, they
will agree while both being wrong. Derive stimulus from the specification.

## Before you synthesise

- [ ] Every module tested in its correct tier, exactly once.
- [ ] No hand-rolled AXI agents anywhere.
- [ ] Protocol monitors report zero violations.
- [ ] End-to-end byte-exact golden diff passes.
- [ ] All eight scenario axes exercised; randomised ones across ≥ 5 seeds.
- [ ] Conservation laws hold after every scenario.
- [ ] Table warmup respected.
- [ ] Anything still untested is **named in your report**, not left implied.
