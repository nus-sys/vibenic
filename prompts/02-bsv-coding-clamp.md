# BSV coding clamp

**Dataflow logic on the packet stream is written in BSV.** Not in hand-written
Verilog, not in HLS. The reason is narrow and practical: the correctness
property that matters most here — that every stage self-throttles correctly
under backpressure and starvation — falls out of BSV's rule semantics for free,
and is exactly what hand-written RTL gets wrong in ways that survive simulation.

Language reference: [`../docs/09-bsv-language-essentials.md`](../docs/09-bsv-language-essentials.md).
Patterns: [10](../docs/10-bsv-dataflow-handshaking.md),
[11](../docs/11-bsv-packet-per-beat.md),
[12](../docs/12-bsv-axi-transactions.md).

## Dataflow

**MUST: never hand-wire ready/valid.** Express dataflow as rules over FIFOs and
let the scheduler build the handshake. `first`/`deq` gives you not-empty,
`enq` gives you not-full; a pipe stage is

```bsv
rule s; let x <- toGet(inF).get; outF.enq(f(x)); endrule
```

and it is already correct under both backpressure and starvation. If you find
yourself writing a `valid` register and a `ready` guard by hand, stop — you are
reimplementing the compiler and you will get it subtly wrong.

**MUST: use `mkConnection`, `Get`/`Put`/`Server`/`Client` for inter-block
wiring.** They are the vocabulary the whole library speaks.

**SHOULD: pick the FIFO flavour deliberately.**

| Situation | Module |
|---|---|
| Ordinary pipeline stage | `mkFIFO` |
| Combinational producer needs same-cycle consumption (adapters, interface boundaries) | `mkLFIFO` |
| Slack buffer, shallow | `mkSizedFIFO(n)` |
| Deep buffer (payloads, reorder windows) | `mkSizedBRAMFIFO(n)` |
| Guard needs `.notEmpty` / `.notFull` / `.first` (arbitration, drain-when-idle) | `mkFIFOF` |

Using `mkFIFO` where the consumer must see the value in the producing cycle
deadlocks a stage that would work with `mkLFIFO`.

**SHOULD: use `mkBufGPConnection(get, put, n)` to break a long path between
blocks** before restructuring their logic. It is the cheapest timing knob
available and it does not change behaviour.

## Scheduling

**MUST: pin the order when two rules touch the same state.** Two such rules
conflict, and `bsc` picks one by its own urgency heuristic. Make it explicit with
`(* preempts = "a, b" *)` or `(* descending_urgency = ... *)`. Relying on the
default is how a design passes simulation and then changes behaviour after an
unrelated edit perturbs the schedule.

**SHOULD: give the completion/drain path priority over the accept path.** Under
load you want the pipeline draining, not admitting more work.

**SHOULD: use the attribute that matches the reason.**

| Attribute | Legitimate use |
|---|---|
| `(* aggressive_implicit_conditions *)` | A rule that conditionally reads different FIFOs and must still fire when only one branch is reachable. |
| `(* fire_when_enabled, no_implicit_conditions *)` | Monitor/debug taps and config sampling only. **Not** a way to silence a scheduling warning. |
| `(* split *)` on an `if` | Let branches schedule independently. |
| `(* preempts *)` | Asymmetric static priority, as above. |

Reaching for `fire_when_enabled` to make a warning go away asserts something
about the design that is probably false.

## Packet processing

**MUST: order header-overlay structs with the network headers LAST.** BSV packs
the first field into the MSBs; network bytes arrive in the low bytes of beat 0.
So:

```bsv
typedef struct {
    Bit#(64) user_ts; Bit#(32) rsvd; Bit#(32) resp;
    Bit#(8)  opcode;  Bit#(8)  magic;
    UdpIpEthHeader nethdr;      // <-- last field = first wire bytes
} PktHdr deriving (Bits, Eq, FShow);
```

and `UdpIpEthHeader` itself nests `{ udp; ip; eth; }` with `eth` last. Parse
beat 0 with `unpack(beat.data)` (or `unpack(truncate(...))` when the struct is
narrower than the bus). Constants are stored little-endian
(`ipv4EtherType = 16'h0008`).

**MUST: byte-swap lanes before signed arithmetic, and again on the way out.**
A 512-bit beat is little-endian relative to the wire, so a 16-bit lane slice
`beat.data[i*16+15 : i*16]` holds the value in **network byte order**. Its true
signed value is `unpack(bswap16(slice))`, not `unpack(slice)`.

> This bug was invisible to every per-module Bluesim test in the case study,
> because each generated its own self-consistent little-endian vectors and
> checked them against itself. It was caught only by the end-to-end byte-exact
> diff against the numpy golden model. That test is the *only* thing that pins
> data-format decisions to the specification — treat keeping it green as
> non-negotiable. Header fields need the same treatment (`bswap32` for 32-bit
> fields); values you merely echo unchanged do not.

**SHOULD: use the beat-counter + state-enum FSM skeleton** from
[11](../docs/11-bsv-packet-per-beat.md), with the universal tail
`if (beat.last) begin state <= IDLE; beatcnt <= 0; end else beatcnt <= beatcnt+1;`,
and exactly one beat consumed per rule firing. It keeps the FSM beat-accurate,
which is what makes gapped-`tvalid` and short-packet cases behave.

**MUST: consume the remaining beats of a rejected packet.** A dropped packet
whose tail is left in the stream desynchronises everything after it. Have an
explicit flush rule (`state == IDLE && beatcnt > 0`).

**SHOULD: trust `tuser[15:0]` for length.** The shell has already
length-policed the packet; re-deriving length from `tkeep` is work you do not
need to do. Apply `axis_mask_keep` before hashing or storing a partial last
beat.

## AXI from BSV

**MUST: chunk HBM bursts to ≤ 8 beats.** The bus preset says so and the
controller enforces it. Keep a remaining-beats counter and an address, issue
`min(rem, 8)` per step, advance by `beats × 64`, loop.

**MUST: start every TLM descriptor from `defaultValue`** and set only what you
need. Building one field-by-field leaves stale `b_length`/`b_size` from the
previous use — a bug that produces plausible-looking wrong transfers.

```bsv
DdrTlmReqDesc_t d = defaultValue;
d.command = READ; d.addr = addr; d.b_length = nbeats - 1; d.b_size = BITS512;
```

Note `b_length` is `beats − 1` (AXI convention).

**SHOULD: split read-completion and write-completion into separate rules keyed
on `.command`**, so they schedule independently.

**SHOULD: pin one ARID per channel** when you want in-order responses per
channel — that is what makes a positional join legal.

## Anti-patterns

- **Do not buffer between a cuckoo table's `drain.get` and its `update.put`.**
  The victim-reinsert path must be a single atomic hop.
- **Do not skip the ~2600-cycle post-reset warmup** before issuing table
  commands. See [`../docs/08-bsv-library-catalog.md`](../docs/08-bsv-library-catalog.md).
- **Do not use `DReg` for a flag that must persist.** It reverts to its default
  the next cycle.
- **Do not rewrite a library block.** See
  [01](01-architecture-and-decomposition.md).

## Instrumentation

**SHOULD: instrument without perturbing dataflow.** Wrap a FIFO in a module that
re-exposes the `FIFO` interface and counts in `enq`/`deq`, or use
`mkGetWithDebugProbe` / `mkPutWithDebugProbe`
([`../libs/bsv/DebugPutSink.bsv`](../libs/bsv/DebugPutSink.bsv)). Adding a
counter should not change the schedule.

## Before you compile

- [ ] No hand-written ready/valid anywhere.
- [ ] FIFO flavours chosen deliberately, `mkLFIFO` at adapter boundaries.
- [ ] Every same-state rule pair has an explicit `preempts` or
      `descending_urgency`.
- [ ] Header structs list network headers last.
- [ ] Every lane that enters signed arithmetic is `bswap`-ed in and out.
- [ ] Rejected packets have their tail beats flushed.
- [ ] HBM bursts ≤ 8 beats; descriptors start from `defaultValue`.
- [ ] You checked yourself against the hallucination table in
      [`../docs/09-bsv-language-essentials.md`](../docs/09-bsv-language-essentials.md).
