# BSV library catalog

What lives in [`../libs/bsv`](../libs/bsv) — the building blocks you compose
rather than rewrite. These are validated in silicon-bound designs; reaching for
one is always cheaper than reinventing it, and reinventing one is a review
finding.

Compile against them with `bsc -p <...>:libs/bsv` and point `-y` at
[`../libs/verilog`](../libs/verilog) for the Verilog/SV closure. The case-study
Makefile ([`../examples/case-study-nf/Makefile`](../examples/case-study-nf/Makefile))
does exactly that and is the template.

| File | Provides |
|---|---|
| `Axi4BusesDefines.bsv` | Bus parameter presets and the type aliases built on them |
| `Axi4Utilities.bsv` | TLM ↔ AXI4 transactors, FIFO-pair → master/slave adapters |
| `AxisGetPut.bsv` | AXI-Stream beat model and `Get`/`Put` adapters |
| `BufferedConnection.bsv` | Pipelined `Get`↔`Put` / `Client`↔`Server` connections |
| `CachedCuckoo.bsv` | BVI wrapper over the vendored cuckoo hash-table IP |
| `KvsDefines.bsv` | Key/value request and response types |
| `EtherDefines.bsv` | Ethernet/IPv4/UDP header structs, helpers, traffic split |
| `GPMux.bsv` | Generic `Get`/`Put` mux and demux over an arbiter |
| `CAM.bsv` | Small associative lookup |
| `DebugPutSink.bsv` | Non-intrusive instrumentation probes |

---

## `Axi4BusesDefines.bsv` — bus presets

Parameter tuple is `(idW, addrW, dataW, lenW, userW)`.

| Preset | Parameters | Notes |
|---|---|---|
| HBM | `6, 33, 512, 8, 0` | 33-bit address = 512 MB per pseudo-channel. **Bursts must be ≤ 8 beats.** |
| DDR4 | same as HBM | Aliased typedefs. |
| XDMA bypass | `4, 64, 512, 8, 0` | |

Type aliases you actually name: `HbmTlmReq_t`, `HbmTlmResp_t`,
`HbmTlmReqDesc_t` (= `RequestDescriptor`), `HbmTlmSendIfc`, `HbmAxiMasterIfc`,
`HbmAxiSlaveIfc`, and the `Ddr*`/`XdmaByp*` equivalents.

## `Axi4Utilities.bsv` — transactors

The standard way to get an AXI master out of a pair of FIFOs:

```bsv
module mkAxi4MasterFromFifoPair #(FIFO#(req) reqF, FIFO#(resp) respF,
                                  Integer maxInFlight) (Axi4RdWrMaster#(...));
module mkAxi4MasterFromTlm       #(TLMSendIFC#(...) tlm, Integer maxFlight) (...);
module mkAxi4SlaveFromFifoPair   #(...);
module mkAxi4SlaveFromTlm        #(...);
function getTlmSendFromFifoPair  (FIFO#(req) reqF, FIFO#(resp) respF);
function getTlmRecvFromFifoPair  (...);
module mkTLMBurstReadExpander    #(...);  // one bursty READ -> single-beat descriptors
```

Design logic emits TLM3 `TLMRequest` and consumes `TLMResponse`; the transactor
converts to AXI4 channels. You build and drain two FIFOs. Usage patterns,
including burst chunking and response reassembly, are in
[12](12-bsv-axi-transactions.md).

## `AxisGetPut.bsv` — the AXI-Stream beat model

```bsv
typedef struct { Bit#(dw) data; Bit#(TDiv#(dw,8)) keep; Bool last; } AxisBeatS#(dw);
typedef struct { ... id; dest; user; ... }                          AxisBeatC#(...);
```

- `mkAxisSlaveAdapterS` / `mkAxisMasterAdapterS` — raw AXIS ports ↔ `Get`/`Put`
  of beats. The ingress adapter **ANDs `tkeep & tstrb`** for you.
- `mkAxisFIFOS` / `mkAxisFIFOC` — a buffered AXIS pass-through.
- `axis_mask_keep` / `axis_beatc_mask_keep` — zero data bytes whose keep bit is
  0. Apply before hashing or storing a partial last beat.

The `C` variants carry `id`/`dest`/`user`, which is what the RP boundary needs
(the shell's streams all have 16-bit `tid`, 16-bit `tdest`, 32-bit `tuser`).

## `BufferedConnection.bsv` — the timing knob between blocks

```bsv
mkBufGPConnection        (Get#(t), Put#(t), Integer nStages)
mkBufCSConnection        (Client#(req,resp), Server#(req,resp), Integer nStages)
mkCountedBufGPConnection (Get, Put, Integer nStages, Reg cntReg)   // + traffic counter
```

Inserts N `mkFIFO` stages between two blocks. Choosing the stage count is the
standard way to add slack and break a long path between large blocks **without
touching their logic** — reach for this before restructuring a datapath.

## `CachedCuckoo.bsv` — the flow-table IP

A BVI wrapper over the vendored cuckoo hash table in
[`../libs/verilog`](../libs/verilog) (`cached_cuckoo.sv`, `uram_cuckoo.sv`,
`uram_bank.sv`, `cuckoo_hash8_16_ultra_dsp_final.sv`, `hash_func.sv`,
`priority_encoder.sv`, `cam_cache.sv`, plus two Vitis-HLS-generated path
hashers).

Three layers:

```bsv
// raw BVI
mkCachedCuckooV #(cacheSize, numHashes, htSize, maxTrial, delValMatch)

// Get/Put layer — exposes the victim drain
interface IfcCachedCuckoo #(kw, vw);
    interface Put #(Bit#(kw))                            lookup;
    interface Get #(Maybe#(Bit#(vw)))                    lookup_res;
    interface Put #(Tuple3#(Bool, Bit#(kw), Bit#(vw)))   update;  // Bool: delete/~write
    interface Get #(Tuple2#(Bit#(kw), Bit#(vw)))         drain;   // evicted victim
endinterface

// the one you normally want
mkCachedCuckooServer #(cacheSize, numHashes, htSize, maxTrial, reinstThres)
  -> interface Server #(KvsReq#(kw,vw), KvsResp#(vw)) kvs_srv;
```

`KvsReq` is a tagged union of `Update (KvPair)` / `Lookup (key)` /
`Remove (key)`; `KvsResp` is `Found (val)` / `Succ` / `Fail`. **Responses come
back in request order**, which is what lets a downstream stage join lookup
results against a packet stream positionally.

`mkCachedCuckooServer` also handles victim reinsertion internally, with a
`reinstThres` cooldown and `(* preempts = "do_reinst, do_subm_req" *)` so
reinsertion wins over new requests.

Two things will bite you:

> **Post-reset warmup: ~2600 cycles.** The vendored `uram_bank.sv` clears its
> valid RAM one entry per cycle after reset (`2**AWIDTH` cycles per bank). Any
> testbench or bring-up sequence **must idle for roughly 2600 cycles after
> `RST_N` deasserts** before issuing the first command, or early inserts are
> silently wiped and every subsequent lookup misses. This is the single most
> common way a flow-table test appears broken when it is not.

> **Do not buffer between `drain.get` and `update.put`.** The victim-reinsert
> path must be a single atomic hop. Inserting a FIFO there breaks the table.

A 128-bit value is a natural fit for packing four 32-bit fields; the case study
uses `{flow_ident, off_ch0, off_ch2, off_ch4}`.

The IP is **not pipelined for 240 MHz.** Its victim/delmask logic runs 12–14
logic levels at ~6.5 ns, which misses even at 200 MHz — see the timing status in
[05](05-floorplan-au50.md). If you need timing closure with this table, plan for
either pipelining the IP or giving it its own slower clock domain.

## `EtherDefines.bsv` — headers and traffic split

```bsv
typedef 512 Cmac_w;   typedef AxisBeatS#(Cmac_w) CmacBeat;
struct EtherHeader / IPv4Header / UdpHeader / UdpIpEthHeader
swap_eth_mac / swap_ip_addr / swap_udp_port      // build a reply in place
assert_udpid_hdr                                  // validate
mkEtherPingbackOthers #(matchFn, swapOpt)         // traffic split
```

`UdpIpEthHeader` nests `{ UdpHeader udp; IPv4Header ip; EtherHeader eth; }` with
`eth` **last**, because BSV packs the first struct field into the MSBs while
network bytes arrive in the low bytes of beat 0. Field ordering here is
load-bearing — see [11](11-bsv-packet-per-beat.md).

`mkEtherPingbackOthers` is worth knowing about before you write your own
demultiplexer: `matchFn` runs on the first beat, matching frames go to your
`Client`, and everything else is automatically MAC/IP/UDP-swapped and looped
back out. Your function then only ever sees its own traffic.

## `GPMux.bsv`, `CAM.bsv`, `DebugPutSink.bsv`

- `mkGPMuxRR` / `mkGPMuxFP` (round-robin / fixed-priority) turn
  `Vector#(n, Put)` into a `Get`; `mkGPDemux*` is the dual. Built over
  bsc-contrib `Arbitrate`. Use these instead of a hand-written structural mux.
- `mkBCAMCL` — a small binary CAM with a clear/lookup interface, for tracking
  tables far smaller than the cuckoo table.
- `mkPutWithDebugProbe` / `mkGetWithDebugProbe` — tee every token to a debug
  sink without perturbing the dataflow. The instrumentation idiom that does not
  change scheduling.

## What is *not* here

The case study's own NF modules (packet ingress, flow-table wrapper, dispatcher,
HBM read engine, averager, egress, notification ring, control registers) are
**examples, not library** — they encode one application's contract. They live in
[`../examples/case-study-nf/src`](../examples/case-study-nf/src) and are meant to
be read and adapted, not imported.
