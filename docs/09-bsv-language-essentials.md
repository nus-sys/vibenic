# BSV language essentials

The subset of Bluespec SystemVerilog that matters for writing packet-processing
logic here, plus the mistakes that generated BSV reliably makes. This is not a
language tutorial — it is the working set, and the traps.

The three pattern documents that follow ([10](10-bsv-dataflow-handshaking.md),
[11](11-bsv-packet-per-beat.md), [12](12-bsv-axi-transactions.md)) show these
constructs assembled into real designs. Read this first, then those.

## The model

A BSV design is a set of **rules** over state. A rule is *atomic*: it fires only
when all its explicit guard and all its **implicit conditions** hold, and when
it fires, all its actions happen in that one cycle. The compiler derives the
enable logic and the schedule.

The practical consequence, which is the whole reason to use BSV here: **you
never write ready/valid handshaking**. FIFO methods inject the conditions for
free (`first`/`deq` ⇒ not-empty, `enq` ⇒ not-full), so a pipeline stage is

```bsv
rule stage;
    let x <- toGet(inF).get;
    outF.enq(f(x));
endrule
```

and it self-throttles on both backpressure and starvation. Hand-rolling
handshake logic in BSV is fighting the language.

## Types

- `Bit#(n)`, `UInt#(n)`, `Int#(n)`, `Bool`, `Maybe#(t)`, `Tuple2..8`,
  `Vector#(n, t)`.
- `struct` / `union tagged`, with `deriving (Bits, Eq, FShow, Bounded)`.
- Numeric type parameters are types: `Bit#(kw)` where `kw` is `numeric type`.
  Convert to a value with `valueOf(kw)`; convert a literal to a type with
  `fromInteger`.
- **Provisos** are type constraints, written after the module/function header:
  `provisos (Bits#(t, sz), Add#(_x, 1, kw))`. The real ones are `Bits`, `Eq`,
  `Ord`, `Bounded`, `Literal`, `FShow`, `Add`, `Mul`, `Div`, `Log`, `Max`,
  `Min`. There is no `Stackable`, no `Queueable`, no `Streamable`.

> **Struct packing order: the FIRST field is the MOST significant bits.** This
> is the single most consequential typing fact in this corpus, because network
> bytes arrive in the *low* bytes of beat 0 — so a header overlay struct must
> list the network headers **last**. See [11](11-bsv-packet-per-beat.md).

## State

| Element | Behaviour |
|---|---|
| `mkReg(init)` | Ordinary register. Read-before-write within a cycle. |
| `mkRegU` | No reset. |
| `mkConfigReg` | Read does **not** conflict with a same-cycle write — the way to let an `always_ready` config port update a knob while the datapath samples it. |
| `mkCReg(n, init)` | *n* ports with defined intra-cycle ordering: port *i* sees port *i−1*'s write. |
| `mkDReg(default)` | **Reverts to its default the cycle after a write.** For single-cycle pulses only — not for a flag that must persist. |
| `mkWire` / `mkDWire(default)` | Intra-cycle broadcast between rules (e.g. an arbiter publishing its grant). `mkWire` adds an implicit condition; `mkDWire` does not. |
| `mkPulseWire` | Fire-and-forget event pulse. |
| `mkCounter` | Conflict-free `.up` / `.down` / `.value` — for bounding in-flight work. |

## Modules, interfaces, methods

```bsv
interface IfcThing #(numeric type dw);
    interface Put #(Bit#(dw)) in;
    interface Get #(Bit#(dw)) out;
    method Action configure (Bit#(32) v);
    method Bit#(32) status ();
endinterface

module mkThing #(Integer depth) (IfcThing #(dw))
    provisos (Add#(_d0, 1, dw));
    ...
endmodule
```

The provided interface is the **last** parenthesised argument. Module parameters
come first, in `#(...)`.

Method flavours: value method (combinational read), `Action` (state change),
`ActionValue#(t)` (both — bind with `<-`, never `=`).

Guards are written `if (...)` after the method signature:

```bsv
method Action push (T item) if (!full);      // correct
method Action push (T item) enable (!full);  // not a thing
```

## Get / Put / Client / Server

The universal wiring vocabulary:

- `Get#(t)` has exactly one method, `ActionValue#(t) get()`. It has **no**
  `first`, `peek`, or `notEmpty` — if you need to look without consuming, pass
  the `FIFOF` itself.
- `Put#(t)` has `Action put(t)`.
- `Server#(req, resp)` = `{ Put request; Get response }`; `Client` is the dual.
- `toGet(fifo)` / `toPut(fifo)` adapt a FIFO. `toGPServer(reqF, respF)` /
  `toGPClient(reqF, respF)` build the pair.
- `mkConnection(g, p)` generates the rule that moves one element per cycle when
  the producer can produce and the consumer can accept. `mkConnection(client,
  server)` wires both directions.

## FIFO flavours

Choosing wrong here costs latency, area, or timing — see
[10](10-bsv-dataflow-handshaking.md) for the full table. The short version:

| Module | Use |
|---|---|
| `mkFIFO` | 2-element default workhorse. |
| `mkLFIFO` | 1-element "loopy": allows a combinational producer→consumer dependency in one cycle. Use at interface boundaries and adapters. |
| `mkSizedFIFO(n)` | Register-based depth-*n* slack. |
| `mkSizedBRAMFIFO(n)` | Deep buffers in BRAM. |
| `mkFIFOF` | Exposes `.notEmpty` / `.notFull` / `.first` so you can branch on them in a guard — needed for arbitration and drain-when-idle. |

> `enq` is a pure `Action`, not an `ActionValue#(Bool)`. There is no success
> flag; the implicit condition prevents the rule from firing when full.

## Scheduling attributes

Escape hatches, each legitimate in a narrow case:

- `(* fire_when_enabled, no_implicit_conditions *)` — assert the rule has no
  implicit conditions and must fire every cycle. Monitor/debug taps and config
  sampling only.
- `(* aggressive_implicit_conditions *)` — let `bsc` hoist implicit conditions
  out of `if`/`case` branches so the rule can still fire when only one branch is
  reachable. Apply to rules that conditionally read different FIFOs.
- `(* preempts = "ruleA, ruleB" *)` — if A is enabled it blocks B this cycle.
  The explicit way to give a cleanup or completion path priority.
- `(* split *)` on an `if` — emit a separate rule per branch so the branches
  schedule independently.
- `(* descending_urgency = "..." *)` — order two rules that write the same state.

> Two rules writing the same state conflict, and `bsc` will pick one by its own
> urgency heuristic. **Make the choice explicit.** Relying on default ordering
> is how a design passes simulation and then behaves differently after an
> unrelated edit changes the schedule.

## Wrapping Verilog: `import "BVI"`

The mechanism behind [`../libs/bsv/CachedCuckoo.bsv`](../libs/bsv/CachedCuckoo.bsv).
You declare the Verilog module's ports, map them onto BSV methods, and state the
scheduling relationships between those methods:

```bsv
import "BVI" CachedCuckoo =
    module mkCachedCuckooV #(Integer cacheSize, ...) (IfcCachedCuckooV#(kw, vw));
        default_clock clk (clk, (*unused*)CLK_GATE);
        default_reset rst (rstn);
        parameter KEY_WIDTH = valueOf(kw);
        method put_lookup (luKey) enable (luEna);
        method (*reg*)luRes get_lookup () ready (luRdy);
        schedule (put_update, get_lookup) CF (put_lookup);
    endmodule
```

The `schedule` clauses are a *promise you are making to the compiler*. Getting
them wrong produces a design that simulates and then fails in hardware.

A BVI module also changes how you simulate it: Bluesim cannot execute the
Verilog, so any testbench whose closure includes a BVI import must go through
Verilog + cocotb. See [13](13-simulation-frameworks.md).

## Things generated BSV gets wrong

Check yourself against this list before compiling.

| Wrong | Right |
|---|---|
| `foldr :: (a -> b -> b) -> b -> List a -> b` (Haskell-style signature) | `function b foldr(function b f(a x, b acc), b seed, List#(a) xs);` |
| `class Connectable a b where` | `typeclass Connectable#(type a, type b); ... endtypeclass` |
| `let x = someActionValue;` | `let x <- someActionValue;` |
| `provisos (Stackable#(a))` | Only real provisos exist: `Bits`, `Eq`, `Add`, `Log`, … |
| `Bool ok <- fifo.enq(x);` | `fifo.enq(x);` — `enq` is an `Action` |
| `fifo.notEmpty()` on a `FIFO#(t)` | Only `FIFOF#(t)` has it |
| `myTuple[0]` or `myTuple.f1` | `tpl_1(myTuple)`, or `match {.a, .b} = myTuple;` |
| `module mkX provides (Ifc);` | `module mkX (Ifc);` |
| `method Action f(T x) enable (cond);` | `method Action f(T x) if (cond);` |
| `DReg` used to hold a status flag | `DReg` reverts to default next cycle; use `Reg` |
| first struct field = LSB | first field = **MSB** |
| `TLMRecvIFC#(4, 32, 512, 8, 0)` | `TLMRecvIFC#(TLMRequest#(...), TLMResponse#(...))` — some interfaces take *types*, not numeric widths; check the definition |
| `.peek()` / `.first()` on a `Get#(t)` | `Get` has only `get()` |

Two more, specific to this corpus and each caught only by an end-to-end test:

- **`RegTwo` ports are Conflict-Free in BSV**, with the conflict resolved in
  hardware by fixed priority. The compiler will not warn you. It bypasses normal
  atomicity — use with caution or not at all.
- **Arithmetic on network-order lanes needs an explicit byte swap.** A 16-bit
  slice of a beat is in network byte order; its signed value is
  `unpack(bswap16(slice))`, not `unpack(slice)`. Per-module tests that generate
  their own self-consistent little-endian vectors cannot see this bug. See
  [11](11-bsv-packet-per-beat.md) and
  [`../prompts/02-bsv-coding-clamp.md`](../prompts/02-bsv-coding-clamp.md).

## Compiling

```bash
bsc -u -elab -p <testdir>:<srcdir>:<libdir>:%/Libraries:… \
    -bdir build -info-dir build -simdir build  src/Top.bsv          # typecheck
bsc -verilog … -vdir verilog -g mkTop src/Top.bsv                   # -> Verilog
bsc -sim    … -g mkSimTop test/SimTop.bsv && bsc -sim -e mkSimTop   # -> Bluesim
```

`%` in a `-p` path expands to the bsc library root, which keeps the flags
install-independent. The working invocation, with the library paths this corpus
needs (`Bus`, `Flute_Addon`, `AMBA_TLM3/{TLM3,Axi,Axi4}`), is in
[`../examples/case-study-nf/Makefile`](../examples/case-study-nf/Makefile).
