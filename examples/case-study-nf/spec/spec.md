# UDP Vector-Averaging Network Function — Specification

**Target board:** Alveo U50 · **Shell:** VibeNIC (packaged shell
`au50_shell_v03_support_eac7a3b3.zip`) · **Language:** Bluespec SystemVerilog (BSV) ·
**Port:** one 100 GbE CMAC

> *As authored for this design. Cross-references have been re-pointed to the
> DEPs corpus; the substance is unchanged. See
> [`../../../prompts/08-spec-authoring.md`](../../../prompts/08-spec-authoring.md)
> for why the design documents are split this way.*

This document is the **standalone functional contract**: the packet- and host-facing behavior a
conforming design must exhibit, and nothing else. It intentionally contains no microarchitecture,
module breakdown, coding style, IP-usage how-to, or floorplanning — those are **companion
documents**, which a conforming design must also follow:

- **[`refarch.md`](refarch.md)** — the mandated reference architecture (stages, dataflow, sizing).
- **[`../../../docs/02-rp-boundary-contract.md`](../../../docs/02-rp-boundary-contract.md)** — the
  exhaustive shell boundary ([`libs/shell/rp_blk.v`](../../../libs/shell/rp_blk.v) is
  authoritative); §2 here summarizes it.
- **[`../../../docs/08-bsv-library-catalog.md`](../../../docs/08-bsv-library-catalog.md)** and
  **[`../../../docs/07-vendored-ip-catalog.md`](../../../docs/07-vendored-ip-catalog.md)** — the
  building-block library, the flow-table IP contract, and the known-good HBM instantiation.

Read those alongside this spec. Where a companion document constrains *how*, this document constrains
*what*; both bind.

---

## 1. Application Story

A stateful per-flow **tensor-mixing** function. Each flow has, pre-loaded in HBM, three `int16×256`
reference vectors representing per-flow "context" — loosely, a per-flow embedding cache for an
ML-inference frontend. Each incoming UDP packet carries one `int16×256` query vector as its payload.
For each packet the function:

1. Looks up the flow's HBM offsets and host-assigned `flow_ident` by 5-tuple.
2. Reads the three reference vectors in parallel from three HBM channels.
3. Computes the elementwise mean of the payload and the three references (a four-way average) across
   all 256 elements.
4. Emits a result packet to the host: the original header beat, modified at bytes 42..49 to carry the
   NF-assigned `flow_ident` and a monotonic `sequence_num`, followed by the 512 B averaged vector.

Packets whose 5-tuple is not yet installed in the on-chip flow table are **dropped**, and a
notification is written to a host-side ring so the host can populate HBM, install the entry over
AXI-Lite, and start handling subsequent packets of that flow.

The host owns all table state (insertion, deletion, offset assignment, `flow_ident`); the NIC owns
lookup, HBM read, vector arithmetic, sequence numbering, and notification.

---

## 2. Interfaces (external boundary)

Exhaustive detail and the authoritative signal set are in
[`../../../docs/02-rp-boundary-contract.md`](../../../docs/02-rp-boundary-contract.md) /
[`libs/shell/rp_blk.v`](../../../libs/shell/rp_blk.v). The NF presents, at `user_clk` (240 MHz on the
shell package named above — this document was drafted against an earlier 200 MHz figure, see
[`../../../docs/04-clocking-and-reset.md`](../../../docs/04-clocking-and-reset.md); single domain, a free-running 100 MHz is
available for an internal MMCM):

| Role | Boundary | Contract |
|---|---|---|
| Packet ingress | `s_axis_ethrx0` (AXI-S 512b) | UDP packets to process. QDMA-style metadata: `tid`=pkt id, `tdest={port_id,qid}`, `tuser={mdata,len_nbytes}`. Shell has length-policed the packet (`len_nbytes` authoritative). `s_axis_rph2c` (H2C lane) exists but is unused by this NF. |
| Result egress (to host C2H) | `m_axis_rpout0` (AXI-S 512b) | Drive the result here with `tdest` in the host range `0x0000–0x7FFF`. (A second lane `rpout1` exists; unused here.) |
| HBM reads | 3× AXI master, 512b @ user clock, channels **0, 2, 4** | Presented to the NF by given app-BD scaffolding (HBM IP + converters); the NF issues read-only bursts. See [`examples/bd/hbm-subsystem.tcl`](../../bd/hbm-subsystem.tcl). |
| Host MMIO | `s_axil` (AXI4-Lite 32/32; no `wstrb`/`prot`) | The §5 register map. |
| Notification write-back | `m_axibr` (AXI4-MM 64/512) | RP→host ring writes (§6). |
| Unused | `s_axi_dma`, `s_axi_pcie` | Not used by this NF; must be safely tied off in the BD. |

The NF shall not instantiate CMAC, QDMA, PCIe bridges, or the shell itself.

---

## 3. Data Formats

### 3.1 Packet on the wire (ingress)

- L2 Ethernet II, L3 IPv4 (no options), L4 UDP. The full **576-byte** wire packet is one header beat
  (64 B) plus eight payload beats (8 × 64 B = 512 B):

| Packet bytes | Field | Notes |
|---|---|---|
| 0..13 | Ethernet header | parsed only as needed for echo |
| 14..33 | IPv4 header (20 B, no options) | parse `proto`, `src_ip`, `dst_ip`, `total_length` |
| 34..41 | UDP header | parse `src_port`, `dst_port`; UDP `length` = 542 |
| 42..45 | client-set field | ignored by NF |
| 46..49 | client-set field | ignored by NF |
| 50..55 | padding | don't-care on ingress |
| 56..63 | `client_timestamp` | 64 b, echoed verbatim on egress |
| 64..575 | UDP payload | `int16 × 256`, **big-endian, lane-major** (beat 1 = elems 0..31, …, beat 8 = elems 224..255) |

IPv4 `total_length` = 562; UDP `length` = 542. Packets failing any of {IPv4, UDP, wire length == 576}
are dropped silently and counted in `CNT_DROP_FILTER`.

### 3.2 HBM storage layout

- Each reference vector = **512 contiguous bytes** in its channel, same big-endian lane-major encoding
  as the payload, so the four inputs elementwise-sum without reordering.
- Per-flow per-channel base offset is host-assigned, stored in the hash-table value (three offsets:
  `off_ch0`, `off_ch2`, `off_ch4`) alongside `flow_ident`.
- Host offsets are **512 B-aligned** (each 8-beat × 64 B burst stays inside one HBM page).
- HBM reads are read-only bursts of length 8, size 64 B — one full vector per burst.

### 3.3 Result on the wire (egress to host C2H)

Exactly **576 B** (1 header beat + 8 payload beats, `tlast` on beat 9). A one-beat header splice:

| Packet bytes | Field | Source |
|---|---|---|
| 0..13 | Ethernet header | echoed verbatim |
| 14..33 | IPv4 header | echoed verbatim (checksum still valid) |
| 34..41 | UDP header | echoed verbatim (UDP checksum now invalid; not recomputed, host does not verify) |
| 42..45 | `flow_ident` | NF-set, from table value, network byte order |
| 46..49 | `sequence_num` | NF 32-bit global monotonic counter, network byte order |
| 50..55 | padding | NF writes zero |
| 56..63 | `client_timestamp` | echoed verbatim from ingress 56..63 |
| 64..575 | averaged vector | `int16 × 256`, big-endian, lane-major — all 256 elements |

---

## 4. Observable Behavior (the contract)

For each ingress packet, in ingress order (egress order = ingress order; no reordering):

1. **Filter.** Parse Ethernet/IPv4/UDP. `CNT_RX` counts every ingress packet. If any of {IPv4, UDP,
   len==576} fails → drop, `CNT_DROP_FILTER++`, no further action.
2. **Lookup** by 5-tuple key `{src_ip, dst_ip, src_port, dst_port, proto=17}`.
3. **On hit** (value carries `flow_ident, off_ch0, off_ch2, off_ch4`): `CNT_HIT++`. Read the three
   reference vectors from HBM channels 0/2/4 at the given offsets. Compute, per lane i, per beat:

       out[i] = (payload[i] + v0[i] + v2[i] + v4[i]) >>> 2

   with a signed 20-bit intermediate and **arithmetic** right shift by 2 (rounds toward −∞); lanes are
   big-endian per §3. Emit the result packet (§3.3). `CNT_PROCESSED++`, `sequence_num++`.
4. **On miss:** `CNT_MISS++`. Drop header+payload. Write one notification entry to the host ring (§6);
   if the ring is full, drop it and `CNT_NOTIFY_DROP++`.
5. **HBM error:** any channel returning `RRESP != OKAY` for a packet → suppress that packet's result,
   `CNT_HBM_ERR++`, and continue without stalling the pipeline.

These invariants must hold after any run — they are part of the contract, and they are checked
after every test scenario:

    CNT_RX  == CNT_DROP_FILTER + CNT_HIT + CNT_MISS
    CNT_HIT == CNT_PROCESSED + CNT_HBM_ERR
    CNT_MISS == (notifications written) + CNT_NOTIFY_DROP

**Flow-table value encoding** (host and NF must agree): 128 bits =
`{flow_ident[31:0], off_ch0[31:0], off_ch2[31:0], off_ch4[31:0]}`.

---

## 5. Control Plane — AXI-Lite Register Map

Base = shell-assigned. All registers 32-bit, byte-addressable. RW unless marked RO.

| Offset | Name | Bits | Description |
|---|---|---|---|
| 0x00 | `CTRL` | [0]=enable, [1]=soft_reset (W1, self-clearing) | enable gates ingress |
| 0x04 | `STATUS` | RO: [0]=ready, [1]=tbl_q_full, [2]=notify_ring_full | |
| 0x10 | `TBL_KEY_0` | `src_ip[31:0]` | scratch |
| 0x14 | `TBL_KEY_1` | `dst_ip[31:0]` | scratch |
| 0x18 | `TBL_KEY_2` | `{src_port[15:0], dst_port[15:0]}` | scratch |
| 0x1C | `TBL_KEY_3` | `{proto[7:0], rsv[23:0]}` | scratch |
| 0x20 | `TBL_VAL_CH0` | `off_ch0[31:0]` | scratch |
| 0x24 | `TBL_VAL_CH2` | `off_ch2[31:0]` | scratch |
| 0x28 | `TBL_VAL_CH4` | `off_ch4[31:0]` | scratch |
| 0x2C | `TBL_VAL_FLOW_ID` | `flow_ident[31:0]` | scratch |
| 0x30 | `TBL_CMD` | [1:0]=op (0=upsert, 1=delete, 2/3=rsv), [31]=commit (W1, self-clearing) | commit snapshots all scratch atomically and enqueues one command |
| 0x40 | `NOTIFY_BASE_LO` | host phys addr [31:0] | |
| 0x44 | `NOTIFY_BASE_HI` | host phys addr [63:32] | |
| 0x48 | `NOTIFY_SIZE_LOG2` | [4:0] | ring length = 2^N entries |
| 0x4C | `NOTIFY_HEAD` | RO — NIC-maintained write index | |
| 0x50 | `NOTIFY_TAIL` | RW — host-maintained read index | |
| 0x80 | `CNT_RX` | RO | total ingress packets seen |
| 0x84 | `CNT_DROP_FILTER` | RO | dropped on header filter |
| 0x88 | `CNT_HIT` | RO | flow-table hits |
| 0x8C | `CNT_MISS` | RO | flow-table misses |
| 0x90 | `CNT_PROCESSED` | RO | result packets emitted |
| 0x94 | `CNT_HBM_ERR` | RO | AXI read RRESP != OKAY (any channel) |
| 0x98 | `CNT_NOTIFY_DROP` | RO | notifications dropped on ring full |
| 0x9C | `CNT_TBL_Q_DROP` | RO | table commands dropped on FIFO full |
| 0xA0+ | (reserved for agent-added debug counters) | | |

**Table-command queue.** Internal FIFO depth = 16. Host writes `TBL_KEY_*`, `TBL_VAL_CH*`,
`TBL_VAL_FLOW_ID`, then `TBL_CMD` with `commit = 1`; the function snapshots all scratch atomically on
that write and enqueues. On overflow: `STATUS.tbl_q_full = 1`, `CNT_TBL_Q_DROP++`, command dropped.

---

## 6. New-Flow Notification

On a miss, write one 32-byte entry to the host ring via `m_axibr`:

```c
struct notify_entry {           // 32 bytes, packed
    uint32_t src_ip;            // network byte order
    uint32_t dst_ip;
    uint16_t src_port;
    uint16_t dst_port;
    uint8_t  proto;             // 17
    uint8_t  rsv[3];
    uint64_t timestamp_cycles;  // local user clock cycles at miss
    uint64_t rsv2;
};
```

Ring geometry from 0x40/0x44/0x48. Increment `NOTIFY_HEAD` after each successful write; if
`((HEAD+1) mod size) == TAIL` the ring is full → drop, `CNT_NOTIFY_DROP++`. Host advances `NOTIFY_TAIL`.

---

## 7. Performance Targets

| Target | Threshold |
|---|---|
| Aggregate throughput, ≥ 16 active flows | ≥ 95 Gbps sustained Ethernet line rate |
| Single-flow throughput | ≥ 80 Gbps (HBM-channel bandwidth permitting) |
| End-to-end latency (arrival → emit, single flow) | ≤ 1 µs excluding HBM access time |
| User-region resource budget | report LUT / FF / BRAM / URAM; expected ≤ 40 % of user pblock |

Report which targets are met; for any missed, disclose the bottleneck honestly (HBM bandwidth,
averager pipeline, table latency, AXI conversion path, etc.). (Line-rate is not HBM-limited: at 100
Gbps / 576 B packets ≈ 21.7 Mpps, per-channel read traffic ≈ 11.1 GB/s, well within one HBM2
pseudo-channel; three channels run in parallel.)

---

## 8. Out of Scope

- Multi-port, multi-queue, RSS, IPv6, IP fragmentation, jumbo frames.
- Dynamic flow eviction/aging (host owns table lifecycle).
- ECC handling, HBM scrubbing.
- The host-side userspace driver (this spec is the NIC-side contract only).
- UDP checksum recomputation on egress (header echoed verbatim; checksum invalid after the 42..49
  rewrite; host does not verify).

---

## 9. Fixed Defaults

These are decided here so nobody re-litigates them; the reference architecture and the tests assume
them:

1. **`sequence_num` = global**, 32-bit, monotonic across all result packets, wraps at 2³².
2. **Notification entry = 32 B.**
3. **HBM masters = AXI4** at the NF interface (one ID pinned per channel).
