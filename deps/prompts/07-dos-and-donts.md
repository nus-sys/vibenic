# Dos and don'ts

One page. Every line here cost someone a failed build, a wasted day, or a bug
that reached silicon. Links go to the reasoning.

## Interfaces

| | |
|---|---|
| ✅ | Treat [`../libs/shell/rp_blk.v`](../libs/shell/rp_blk.v) as the contract — names, widths, directions exactly. [→](../docs/02-rp-boundary-contract.md) |
| ✅ | Drive **every** boundary output, including `m_axibr` if unused. Undriven ⇒ `DRC MDRV-1` after the link. |
| ✅ | Null-tie unused HBM SAXI ports — an enabled MC's second pseudo-channel stalls the controller otherwise. |
| ✅ | Use `tuser[15:0]` for packet length; the shell already policed it. |
| ❌ | Don't assume `s_axil` has `prot` or `wstrb`, or that AXI-MM has `region`. It doesn't. |
| ❌ | Don't expect a packet with `tdest 0xFFF0/0xFFF1` to reach the RP — those bypass it. Enter with `≤ 0xFFEF`; rewrite on the way out. [→](../docs/02-rp-boundary-contract.md) |
| ❌ | Don't instantiate CMAC, QDMA, or PCIe primitives inside the RP. |

## BSV

| | |
|---|---|
| ✅ | Express dataflow as rules over FIFOs; let implicit conditions build the handshake. [→](02-bsv-coding-clamp.md) |
| ✅ | Order header structs with network headers **last** — first field packs to MSBs. |
| ✅ | `bswap16` every lane in and out of signed arithmetic; `bswap32` header fields you set. |
| ✅ | Start TLM descriptors from `defaultValue`; `b_length` = beats − 1. |
| ✅ | Chunk HBM bursts to ≤ 8 beats. |
| ✅ | Flush the tail beats of a rejected packet, or the stream desynchronises. |
| ✅ | Pin rule order with `preempts` / `descending_urgency` whenever two rules touch the same state. |
| ✅ | `mkLFIFO` where a combinational producer needs same-cycle consumption. |
| ❌ | Never hand-wire ready/valid. |
| ❌ | Don't buffer between a cuckoo table's `drain.get` and its `update.put` — it must be one atomic hop. |
| ❌ | Don't use `DReg` for a flag that must persist; it reverts next cycle. |
| ❌ | Don't rewrite a library block. Check [`../docs/08-bsv-library-catalog.md`](../docs/08-bsv-library-catalog.md) first. |
| ❌ | Don't reach for `fire_when_enabled` to silence a scheduling warning. |

## Block design

| | |
|---|---|
| ✅ | Catalog IP for anything the catalog does — `clk_wiz`, not hand-rolled `MMCME4_ADV`. [→](03-vivado-bd-clamp.md) |
| ✅ | Enumerate interface physical pins with `get_bd_pins -of_objects` — `SAXI_01`'s pins are named `AXI_01_*`. |
| ✅ | Pass **one list** to `get_bd_ports` / `get_bd_pins`, not multiple positional args. |
| ✅ | Set `ARB_ON_MAX_XFERS 0` wherever `ARB_ON_TLAST` is set — otherwise the switch re-arbitrates per beat: half throughput and frame interleaving. |
| ✅ | Cross the clock **before** changing data width; keep the register slice after the CDC. |
| ✅ | Run `make app RUN=0` after every BD edit. |
| ❌ | Don't store BD object handles in variables and re-expand them — resolve inline. |
| ❌ | Don't `set_property CONFIG.FREQ_HZ` on a module cell's pin; it silently no-ops and surfaces as `BD 41-237` elsewhere. |
| ❌ | Don't trade SmartConnect mode or outstanding depth for timing. |

## Simulation

| | |
|---|---|
| ✅ | Tier by interface: pure logic → Bluesim; anything AXI-facing or BVI → cocotb + Verilator. [→](04-simulation-mandates.md) |
| ✅ | Keep a byte-exact end-to-end golden diff green — it is the only thing pinning byte order and rounding to the spec. |
| ✅ | Check counter conservation after **every** scenario. |
| ✅ | Exercise backpressure, gapped valid, variable latency, error injection, overflow, churn, cold start, sustained rate. |
| ✅ | Warm up `2**htSizeLog2` cycles after reset before any table command — the wait scales with **your** table size, not the reference design's. [→](../docs/08-bsv-library-catalog.md) |
| ❌ | **Never hand-roll an AXI/AXIS driver or collector.** A hand-written one produced a phantom 27 % drop that cost a long investigation. |
| ❌ | Don't validate a data format against stimulus you generated from the same assumption. |
| ❌ | Don't reach step "build" with functional questions open. |

## Floorplan and timing

| | |
|---|---|
| ✅ | Start from the guard-slice ring + `EXCLUDE_PLACEMENT` guard pblocks. [→](05-floorplanning-and-timing.md) |
| ✅ | `SCOPED_TO_REF rp_blk`, idempotent XDC, `SNAPPING_MODE OFF` when nested. |
| ✅ | Read the logic-vs-route split **before** writing a constraint. |
| ✅ | Give every primitive type its own concrete site range in an RP-nested pblock. |
| ✅ | Verify a cell glob matches before launching a 3-hour build. |
| ❌ | Don't use `EXCLUDE_PLACEMENT` on a connected datapath module — it starves and repels its own neighbours. |
| ❌ | Don't use REG 10/15 where no SLR is crossed; they force LAGUNA and hurt. |
| ❌ | Don't span an SLR with a guard pblock without budgeting LAGUNA (1440 regs/column, ~700 per 512-bit crossing). |
| ❌ | Don't widen `HD.PARTPIN_RANGE` to chase timing — it kills routability. |
| ❌ | Don't read `pb_user` congestion as a resource shortage. |
| ❌ | Don't conclude closure from a router-init or post-physopt estimate. |

## Iteration

| | |
|---|---|
| ✅ | One `PROJ` per variant, always. [→](00-workflow.md) |
| ✅ | Run variants in parallel (~64 GB RAM each) rather than serially. |
| ✅ | Read intermediate timing to judge whether a run is converging. |
| ✅ | Source the right Vivado — **2023.2 for au280**, 2024.2 otherwise. |
| ❌ | **Never kill a running build to try a change.** |
| ❌ | Never relaunch over an existing `PROJ` — it destroys resumable checkpoints. |
| ❌ | Don't edit an added-by-reference file mid-run. |
| ❌ | Don't chase a benign warning. [→](06-build-debug-iteration.md) |

## Reporting

| | |
|---|---|
| ✅ | Give post-route WNS/TNS/WHS/THS and the failing-endpoint count as they are. |
| ✅ | Name what you did not verify. |
| ✅ | State assumptions where the spec was ambiguous; ask where two readings give different hardware. |
| ❌ | Don't call a design closed when timing missed. |
| ❌ | Don't report a build as successful and leave the timing miss implied. |
