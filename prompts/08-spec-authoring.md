# Spec authoring

Before generation starts, someone has to say what is being built. This is the
document structure that worked for the case study, and why it is split the way
it is.

The insight is that "what" and "how" have different lifetimes and different
authorities. A functional contract should survive a change of microarchitecture;
a reference architecture should survive a change of module names. Mixing them
into one document means every change touches everything, and an implementer
cannot tell which parts are negotiable.

## Three documents

| Document | Constrains | Authority |
|---|---|---|
| **Specification** | *what* — externally observable behaviour only | Binding. Every claim is testable from outside the design. |
| **Reference architecture** | *how* — stages, dataflow topology, sizing | Binding, but names and intra-stage structure are free. |
| **Test plan** | how it will be shown to be right | Binding on coverage, not on implementation. |

Worked examples, in full:
[`spec.md`](../examples/case-study-nf/spec/spec.md),
[`refarch.md`](../examples/case-study-nf/spec/refarch.md),
[`test-plan.md`](../examples/case-study-nf/spec/test-plan.md).

---

## The specification — externally observable behaviour

Contains **no** microarchitecture, no module breakdown, no coding style, no IP
usage, no floorplanning. If a statement cannot be checked by watching the
interfaces, it does not belong here.

```
1. Application story        one paragraph: what it does and why
2. Interfaces               role -> boundary -> contract, per port
3. Data formats             wire layout, memory layout, byte order, alignment
4. Observable behaviour     per-input, ordered: filter, lookup, act, error
                            + the conservation invariants
5. Control plane            the complete register map
6. Host-facing structures   ring entries, descriptors, C structs
7. Performance targets      with thresholds
8. Out of scope             explicitly
9. Fixed defaults           decisions taken so nobody re-litigates them
```

Sections that earn their place:

**§3 Data formats — be pedantic.** Byte offsets, field widths, byte order,
alignment, element ordering within a beat. "int16 × 256, big-endian,
lane-major, beat 1 = elements 0–31" is the level of detail required. Ambiguity
here produces a design that passes every unit test and fails the golden diff —
the case study's byte-order bug lived in exactly this gap.

**§4 Observable behaviour — write the invariants down.** Not just the happy
path: for each abnormal event, what is dropped, what is counted, and whether the
pipeline stalls. Then state the conservation laws as part of the contract:

```
CNT_RX   == CNT_DROP_FILTER + CNT_HIT + CNT_MISS
CNT_HIT  == CNT_PROCESSED + CNT_HBM_ERR
CNT_MISS == notifications_written + CNT_NOTIFY_DROP
```

These are checkable after every scenario and catch a large class of bugs at
near-zero cost.

**§5 Control plane — the complete map**, offset by offset, with RO/RW marked and
commit semantics spelled out. A partial register map guarantees invention.

**§8 Out of scope — say it.** "No IPv6, no fragmentation, no multi-queue, no
dynamic eviction, no checksum recomputation on egress." Absent, these become
speculative features nobody asked for.

**§9 Fixed defaults — decide, don't leave open.** "Sequence number is global,
32-bit, monotonic, wraps at 2³²." "Notification entry is 32 bytes." Each of these
is a decision that would otherwise be made silently and differently by every
implementer and every test.

---

## The reference architecture — how much is fixed

State the ground rules first, so the boundary of freedom is unambiguous:

- **What is fixed:** the stage list, each stage's responsibility, and the
  **inter-stage interface contracts** — the payload crossing each FIFO. These are
  the testable cut-points.
- **What is free:** module names, intra-stage microarchitecture, connection
  idioms.
- **What merging costs:** stages may be merged, but a merged stage hides an
  interface and forfeits that boundary's unit-testability — covered thereafter
  only by end-to-end tests. Say this explicitly so the trade is made knowingly.

Then give:

1. A **dataflow diagram** showing the chain and the side paths.
2. A **table**: stage → responsibility → the interface contract at its output.
3. **Sizing**: `N_INFLIGHT` and a depth for every buffer.
4. **Error-path microarchitecture**: the observable is fixed, the mechanism is
   free.
5. **Pointers** to the given IP and scaffolding, so nothing gets re-authored.

Design guidance for filling this in: [01](01-architecture-and-decomposition.md).

---

## The test plan — keyed to stages, not to names

Because module names are free, tests bind to the reference architecture's
**inter-stage interfaces**. A stage the design exposes gets a per-stage test; a
stage it merges is recorded N/A and covered by the integration tests.

```
1. Purpose and approach     what is in and out of scope
2. Tooling stack            simulator, framework, agents, golden model
3. Per-stage tests          stage -> tier -> interface -> numbered cases
4. Top-level integration    harness, scenarios, conservation checks, pass criteria
5. Coverage                 targets and how measured
6. Out of scope
```

**§3 states the tier per stage and why** — pure logic to Bluesim, AXI-facing to
cocotb. See [04](04-simulation-mandates.md); the choice is forced by the
interface, not preference.

**§4 is where the real coverage lives.** Name the scenarios concretely (cold
start, single-flow line rate, multi-flow, mixed hit/miss, state churn under
traffic, error injection, egress backpressure, overflow recovery), the seed
count, and the pass criteria — including zero protocol violations from the
monitors and the conservation laws holding in every scenario.

---

## Writing checklist

- [ ] Every specification claim is checkable from outside the design.
- [ ] No microarchitecture in the specification; no external behaviour invented
      in the reference architecture.
- [ ] Byte-level data formats, including byte order and element ordering.
- [ ] Abnormal events enumerated with drop/count/stall behaviour.
- [ ] Conservation invariants stated as part of the contract.
- [ ] Complete register map, with commit semantics.
- [ ] Out of scope stated explicitly.
- [ ] Fixed defaults decided rather than left open.
- [ ] Reference architecture says what is fixed, what is free, and what merging
      costs.
- [ ] Sizing given as a number.
- [ ] Test plan binds to interfaces, not module names, and names its scenarios.
