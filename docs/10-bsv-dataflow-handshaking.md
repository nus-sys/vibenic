# BSV dataflow: FIFO-based automatic rule handshaking

Patterns distilled from the **kvs_cuckoo** reference design (pinned in
[`../PROVENANCE.md`](../PROVENANCE.md)). Bare `src/…` paths below name files in
*that* repository, cited for attribution; the reusable modules they describe are
vendored here in [`../libs/bsv`](../libs/bsv), and the in-corpus code that shows
the same patterns assembled is
[`../examples/case-study-nf/src`](../examples/case-study-nf/src).

See also [11 — Per-beat packet processing](11-bsv-packet-per-beat.md) and
[12 — AXI / TLM transactions](12-bsv-axi-transactions.md).

## Core principle: handshaking is implicit, never hand-wired

A BSV rule is atomic and fires only when **all** its implicit conditions hold.
FIFO methods inject those conditions for free:

- `fifo.first` / `fifo.deq` ⇒ implicit *notEmpty*
- `fifo.enq(x)` ⇒ implicit *notFull*

So a pipe stage is just
`rule s; let x <- toGet(inF).get; outF.enq(f(x)); endrule` — it self-throttles
on both back-pressure and starvation. **Never write ready/valid by hand**;
express dataflow as rules over FIFOs and let the scheduler build the handshake.

## The elemental primitives

- `toGet(fifo)` / `toPut(fifo)` adapt a FIFO to `Get#(t)` / `Put#(t)`.
- `mkConnection(g, p)` generates a rule moving one element/cycle when `g` can
  produce and `p` can accept — the atom of all wiring.
- `Server#(req,resp)` = `{ Put request; Get response }`; `Client` is the dual.
  Build with `toGPServer(reqF, respF)` / `toGPClient(reqF, respF)`.
  `mkConnection(client, server)` wires both directions.
- Cross-rule intra-cycle signalling: `mkDWire`/`mkWire` to broadcast a computed
  value within the same cycle (e.g. an arbiter publishing its grant),
  `PulseWire` for a fire-and-forget event pulse (e.g. a reset request).
- `mkCounter` for in-flight accounting: conflict-free `.up` / `.down` /
  `.value`, used to bound outstanding ops (`otf_cnt`, `prst_cnt` in
  `src/PrstKvsEthPl.bsv`).
- `mkConfigReg` for runtime knobs: read does not conflict with same-cycle
  write, so an `(* always_ready *) Put` config port can update it while the
  datapath samples it (see `src/PrstKvsTop.bsv` `do_config`).

## FIFO flavor selection (matters for latency/area/timing)

| Module | Use |
|---|---|
| `mkFIFO` | 2-elem pipeline default workhorse; enq+deq same cycle when neither full nor empty |
| `mkLFIFO` | 1-elem "loopy"; allows back-to-back with a combinational producer→consumer dep in one cycle. Used at interface boundaries / adapters (`sbuf` in [`../libs/bsv/AxisGetPut.bsv`](../libs/bsv/AxisGetPut.bsv)) |
| `mkSizedFIFO(n)` | register-based depth-n slack buffer |
| `mkSizedBRAMFIFO(n)` / `mkSizedBRAMFIFOF` | deep buffers in BRAM — value buffers, pre-persist queues, reorder windows |
| `mkFIFOF` | exposes `.notEmpty`/`.notFull`/`.first` so you can branch on them in rule guards (needed for arbitration / drain-when-idle) |

## Buffered connections (timing & pipelining)

[`../libs/bsv/BufferedConnection.bsv`](../libs/bsv/BufferedConnection.bsv):

- `mkBufGPConnection(get, put, nStages)` — inserts N `mkFIFO` stages between a
  Get and a Put. Used everywhere in `src/PrstKvsTop.bsv` to add slack and break
  long paths between blocks.
- `mkBufCSConnection(client, server, nStages)` — same, both directions of a
  Client/Server.
- `mkCountedBufGPConnection(get, put, nStages, cntReg)` — taps a counter on the
  traffic for debug/flow stats.

Choosing the stage count is the standard knob for closing timing between large
blocks without touching their logic.

## Scheduling attributes (the controlled escape hatches)

- `(* fire_when_enabled, no_implicit_conditions *)` — assert the rule has no
  implicit conditions and must fire every cycle. For pure monitor/debug taps
  and config sampling only (`mkDebugPutSink` consumers, `do_config`,
  `do_monitor`).
- `(* aggressive_implicit_conditions *)` — let bsc hoist nested implicit
  conditions out of `if`/`case` branches so the rule can still fire when only
  one branch is reachable. Apply to rules that conditionally read different
  FIFOs (e.g. `do_fwd_eth_in`, `do_arb_eth_out` in [`../libs/bsv/EtherDefines.bsv`](../libs/bsv/EtherDefines.bsv)).
- `(* preempts = "ruleA, ruleB" *)` — if A is enabled it blocks B that cycle
  (asymmetric static priority). Used for cleanup/reinstate vs normal path:
  `do_reinst` preempts `do_subm_req` in [`../libs/bsv/CachedCuckoo.bsv`](../libs/bsv/CachedCuckoo.bsv);
  `do_tx_wr_cpl` preempts the lookup-start + rx-init group in
  `src/PrstKvsEthPl.bsv`.
- `(* split *)` on an `if` — emit a separate rule per branch so branches
  schedule independently (`do_arb_eth_out`).
- Two rules writing the same state conflict; bsc picks one by urgency. Make it
  explicit with `preempts`/`descending_urgency` rather than relying on the
  default.

## Idioms worth copying

- **Self-draining sink**: when a response is unused,
  `rule flush; let _ <- srv.response.get; endrule` (see
  `flush_htbl_valdel_rsp` in `src/PrstKvsTop.bsv`). Keeps the producer from
  stalling.
- **Manual round-robin arbiter** (`src/PrstKvsValBuf.bsv` `do_arb_rr`): a
  `last_grant` Reg + `case` rotates priority; the decision is published on an
  `arb_grant` DWire; consumer rules are guarded by `arb_grant == X`. One
  arbiter rule, one consumer rule per source, no structural mux.
- **Generic mux/demux** ([`../libs/bsv/GPMux.bsv`](../libs/bsv/GPMux.bsv)): `mkGPMuxRR` / `mkGPMuxFP` give
  `Vector#(n, Put)` → `Get` (and `mkGPDemux*` the dual) over bsc-contrib
  `Arbitrate`. Two-rule pattern: a `fire_when_enabled` rule raises arb
  requests, an `aggressive_implicit_conditions` rule forwards the granted FIFO.
- **Inline instrumentation without breaking dataflow**: wrap a FIFO in a module
  that re-exposes the `FIFO` interface but counts in `enq`/`deq`
  (`mkPktLenProbe` in `src/PrstKvsEthPl.bsv`); or
  `mkGetWithDebugProbe`/`mkPutWithDebugProbe` ([`../libs/bsv/DebugPutSink.bsv`](../libs/bsv/DebugPutSink.bsv)) which tee
  every token to a `BVI` debug sink.
- **Counter-bounded admission**: gate the accepting rule on
  `inflight.value < limit` and `.up` on accept / `.down` on completion —
  backpressure for everything else falls out of FIFO fullness automatically.

## Anti-patterns to avoid

- Adding a buffer between a cuckoo `drain.get` and its `update.put` — the
  victim-reinsert path must be a single atomic hop (explicit comment in
  `src/PrstKvsEthPl.bsv` `do_ccht_reinst`).
- Relying on default rule ordering when two rules touch shared state — always
  pin with `preempts`.
- Using `mkFIFO` where a combinational producer needs same-cycle consumption —
  use `mkLFIFO` at those boundaries.
