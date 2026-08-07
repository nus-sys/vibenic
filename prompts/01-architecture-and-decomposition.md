# Architecture and decomposition

Turning a specification into modules. The goal is a design you can test in
pieces, reason about under backpressure, and floorplan — in that order.

## Compose, do not microarchitect

**MUST: check [`../docs/08-bsv-library-catalog.md`](../docs/08-bsv-library-catalog.md)
before writing any block that sounds generic.** A mux, an arbiter, an AXI
master, an AXI-Stream adapter, a CAM, a hash table, a pipelined connection — all
exist, validated. Rewriting one is not neutral: it is new, unproven logic in a
place where proven logic was available, and it will be a review finding.

The library boundary is also where the risk boundary sits. Composition of
validated blocks fails in ways you can see in simulation; novel microarchitecture
fails in ways you discover after a 3-hour build.

## The default shape: a FIFO-decoupled stage chain

Unless the problem demands otherwise, build a straight producer→consumer chain
where **the stage boundaries are FIFOs**:

```
 ingress ──► [S1] ──FIFO──► [S2] ──FIFO──► [S3] ──► ... ──► egress
                              │
                        (side paths: lookup, memory, notification)
```

This shape is not arbitrary. It gets you, for free:

- **Backpressure end-to-end.** Every stage self-throttles on its input and
  output FIFOs; nothing needs a flow-control protocol.
- **Testable cut-points.** Each FIFO is an interface you can drive and observe
  in isolation.
- **A timing knob that does not touch logic.** `mkBufGPConnection(get, put, n)`
  inserts pipeline stages between blocks to break a long path. See
  [`../docs/10-bsv-dataflow-handshaking.md`](../docs/10-bsv-dataflow-handshaking.md).

A worked eight-stage decomposition, with the payload crossing each FIFO written
down explicitly, is in
[`../examples/case-study-nf/spec/refarch.md`](../examples/case-study-nf/spec/refarch.md).

## Pin the interfaces before writing the stages

**MUST: write down what crosses each boundary before implementing either side.**
Type, width, ordering guarantee, and what happens on backpressure. This is what
makes parallel implementation possible and per-stage testing meaningful.

**SHOULD: expose each inter-stage interface as a real module boundary.** Merging
two stages is legitimate when the split buys nothing — but a merged stage hides
an interface, and a hidden interface cannot be unit-tested. You then depend
entirely on end-to-end tests to localise its bugs, which is a much worse place
to debug from. Merge deliberately, not by accident.

## Ordering and joins

Decide the ordering guarantee explicitly and write it down. The common and
easiest choice is **egress order = ingress order, no reordering**, because it
lets downstream stages join side-channel results positionally instead of
carrying tags.

That only works if every side path preserves order too:

- `mkCachedCuckooServer` returns responses **in request order** — so a lookup
  result can be popped alongside the packet it belongs to.
- An AXI read channel is in-order **per ID**. Pin one ARID per channel and each
  channel's R stream stays in order; drift *between* channels is fine as long as
  the join is per-channel.

If you need out-of-order completion, you need tags and a reorder structure —
say so, and budget for it, rather than discovering it in integration.

## Sizing

**MUST: size for a stated number of in-flight packets and write the number
down.** Pick `N_INFLIGHT` from the latency you must cover — memory round-trip,
lookup latency — times the arrival rate, then size every buffer on the path to
it. Under-sizing shows up as throughput collapse under exactly the conditions
your unit tests do not create.

The case study uses `N_INFLIGHT = 32` with per-FIFO depths tabulated in its
reference architecture; header FIFOs are registers, payload and response FIFOs
are BRAM (`mkSizedBRAMFIFO`).

**SHOULD: bound admission explicitly** where a stage can otherwise accept
unbounded work: gate the accepting rule on `inflight.value < limit`, `.up` on
accept, `.down` on completion. Everything downstream then backpressures
naturally.

## Design the error path with the happy path

**MUST: decide what happens on every abnormal event before implementing the
normal one.** For each: what is dropped, what is counted, and — critically —
**does the pipeline stall?**

The standard answers:

| Event | Behaviour |
|---|---|
| Malformed / filtered packet | drop, count, no further action |
| Lookup miss | drop, count, notify the host if the spec says so |
| Memory error (`RRESP != OKAY`) | suppress that packet's result, count, **continue without stalling** |
| Queue or ring full | drop, count, set a status bit |

"Continue without stalling" is the hard one: it means draining the sibling
buffers that already hold that packet's other pieces. The *mechanism* is yours;
the *observable* — one suppressed result, the right counter increments, no stall
— is the contract.

## Counters are a design requirement

**MUST: instrument so that conservation laws hold and are checkable.** Not
telemetry — a correctness mechanism:

```
CNT_RX   == CNT_DROP_FILTER + CNT_HIT + CNT_MISS
CNT_HIT  == CNT_PROCESSED + CNT_HBM_ERR
CNT_MISS == notifications_written + CNT_NOTIFY_DROP
```

These catch lost packets, double-counts, and silent drops at near-zero cost, and
they are checkable after *every* test scenario. Design the counters so the sums
close by construction; if a law does not hold, you have a real bug, not a
counting bug.

## Control plane

**SHOULD: keep the host as the owner of policy state** (table contents,
addresses, ring geometry) and the device as the owner of mechanism (lookup,
memory access, arithmetic, sequence numbers). It keeps the device simple and
makes the control path a register map rather than a protocol.

**MUST: make multi-register updates atomic.** A table entry spanning several
32-bit registers needs a commit bit: the host writes scratch registers, then
writes `CMD` with `commit=1`, and the device snapshots *all* scratch atomically
on that write and enqueues one command. Without it, the device can act on a
half-written entry. Give the command queue a defined depth, an overflow status
bit, and a drop counter.

Worked example:
[`CtrlRegs.bsv`](../examples/case-study-nf/src/CtrlRegs.bsv).

## Where the shell constrains you

- One clock domain at 240 MHz ([`../docs/04-clocking-and-reset.md`](../docs/04-clocking-and-reset.md)).
  Slower is free; faster requires a shell rebuild.
- No external memory on the boundary — an HBM design instantiates its own
  controller and pays for it on every build
  ([`../docs/07-vendored-ip-catalog.md`](../docs/07-vendored-ip-catalog.md)).
- Two egress lanes, routed by `tdest`, with the bypass trap
  ([`../docs/02-rp-boundary-contract.md`](../docs/02-rp-boundary-contract.md)).
- 8-beat maximum HBM burst
  ([`../docs/12-bsv-axi-transactions.md`](../docs/12-bsv-axi-transactions.md)).

Do the throughput arithmetic before committing to a structure. At 240 MHz a
512-bit stream carries ~15.4 GB/s; a 576-byte packet is 9 beats. If a stage
needs more cycles per packet than the arrival interval allows, no amount of
timing closure will save it.

## Before you write code

- [ ] Every stage named, with its responsibility in one sentence.
- [ ] Every inter-stage payload written down.
- [ ] Ordering guarantee stated, and every side path checked against it.
- [ ] `N_INFLIGHT` chosen; every buffer sized to it.
- [ ] Error behaviour decided for each abnormal event, stall-freedom included.
- [ ] Counters chosen so the conservation laws close.
- [ ] Library blocks identified for everything generic.
- [ ] Throughput arithmetic done.
