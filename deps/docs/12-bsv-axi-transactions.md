# BSV AXI / TLM transaction handling

The transactors and bus presets these patterns use are
[`../libs/bsv/Axi4Utilities.bsv`](../libs/bsv/Axi4Utilities.bsv) and
[`../libs/bsv/Axi4BusesDefines.bsv`](../libs/bsv/Axi4BusesDefines.bsv); the
worked AXI master is
[`HBMReadEngine.bsv`](../examples/case-study-nf/src/HBMReadEngine.bsv) and the
worked AXI-MM writer is
[`NotifyEngine.bsv`](../examples/case-study-nf/src/NotifyEngine.bsv).

See also [10 — Dataflow and FIFO handshaking](10-bsv-dataflow-handshaking.md) and
[11 — Per-beat packet processing](11-bsv-packet-per-beat.md).

## Layering: speak TLM3, not raw AXI

Design logic emits **TLM3** `TLMRequest` (`Descriptor | Data`) and consumes
`TLMResponse`. A transactor converts TLM ↔ AXI4 channels. You build/consume two
FIFOs; a library module turns them into an AXI master port.

## Bus parameter presets ([`../libs/bsv/Axi4BusesDefines.bsv`](../libs/bsv/Axi4BusesDefines.bsv))

Parameter tuple is `(idW, addrW, dataW, lenW, userW)`:

- HBM: `6, 33, 512, 8, 0` — 33-bit addr = **512 MB per pseudo-channel**, data
  512-bit, **bursts must be ≤ 8 beats**.
- XDMA bypass: `4, 64, 512, 8, 0`. DDR4 = same preset as HBM.

Typedefs you use: `HbmTlmReq_t` / `HbmTlmResp_t`, `HbmTlmReqDesc_t`
(= `RequestDescriptor`), `HbmAxiMasterIfc`, `HbmTlmSendIfc`, `DdrTlm*` aliases.

## Building an AXI master from a FIFO pair (standard idiom)

```bsv
FIFO #(DdrTlmReq_t)  memreq_obuf  <- mkLFIFO;
FIFO #(DdrTlmResp_t) memresp_ibuf <- mkLFIFO;
// expose as TLM send iface ...
interface DdrTlmSendIfc ddr_tlm = getTlmSendFromFifoPair(memreq_obuf, memresp_ibuf);
// ... or make the AXI master directly:
//   mkAxi4MasterFromFifoPair(reqF, respF, maxInFlight)   -> HbmAxiMasterIfc
//   mkAxi4MasterFromTlm(tlmSendIfc, maxFlight)            -> HbmAxiMasterIfc
```

N HBM channels at once:
`Vector#(8,HbmAxiMasterIfc) m <- zipWith3M(mkAxi4MasterFromFifoPair, reqFs, respFs, replicate(2));`
when a design fans across HBM pseudo-channels. Expose at top as
`interface Vector axi_hbm = m;`. Multiple TLM masters → one port via
`mkDdrTlmXbar` (`mkConnection(blk.ddr_tlm, xbar.msts_in[i])`).

## Issuing a WRITE (`PrstKvsValBuf.bsv:axi_wr_valbeat`)

Always start from `defaultValue` and set only what you need (prevents stale
`b_length`/`b_size` bugs):

```bsv
DdrTlmReqDesc_t d = defaultValue;
d.command        = WRITE;
d.addr           = addr;
d.data           = beat.data;
d.byte_enable    = tagged Specify beat.keep;   // strobe
d.b_size         = BITS512;
d.b_length       = nbeats - 1;                 // AXI len = beats-1
d.transaction_id = 0;
memreq_obuf.enq(tagged Descriptor d);
// subsequent beats of a burst:
memreq_obuf.enq(tagged Data RequestData {
    data: beat.data, byte_enable: tagged Specify beat.keep,
    transaction_id: 0, is_last: True });
```

A beat-counter Reg tracks position within the burst (descriptor for beat 0,
`Data` for the rest).

## Issuing a READ + handling responses

```bsv
DdrTlmReqDesc_t d = defaultValue;
d.command = READ; d.addr = addr; d.b_length = numbeat-1; d.b_size = BITS512;
memreq_obuf.enq(tagged Descriptor d);          // descriptor only
```

Responses arrive as `TLMResponse`. Discriminate by
`memresp_ibuf.first.command`:

- `command == READ` → `tlmresp.data` is a data beat; route in
  `do_read_val_cplflush`.
- otherwise → write completion; just `deq` in `do_write_cplflush`.

Split read vs write completion into separate rules keyed on `.command` so they
schedule independently.

## Burst chunking is mandatory for HBM (≤ 8 beats)

Keep `axi_nbrem` and `memaddr`; per step issue `min(rem, max_axi_burst)`,
advance `memaddr += beats * axi_beat_nb`, loop until 0. Constants:
`max_axi_burst = 8`, `axi_beat_nb = 64` (512 bits / 8). The shape is a start
rule plus a burst-continuation rule that re-issues until the span is covered.

## Response reassembly across bursts

Record the requested beat-count per outstanding read in a sized FIFO
(`axi_beatcnt_rdfifo`), then regenerate the stream `last` when the running
count hits 0. The inverse adapter `mkTLMBurstReadExpander`
([`../libs/bsv/Axi4Utilities.bsv`](../libs/bsv/Axi4Utilities.bsv)) expands one bursty READ descriptor into single-beat
descriptors and re-marks `is_last` on the responses — reusable when a slave
cannot do native bursts.

## Knobs & discipline

- `transaction_id` / `id` width: leave 0 for a single outstanding class; tag to
  correlate when interleaving.
- `max_flight` arg to the transactor sets outstanding depth (e.g.
  `mkAxi4MasterFromTlm(blk.ddr_tlm, 32)`).
- Slave side mirrors this: `mkAxi4SlaveFromFifoPair` /
  `getTlmRecvFromFifoPair` ([`../libs/bsv/Axi4Utilities.bsv`](../libs/bsv/Axi4Utilities.bsv)) —
  the basis of a behavioural memory slave for simulation.
- Treat each TLM FIFO as a normal dataflow FIFO — all the
  handshaking/scheduling rules in
  [10 — Dataflow and FIFO handshaking](10-bsv-dataflow-handshaking.md) apply (e.g.
  `aggressive_implicit_conditions` on the response rule).
