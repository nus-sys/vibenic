# Case study — UDP vector-averaging network function

The datapath the VibeNIC paper reports, complete and buildable in this tree.

A stateful per-flow tensor-mixing function of a shape common on SmartNICs:
per-flow lookup fused with memory-bound aggregation, as in in-network vector
similarity or telemetry. Each UDP packet carries an `int16 × 256` query vector;
on a flow-table hit the design reads three reference vectors from HBM channels
0/2/4 at table-designated offsets, emits their four-way average
`(payload + v0 + v2 + v4) >>> 2` to the host over QDMA C2H, and reports misses to
a host notification ring. The host owns all table state; the device owns lookup,
memory access, arithmetic, sequence numbering, and notification.

Target: Alveo U50, one 100 GbE port, 4096 tracked flows.

## Status

**Functionally complete and byte-exact in simulation.** Verified in this tree:
7/7 Bluesim testbenches pass; the end-to-end cocotb test is byte-exact against
the numpy golden model with counter conservation holding; the flow-table suite
passes all six scenarios; the stress suite is byte-exact at 432/432 beats and
48/48 frames under backpressure plus memory latency.

**Its last U50 build misses timing:** post-route WNS **−2.423 ns**, TNS
−9107 ns, 7826 failing endpoints (hold clean, WHS +0.007). The worst paths are
**inside the vendored cuckoo hash-table IP** (`ft/…/victim_cache`,
`delmask_cache`) — 12–14 logic levels at ~6.5 ns of data-path delay, which misses
even at 200 MHz. That IP was never pipelined for this frequency. This is **not**
a partition-boundary or floorplan defect: the guard-slice ring and pblocks are
in place and correct, and they close the boundary paths. A secondary 450 MHz
`hbm_axiclk` violation (−0.187 ns) in the 512→256 downsizer is route-delay
dominated — congestion from a large design crowding the die; the identical
downsizer closes in the loopback reference with a near-empty partition.

Closing it needs IP-level work — pipelining the victim/delmask logic, or giving
the flow table its own slower clock domain with a CDC — not more constraints.

The partial bitstream is usable for functional bring-up but is not timing-clean.

One historical note worth keeping: a long-tracked "~27 % header drop under
backpressure" turned out to be a **testbench artifact**, not a design defect. A
hand-written egress collector drove `tready` itself and sampled in `ReadOnly`,
mis-scoring transfers by one cycle. With `cocotbext-axi`'s `AxiStreamSink` the
design is byte-exact and needed no change. See
[`../../prompts/04-simulation-mandates.md`](../../prompts/04-simulation-mandates.md).

## Building and simulating

Self-contained — `bsc` is pointed at [`../../libs`](../../libs), so nothing
outside this tree is needed.

```bash
make compile                    # bsc -> verilog/mkVectorAvgNF.v
make bsim-all                   # 7 pure-logic Bluesim testbenches
make cocotb                     # e2e byte-exact diff + flow-table suite
make golden                     # the numpy oracle's own self-check
make tc PKG=FourWayAverager     # typecheck one package
make pack_ip                    # -> a Vivado IP  (needs Vivado)
```

The FPGA build itself runs from a shell checkout against a support package —
`make app BOARD=au50 APP=… SHELL_PKG=…`. See
[`../../docs/14-build-and-load-flow.md`](../../docs/14-build-and-load-flow.md)
and [`../tcl/app-build.tcl`](../tcl/app-build.tcl).

## The modules, and what each demonstrates

| Module | Stage | Read it for |
|---|---|---|
| `FlowReduceDefines.bsv` | shared | Type definitions and interface contracts pinned in one place. |
| `PacketIngress.bsv` | S1 | Per-beat parsing, header-overlay structs, filtering, the beat-counter FSM, tail flushing. → [`docs/11`](../../docs/11-bsv-packet-per-beat.md) |
| `FlowTable.bsv` | S2 | Driving a BVI-wrapped hash table; serialising host commands against the lookup stream. → [`docs/08`](../../docs/08-bsv-library-catalog.md) |
| `LookupDispatcher.bsv` | S3 | Joining three streams positionally by ingress order; hit/miss routing. |
| `HBMReadEngine.bsv` | S4 | An AXI4 read master in BSV: one ARID per channel, ≤ 8-beat bursts, `RRESP` surfacing. → [`docs/12`](../../docs/12-bsv-axi-transactions.md) |
| `FourWayAverager.bsv` | S5 | A 32-lane `int16` datapath with a 4-input beat-synchronous rendezvous — **and the byte-swap discipline** that makes it correct. |
| `ResultEgress.bsv` | S6 | Header splicing, `tlast` placement, host-range `tdest`, a monotonic sequence field. |
| `NotifyEngine.bsv` | S7 | An AXI4-MM writer into host memory: ring geometry, head/tail, full-drop accounting. |
| `CtrlRegs.bsv` | S8 | An AXI-Lite slave with **atomic multi-register commit** and the counter set the conservation laws close over. |
| `VectorAvgNF.bsv` | top | Composing stages with `mkConnection`, and what the top's external interface must look like. |

## Its own design documents

[`spec/`](spec/) holds the three documents this was built from — the functional
contract, the reference architecture, and the test plan. They are worth reading
as a worked example of the pattern in
[`../../prompts/08-spec-authoring.md`](../../prompts/08-spec-authoring.md), quite
apart from what they say about this particular function.

Two conventions from them are load-bearing elsewhere in the corpus:

- **Vector lanes are `int16`, big-endian, lane-major.** Beat 1 carries elements
  0–31, and each lane arrives in network byte order — so signed arithmetic needs
  `bswap16` in and out. This is the bug the end-to-end golden diff exists to
  catch.
- **The flow-table value is 128 bits**:
  `{flow_ident[31:0], off_ch0[31:0], off_ch2[31:0], off_ch4[31:0]}`. Because HBM
  channel windows are at fixed offsets, `off_chN` is an HBM-absolute byte
  address for both the host preload path and the device read path.

## Tests

| Tier | Files | Covers |
|---|---|---|
| Bluesim | `test/Sim*.bsv` (7) | Pure-logic stages: averager, dispatcher, HBM engine, egress, ingress, notify, control registers. |
| Verilator + cocotb | `tests/cocotb/` (5) | The flow table (BVI), the integrated top, the byte-exact end-to-end diff, the backpressure stress run, a fast smoke. |
| Oracle | `tests/golden/` | The numpy specification model, plus a self-check of the model itself. |

`test/SimFlowTable.bsv` is a Bluesim-style testbench that cannot run in
Bluesim — it pulls the cuckoo BVI, so it goes through the Verilator tier. That
split is explained in
[`../../docs/13-simulation-frameworks.md`](../../docs/13-simulation-frameworks.md).
