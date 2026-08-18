# UDP Vector-Averaging Network Function — Test Plan

**Spec:** [`spec.md`](spec.md) · **Architecture:** [`refarch.md`](refarch.md) · **Status:** v0.3

> *As authored for this design. Cross-references have been re-pointed to the
> DEPs corpus; the substance is unchanged. See
> [`../../../prompts/08-spec-authoring.md`](../../../prompts/08-spec-authoring.md)
> for why the design documents are split this way.*


---

## 1. Purpose & Approach

Covers **functional verification** of the NF. Out of scope: timing closure, post-P&R gate-level sim,
performance modeling, bring-up.

Tests are keyed to the reference architecture's **stages** (S1–S8 in `refarch.md`), not to module
names — under the ground rules module names and intra-stage structure are the agent's.
Two-tier strategy, chosen per stage by its **inter-stage interface contract**:

- **BSV native (Bluesim)** for pure-logic stages whose interfaces are BSV abstractions (`Server#`,
  `Get#`/`Put#`, datapath streams). Fast iteration, native types.
- **Cocotb + cocotbext-axi (over Verilator)** for stages whose interfaces are AXI buses. Captures
  protocol-handshake bugs BSV scheduling hides; pressure-tests backpressure and error injection.

Each stage is tested in exactly one tier. **Free names, fixed cut-points:** a per-stage test binds to
the stage's pinned inter-stage interface (the FIFO/`Server#` contract in `refarch.md`) **if the design
exposes it** as an observable module boundary. A stage the design **merges/hides** has its per-stage
test recorded **N/A** and is covered by the top-level integration (§4) instead. The top test is Cocotb
only, since every *external* interface of `mkVectorAvgNF` is AXI.

---

## 2. Tooling Stack

| Layer | Tool |
|---|---|
| BSV → Verilog compilation | `bsc` |
| BSV-native simulator | Bluesim |
| Verilog simulator for Cocotb | Verilator |
| Test framework | Cocotb 1.8+ |
| AXI agents and monitors | cocotbext-axi (AxiMaster, AxiSlave, AxiStreamSource, AxiStreamSink, monitors) |
| Golden model | Python + numpy, at `tests/golden/`, shared across Cocotb tests |
| Packet construction | scapy |
| HBM behavioral model | cocotbext-axi `AxiSlave` backed by `bytearray`, per channel |

CMAC and QDMA are not simulated as IPs — only their AXI-Stream contracts are driven via
`AxiStreamSource` / `AxiStreamSink`.

---

## 3. Per-Stage Tests

Stage → tier → the pinned interface each test binds to (per `refarch.md`). Names in parentheses are
the original reference modules, for continuity only — the agent's module names may differ.

| Stage | Tier | Binds to (inter-stage interface) |
|---|---|---|
| S1 Ingress (mkPacketIngress) | Cocotb | `s_axis_ethrx0` in; HeaderFIFO / PayloadFIFO / lookup-req out |
| S2 FlowTable (mkFlowTable) | Bluesim | lookup `Server#`; `update` Put; command stream from S8 |
| S3 Dispatch (mkLookupDispatcher) | Bluesim | Header/Payload/LookupResp in; 3× HBM AR + post-FIFOs / notify out |
| S4 HBMReadEngine (mkHBMReadEngine) | Cocotb | 3× AXI4 master (one ARID/channel); Ch0/2/4 RespFIFO |
| S5 Averager (mkFourWayAverager) | Bluesim | 4 input streams (Payload + 3 channel resp) → AvgOutFIFO |
| S6 ResultEgress (mkResultEgress) | Cocotb | header + AvgOut in; `m_axis_rpout0` out |
| S7 Notify (mkNotifyEngine) | Cocotb | miss descriptors in; `m_axibr` ring writes |
| S8 CtrlRegs (mkCtrlRegs) | Cocotb | `s_axil` slave; command stream to S2; counter reads |

### 3.1 S1 Ingress — Cocotb

External AXI-Stream input on `s_axis_ethrx0` (NIC RX).

**Cases:**
1. **Line-rate good traffic:** 1000 well-formed 576 B packets with `tvalid` held high → all 1000 enter HeaderFIFO and PayloadFIFO with correct 5-tuple; `CNT_RX = 1000`.
2. **Filter — non-IPv4:** ethertype != 0x0800 → dropped, `CNT_DROP_FILTER` increments.
3. **Filter — non-UDP:** IPv4 `proto` != 17 → dropped.
4. **Filter — wrong length:** wire length != 576 B → dropped.
5. **Gappy AXI-S:** random `tvalid` deassertions mid-packet → packet still parsed correctly; no spurious tlast handling.
6. **Output backpressure:** HeaderFIFO held full → `tready` on RX deasserted; no packet loss after FIFO drains.

**Pass:** counters match; no malformed packets reach downstream; line-rate sustained on good packets.

### 3.2 S2 FlowTable — Bluesim

Wraps `mkCachedCuckooServer` plus a small command FIFO (depth 16) consuming `Upsert` / `Delete` from the CtrlRegs stage (S8).

**Cases:**
1. Upsert + Lookup → expected value returned with hit.
2. Lookup on empty table → miss.
3. Delete + subsequent Lookup → miss.
4. Fill to 4096 entries, verify hits on all; delete half, verify misses on deleted half.
5. Concurrent Upsert (from command FIFO) interleaved with Lookup (from ingress) — verify both serviced without corruption.
6. Command queue overflow → `tbl_q_full` status; subsequent command dropped, `CNT_TBL_Q_DROP` increments.

**Pass:** all sequences produce expected responses; queue overflow flagged correctly.

> Note (per [`docs/08-bsv-library-catalog.md`](../../../docs/08-bsv-library-catalog.md)): warm up ~2600 cycles after reset before issuing
> commands, or early inserts get wiped by the vendor URAM valid-clear.

### 3.3 S3 Dispatch — Bluesim

Joins HeaderFIFO, PayloadFIFO, LookupRespFIFO; routes hits to the HBM masters + post-dispatch FIFOs; routes misses to the Notify stage (S7).

**Cases:**
1. 100 all-hit packets → 100 entries in each post-FIFO, 3 HBM AR per packet, zero notifications.
2. 100 all-miss packets → zero post-FIFO entries, 100 notifications enqueued, zero HBM AR.
3. Interleaved hit/miss (random pattern) → per-packet routing correct.
4. Backpressure on a post-FIFO → dispatcher backpressures lookup pop; no FIFO underflow.

**Pass:** counters match; no FIFO underflow; backpressure propagated cleanly.

### 3.4 S4 HBMReadEngine — Cocotb (AXI4 slave per channel)

Three channels, each pinned to one ARID. cocotbext-axi `AxiSlave` instances back each channel with a Python `bytearray` model memory.

**Cases:**
1. **Single-burst correctness:** issue one AR per channel, verify R data matches model memory, RLAST on beat 8.
2. **32 outstanding bursts on one channel:** issue 32 ARs back-to-back, all responses returned in AR-issue order (AXI per-ID guarantee).
3. **3 channels concurrent:** random offsets per channel, drift between channels permitted; each channel's R stream is individually in-order.
4. **Variable HBM latency:** AxiSlave configured for random 10..200-cycle latency per burst → engine handles backpressure without dropping transactions.
5. **RRESP=SLVERR injection:** on one burst (random channel, random packet) → `CNT_HBM_ERR` increments; the affected packet's result is suppressed downstream; pipeline does not stall.

**Pass:** zero AXI4 protocol violations; no transactions lost; error path verified.

### 3.5 S5 Averager — Bluesim

Pure dataflow: 4 input streams (32-lane int16) → 1 output stream.

**Golden model:** `out[i] = (p[i] + v0[i] + v2[i] + v4[i]) >>> 2`, signed 20-bit intermediate, arithmetic right shift (rounds toward −∞). Lanes are big-endian (spec §3).

**Cases:**
1. All zero inputs → zero output.
2. All inputs = INT16_MAX, INT16_MIN → check no overflow, correct signed shift.
3. 1000 random vectors → golden compare elementwise.
4. Output backpressure (downstream FIFO full) → averager stalls; no data loss.
5. Stall on one of four input FIFOs → rendezvous blocks; resumes cleanly when input arrives.

**Pass:** all golden matches; no underflow events; clean restart from stall.

### 3.6 S6 ResultEgress — Cocotb (AXI-Stream to `m_axis_rpout0`)

**Cases:**
1. **Byte-map correctness:** emit one packet; verify byte map: 0..41 echoed from input header, 42..45 = flow_ident, 46..49 = sequence_num, 50..55 = 0, 56..63 = echoed timestamp, 64..575 = averaged vector. `tlast` on beat 9; egress `tdest` in the host range `0x0000–0x7FFF`.
2. **Sequence monotonicity:** emit 1000 packets, verify `sequence_num` increments by 1 per packet, no skips.
3. **Sink backpressure:** random `tready` pattern → all 9 beats of each packet remain contiguous; `tlast` preserved; no drops.
4. **Averager gap:** simulate input gap mid-packet → egress holds the bus (no spurious `tlast`); resumes when data arrives.

**Pass:** every emitted packet matches byte map; backpressure preserves AXI-Stream packet atomicity.

### 3.7 S7 Notify — Cocotb (AXI4-MM master `m_axibr`)

cocotbext-axi `AxiSlave` models host memory backing the notification ring.

**Cases:**
1. **Single miss:** one notification → AXI write at `NOTIFY_BASE`, 32 B payload matches the C struct; `NOTIFY_HEAD` advances by 1.
2. **Ring fill:** drive `2^N` misses with `NOTIFY_SIZE_LOG2 = N` → all writes succeed; HEAD wraps correctly.
3. **Ring full:** with TAIL held static, one more miss → `CNT_NOTIFY_DROP` increments; HEAD does not advance; no spurious AXI write.
4. **Recovery:** advance TAIL → engine resumes writing on next miss.
5. **AXI-MM stall:** AxiSlave configured to stall AW/W → notifications backpressure cleanly; no protocol violation.

**Pass:** ring mechanics correct; AXI4 protocol monitor reports zero violations.

### 3.8 S8 CtrlRegs — Cocotb (AXI-Lite slave `s_axil`)

**Cases:**
1. **Write/readback:** write every RW register, read back, verify value.
2. **Read-only registers:** writes are ignored, value unchanged.
3. **Atomic commit:** write `TBL_KEY_*` + `TBL_VAL_*` + `TBL_VAL_FLOW_ID`, then write `TBL_CMD` with `commit=1` → exactly one command captured in command FIFO with the values present at the commit cycle. Mid-stream scratch updates between non-commit writes are not visible until commit.
4. **Counter propagation:** drive internal increment signals → `CNT_*` registers reflect updates on subsequent reads.
5. **Reserved bits:** read as zero.

**Pass:** all read-after-write checks succeed; commit semantics verified; AXI-Lite protocol monitor reports zero violations.

---

## 4. Top-Level Integration (Cocotb)

DUT: full `mkVectorAvgNF` with all external interfaces driven by Cocotb agents.

### 4.1 Harness

- **RX:** `AxiStreamSource` on `s_axis_ethrx0`, driving constructed packets from the golden model.
- **TX:** `AxiStreamSink` on `m_axis_rpout0`, collecting result packets for comparison.
- **HBM (×3):** `AxiSlave` per channel, backed by `bytearray(64 KB)` model memory the test pre-populates.
- **MMIO:** `AxiLiteMaster` on `s_axil` for table setup, counter reads, ring config.
- **Notify ring:** `AxiSlave` on `m_axibr` backed by `bytearray` for the host ring.
- **Golden model:** `tests/golden/`. A single Python package shared across all Cocotb tests. Exposes `compute_result(input_packet, table_state, sequence_num) → (result_packet, notification_or_none, counter_deltas)`. Used both to seed DUT inputs and to score DUT outputs.

### 4.2 Scenarios

1. **Cold start:** empty table; send 16 packets to 16 distinct flows → 16 misses, 16 notifications, zero processed. Host installs all 16 entries via AXI-L + writes vectors to HBM via the model memory; re-send → 16 hits, 16 result packets emitted.
2. **Single-flow line rate:** one flow installed, 10 000 packets back-to-back → `CNT_PROCESSED = 10 000`, every result packet matches the golden output.
3. **Multi-flow line rate:** 32 flows installed, packets cycled round-robin at line rate → no drops; within-flow ordering preserved.
4. **Mixed hit/miss:** 50 % of packets target uninstalled flows → `CNT_HIT` and `CNT_MISS` each ≈ 50 % of `CNT_RX`; results correct for the hits.
5. **Table churn under traffic:** stream packets while host performs upsert/delete at ≈ 1 cmd/μs (sim time) → no false hits or false misses across transitions.
6. **HBM error injection:** 1 % of bursts return RRESP=SLVERR → `CNT_HBM_ERR` increments; affected result packets are suppressed; pipeline does not stall; subsequent packets succeed.
7. **Egress backpressure:** random `tready` pattern on the TX sink → ingress slows via backpressure chain; no drops; no corruption.
8. **Ring overflow recovery:** hold notify TAIL static while driving misses → ring fills, `CNT_NOTIFY_DROP` increments. Advance TAIL → writes resume cleanly on the next miss.

### 4.3 Counter conservation

After every scenario, verify:

    CNT_RX == CNT_DROP_FILTER + CNT_HIT + CNT_MISS
    CNT_HIT == CNT_PROCESSED + CNT_HBM_ERR
    CNT_MISS == (notifications written) + CNT_NOTIFY_DROP

These conservation laws catch a large class of pipeline bugs (lost packets, double-counts) at very low cost.

### 4.4 Pass criteria

- All eight scenarios pass deterministically across 5 random seeds each.
- Counter conservation holds in every scenario.
- Zero AXI protocol violations across all interfaces (cocotbext-axi monitors).
- Scenarios 2 and 3 sustain ≥ 95 % of theoretical line rate in simulation cycle terms.

---

## 5. Coverage

Best-effort, in-band to the simulation cases above. No formal coverage tooling.

| Type | Target |
|---|---|
| BSV line coverage (Bluesim, per stage) | ≥ 90 %, reported via `bsc` coverage output |
| Cocotb scenario coverage | every listed case PASS on ≥ 5 random seeds |
| AXI protocol compliance | zero violations from cocotbext-axi monitors on AR/R/AW/W/B/AXI-Stream handshakes across all tests |
| Functional cross at top level | for each cell of {hit, miss} × {backpressure on, off} × {error inject on, off} × {table churn on, off} — at least one packet observed in the aggregate run logs |

---

## 6. Out of Scope

- Timing closure / static timing analysis.
- Post-place-and-route gate-level simulation.
- Performance modeling beyond simulator cycle counts.
- Host-side userspace driver (separate effort).
- HBM controller internal modeling — the wrapper presents AXI to the NF; behavioral slaves are sufficient.
- Multi-port, multi-queue, IPv6, fragmentation — all explicitly out of scope per spec §8.
- Formal coverage tooling (`cocotb-coverage`, cross-coverage analysis). Coverage is best-effort and scenario-based.
