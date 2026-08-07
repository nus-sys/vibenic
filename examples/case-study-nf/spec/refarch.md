# UDP Vector-Averaging NF — Reference Architecture

> *As authored for this design. Cross-references have been re-pointed to the
> DEPs corpus; the substance is unchanged. See
> [`../../../prompts/08-spec-authoring.md`](../../../prompts/08-spec-authoring.md)
> for why the design documents are split this way.*

Companion to [`spec.md`](spec.md). The spec says **what**; this says **how**, and following it is
part of conformance. It pins the **stage decomposition, the dataflow
(FIFO) topology, and buffer sizing**. It does **not** pin BSV module names, intra-stage structure, or
connection idioms — those are the agent's, guided by the coding-style helpers.

## Ground rules (how much is fixed)

- **Stages are fixed** (the eight below), with fixed responsibilities and fixed **inter-stage
  interface contracts** (the payloads crossing each FIFO). These interfaces are the testable
  cut-points.
- **Module names and intra-stage microarchitecture are free.** The agent may name modules anything and
  may structure the logic inside a stage however it likes. It **may merge or split** stages — but a
  merged stage that hides an inter-stage interface **forfeits that boundary's unit-testability** and
  is covered only by the end-to-end tests. To keep each boundary diagnosable, expose it as an
  observable module boundary.
- **Connection idioms are recommended, not mandated.** Use `Get#`/`Put#`/`Server#` and the library's
  `AXI4_Stream`/`AXI4_Lite`/HBM-master interface types per
  [`docs/10`](../../../docs/10-bsv-dataflow-handshaking.md)–[`12`](../../../docs/12-bsv-axi-transactions.md).
  The ref-arch names the interface *contracts*; the *style* lives in those documents.
- **Given IP / scaffolding is not re-authored.** The flow-table IP (`mkCachedCuckooServer`) and the
  HBM subsystem are provided — see
  [`docs/08`](../../../docs/08-bsv-library-catalog.md) for the table's contract and
  [`examples/bd/hbm-subsystem.tcl`](../../bd/hbm-subsystem.tcl) for the HBM instantiation.

## Stage decomposition (the pipeline)

A straight producer→consumer chain, order-preserving, FIFO-decoupled. Stage boundaries = the FIFOs.

```
 s_axis_ethrx0
     │
 [S1 Ingress] ── HeaderFIFO ─────────────────────────────┐
     │        ── PayloadFIFO ──────────────────┐          │
     │        ── Lookup req ─▶ [S2 FlowTable] ─ LookupRespFIFO ─┐
     │                                                     │    │
     └────────────────────────────────────────────────────┼────┼──▶ [S3 Dispatch]
                                                           (joins Header+Payload+LookupResp by order)
   [S3 Dispatch] ─ hit ─▶ 3× HBM AR ─▶ [S4 HBMReadEngine] ─ Ch0/Ch2/Ch4 RespFIFO ─┐
        │        ─ hit ─▶ HeaderPostFIFO, PayloadPostFIFO, FlowIdentPostFIFO ──────┤
        │        ─ miss ─▶ [S7 Notify]                                              │
                                                                                    ▼
                        [S5 Averager] ◀─ PayloadPostFIFO + 3× Ch RespFIFO (4-input rendezvous)
                                     └─ AvgOutFIFO (8 beats/pkt) ─▶ [S6 ResultEgress] ─▶ m_axis_rpout0
   [S8 CtrlRegs] ◀─ s_axil ; drives table commands into S2, exposes counters/status
```

| Stage | Responsibility | Inter-stage interface contract (the cut-point) |
|---|---|---|
| **S1 Ingress** | parse Eth/IPv4/UDP from beat 1; filter (§3); build 5-tuple; fan out | `HeaderFIFO`: 64 B header beat (incl. `client_timestamp`). `PayloadFIFO`: 8×64 B payload. Lookup request: 5-tuple key. `CNT_RX`/`CNT_DROP_FILTER`. |
| **S2 FlowTable** | wrap `mkCachedCuckooServer`; serialize AXI-L upsert/delete from S8; route lookup responses in request order | `LookupRespFIFO`: `Server#`-ordered response `{hit, flow_ident, off_ch0, off_ch2, off_ch4}`. |
| **S3 Dispatch** | pop Header+Payload+LookupResp aligned by ingress order; on hit issue 3 HBM reads + forward; on miss drop + notify | to S4: 3× AR `{addr=off_chN, len=8, size=64B, fixed ARID/channel}`. `HeaderPostFIFO`, `PayloadPostFIFO`, `FlowIdentPostFIFO`. To S7 on miss. `CNT_HIT`/`CNT_MISS`. |
| **S4 HBMReadEngine** | 3 channel masters, **one fixed ARID each** → per-channel in-order R streams | `Ch0/Ch2/Ch4 RespFIFO`: 8×64 B vector each. `RRESP` surfaced for error path. |
| **S5 Averager** | 32-lane int16 datapath; 4-input beat-synchronous rendezvous (PayloadPost + 3 channel resp); `(p+v0+v2+v4)>>>2`, signed 20-bit, arith shift; big-endian lanes | `AvgOutFIFO`: 8 averaged beats/pkt. |
| **S6 ResultEgress** | splice header beat (bytes 42..49 = flow_ident+seq, 50..55 zeroed) | 8 avg beats; `tlast` beat 9; drive `m_axis_rpout0` with host-range `tdest`; maintain global `sequence_num`; `CNT_PROCESSED`. |
| **S7 Notify** | AXI-MM master (`m_axibr`); write 32 B ring entries; HEAD/TAIL mechanics | ring writes; `CNT_NOTIFY_DROP`. |
| **S8 CtrlRegs** | AXI-Lite slave (`s_axil`); register map (spec §5); atomic `TBL_CMD` commit → S2; expose counters/status | table-command stream to S2; counter reads. |

## Dataflow topology + sizing (fixed)

Size every FIFO for **≥ 32 in-flight packets (`N_INFLIGHT = 32`)**:

| FIFO | Depth | Bytes |
|---|---|---|
| HeaderFIFO / HeaderPostFIFO | 32 | 2 KB each |
| PayloadFIFO / PayloadPostFIFO | 32 | 16 KB each (BRAM/URAM — agent's choice) |
| FlowIdentPostFIFO | 32 | 128 B |
| LookupRespFIFO | 32 | ≈ 1 KB |
| Ch0/Ch2/Ch4 RespFIFO (per channel) | 32 | 16 KB each |

Outstanding AXI reads per channel: up to 32, all on one `ARID`.

## Error-path microarchitecture (fixed observable, free mechanism)

On `RRESP != OKAY` for a packet on any channel: drop that packet's result, drain the matching entries
from `PayloadPostFIFO`/`HeaderPostFIFO`/`FlowIdentPostFIFO` and the sibling channel RespFIFOs,
`CNT_HBM_ERR++`, continue without stalling. The *draining mechanism* is the agent's; the *observable*
(one suppressed result, counter increments, no stall, conservation holds) is fixed by the spec.

## Known-good pointers (no code copied)

- **HBM instantiation** (the given app-BD scaffolding presenting 3× 512b@user-clk masters, channels
  0/2/4): follow [`examples/bd/hbm-subsystem.tcl`](../../bd/hbm-subsystem.tcl) (HBM IP + per-channel
  dwidth 256→512 / clock 450 MHz→user-clk converters).
- **Flow-table IP contract** (`mkCachedCuckooServer` request/response, 128-bit value, post-reset
  warmup): [`docs/08-bsv-library-catalog.md`](../../../docs/08-bsv-library-catalog.md).
- **BSV dataflow idioms** (Get/Put/Server, FIFO flavors, AXIS beat model, TLM3/AXI):
  [`docs/10`](../../../docs/10-bsv-dataflow-handshaking.md)–[`12`](../../../docs/12-bsv-axi-transactions.md).
- **Timing / floorplanning** (guard-pblock boundary ring, `CLOCK_DEDICATED_ROUTE BACKBONE` for the
  HBM MMCM): [`docs/05-floorplan-au50.md`](../../../docs/05-floorplan-au50.md) +
  [`prompts/05-floorplanning-and-timing.md`](../../../prompts/05-floorplanning-and-timing.md).
