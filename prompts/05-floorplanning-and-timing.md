# Floorplanning and timing

Constraints are expensive to get wrong: each attempt costs a place-and-route
pass. So the ordering rule dominates everything else here — **diagnose first,
constrain second.** Most bad floorplans come from constraining before knowing
what the problem was.

Device map: [`../docs/05-floorplan-au50.md`](../docs/05-floorplan-au50.md).
Diagnosis tool: [`../examples/scripts/congestion-report.tcl`](../examples/scripts/congestion-report.tcl).

## Start with the guard ring, always

**MUST: put an RP-side register slice on every partition-pin interface, and pin
each into an `EXCLUDE_PLACEMENT` guard pblock hugging its partpin column.** This
is not a remedy for a timing failure — it is the baseline every design starts
from. It registers each RP↔static crossing at the pin and pushes the rest of the
RP off the congested edge.

Cells: [`../examples/bd/boundary-guard-ring.tcl`](../examples/bd/boundary-guard-ring.tcl).
Constraints: [`../examples/xdc/guard-pblocks-au50.xdc`](../examples/xdc/guard-pblocks-au50.xdc).

Without it, the `rpout` egress crossing alone left the HBM loopback design at
−0.026 ns. With it, that design closes at +0.020 ns.

Mechanics that are each mandatory:

- **`SCOPED_TO_REF rp_blk` + `used_in_synthesis false`.** The static block design
  contains identically-named register slices; an unscoped
  `get_cells -hierarchical` match hits both.
- **Keep the XDC idempotent.** It is evaluated twice — captured into the RP
  checkpoint, then re-applied at the abstract-shell link. That produces one
  `Vivado 12-795` "pblock already exists" critical **per pblock**. No `-remove`,
  no statement whose second application diverges. Treat the 12-795 count as a
  checksum: a different count means something changed.
- **`SNAPPING_MODE OFF` on any pblock nested inside a CLOCKREGION-defined
  parent.** With default snapping the nested SLICE range collapses to empty
  (`HDPR-14` / `HDPR-18`).
- **Verify the cell glob matches before launching.** A silent zero-match wastes
  the whole run. `llength [get_cells -hierarchical -filter {...}]` first.

## Then diagnose before doing anything else

**MUST: read the worst path's logic-vs-route split before writing a single
constraint.** `report_timing` prints it directly:
`Data Path Delay: … (logic X% route Y%)`.

| Reading | Meaning | Response |
|---|---|---|
| logic ≫ route, many levels | genuinely too deep | pipeline the logic. A pblock will not help. |
| route ≫ logic (> ~60 %) | badly placed or congested | floorplan it. Pipelining will not help. |

The case study's worst path was **79.5 % route, 1.34 ns of logic over 12
levels** — a placement problem that looks like a depth problem if you only read
the level count. The signature of congestion is a low logic percentage combined
with fanout-1 nets burning 0.3–0.7 ns where an uncongested one costs ~0.05.

**MUST: identify the saturated resource.** `report_design_analysis -congestion`
on the routed checkpoint names the congested window's cells and what ran out. In
the case study every window was the cuckoo table with **URAM at 100 %** — the
table's URAM column fully packed, with its associative victim-cache logic wedged
against it. That tells you the fix is to *over-provision* URAM sites, which is
not a conclusion you would reach from a timing report alone.

## Choosing a pblock kind

**MUST: use a SOFT (non-exclusive) pblock for a chunky, connected module.** It
merely *attracts* the module's cells to a roomy region with the resources it
needs, while still letting neighbours — including logic wired to it — share the
area. Nothing is starved or repelled.

**MUST NOT: use `EXCLUDE_PLACEMENT` on a connected datapath module.** It has a
severe adverse effect: (a) space the pinned module does not use is denied to
everyone else, making *their* timing harder, and (b) it repels neighbouring
logic, including logic directly connected to the pinned module — lengthening
exactly the nets you were trying to shorten.

`EXCLUDE_PLACEMENT` is correct for the tiny boundary guard strips above, which
hold only their own few slices by design, and for a genuinely self-contained,
timing-critical block that cannot meet timing any other way. That is the whole
list.

**SHOULD: size a soft pblock LOOSE and over-provision the scarce resource.** The
point is decongestion, not packing. The case study's flow table (~0.8–1.2 k logic
slices) got a ~6.8 k-slice region — 15–20 % utilisation — with URAM sites
over-provisioned 2× so the placer never packs URAMs against each other. Use
clock-region columns that actually carry the resource; a URAM-less column just
wastes the pblock.

**SHOULD: consider a non-exclusive *guide* pblock before anything heavier.**
They are cheap and surprisingly powerful — pinning an AXI SmartConnect into the
SLR between its clients took au280 from WNS −0.2 to positive at placement.

## RP-nested pblock mechanics

A pblock inside the `HD.RECONFIGURABLE` partition has extra rules:

- **MUST: give concrete site ranges for EVERY primitive type the cells use** —
  `SLICE` for LUT/FF/CARRY/MUXF/SRL, plus `URAM288` / `RAMB*` / `DSP48*` as
  applicable. A bare `CLOCKREGION` range is **rejected**: `DRC HDPR-18`,
  thousands of "SLICE range needs to be added". Get device extents with
  `link_design -part <part>` and `get_sites -of [get_clock_regions X Y]` — no
  design needed.
- **MUST: `SNAPPING_MODE OFF`**, so the exact ranges are kept and Vivado parents
  the pblock directly under `pb_user` by geometric containment. Default
  `NESTED` snapping once parented a module pblock into a *guard* pblock instead
  → `DRC HDPR-14` "no common ancestor". Keep the module pblock's ranges clear of
  the guard rectangles.
- **SHOULD: match the whole module in one shot** —
  `add_cells_to_pblock <pb> [get_cells -hierarchical -filter {NAME =~ "*rp_user_i*<mod>/inst/<sub>"}]`.
  One hierarchical cell pulls in all its leaves.

## SLR crossings

**MUST: use REG modes 10/15 only where an SLR boundary is really crossed.** They
mandate LAGUNA primitives; elsewhere they force a hop that makes timing worse.
Check whether the producer and consumer pblocks actually straddle the boundary —
on au50 that is Y3 ↔ Y4.

**MUST: budget LAGUNA before assuming a crossing will route.** One column = 240
sites × 6 = **1440 registers**; one 512-bit AXI4 `REG=10` crossing consumes
~700. Oversubscribe and the next slice silently spills into a CLB straddle whose
control nets need impossible fabric SLR crossings — `route_design` then dies
during *initial* routing (`Route 35-4445`, unroutable `aresetn`/handshake nets),
immune to directives. Without the budget, do not span the boundary at all: split
the guard per SLR.

## Things not to do

**MUST NOT: trade a SmartConnect's mode or outstanding-transaction depth for
timing.** Relieve congestion by floorplanning.

**MUST NOT: widen `HD.PARTPIN_RANGE` / `PARTPIN_SPREADING` to chase RP timing.**
It was tried; it kills routability through congestion and was reverted. Keep
partpins tight.

**MUST NOT: read `pb_user` congestion as a resource shortage.** The pblock is
huge and the RP is small by construction. Congestion there means the static
floorplan or partpin geometry has squeezed the RP's shape — investigate the
boundary, not your own utilisation.

**MUST NOT: copy a resource-range compaction pblock (e.g. `pb_ft`) from
another design without checking what resource types your own cells actually
use.** The case study's `pb_ft` ranges `SLICE` and `URAM288` only, because
that design's flow-table state lives in URAM. A different flow-table
instantiation whose entry state (or the vendored table's own
`ram_style="block"` valid arrays) lands in `BRAM`/`RAMB` instead will fail
DRC (`HDPR-18`, cells outside every range in the pblock they're assigned to)
before place even starts — on a design where no congestion had even been
observed yet. This is the same "diagnose before constraining" rule below,
sharpened: a pblock that closed timing for the reference design is scoped to
*that* design's resource mix, not a template to carry forward. Measure your
own design's congestion (or lack of it) before reapplying someone else's fix.

## Post-router-init timing is not the answer

**MUST: judge only the final `report_timing_summary` after `route_design`** (or
the `Physopt 32-669` post-route physical-optimisation summary that follows it).

> On the case study, a soft `pb_ft` and an `EXCLUDE` `pb_ft` — same cells, same
> ranges, only the exclusivity differing — both showed **setup met** at
> router-init (+0.129 / +0.052 ns, TNS 0, from an original −2.423). Both then
> **degraded during Phase 5 Rip-up-And-Reroute** and finished essentially tied:
> −1.169 vs −1.178 ns, a 0.009 ns difference, i.e. noise. The routed worst path
> had moved *inside* the table's own victim-cache logic — congestion intrinsic
> to that submodule's associative compare/broadcast nets, which no module-level
> pblock can fix because it is not about the module's position relative to its
> neighbours.
>
> An "Estimated Timing Summary" at post-place, post-physopt, or router-init is
> a leading indicator, not a result. Do not report closure from one, and do not
> abandon a run because of one.

**A separate axis worth knowing:** on that same A/B, `route_design` took
**1h37m for EXCLUDE vs 3h41m for soft**, almost entirely in rip-up-and-reroute,
for statistically tied final timing. If two candidates converge to the same QoR,
the more constrained legal region routes faster. That is a legitimate tiebreaker
for *runtime* — it does not change the placement guidance above.

## When the fix is not a constraint

If the worst path is deep logic inside a module — high logic percentage, 12+
levels — no floorplan will close it. The answer is pipelining, or moving that
module to its own slower clock domain with a CDC. The case study's residual
−2.423 ns is exactly this: the vendored cuckoo IP's victim/delmask logic runs
~6.5 ns of data-path delay, which misses even at 200 MHz. Recognise it and say
so rather than iterating constraints against physics.

## Before you constrain

- [ ] Guard ring present, `SCOPED_TO_REF`, idempotent, `SNAPPING_MODE OFF`
      where nested.
- [ ] `12-795` count equals the pblock count.
- [ ] Every cell glob verified to match exactly what you intended.
- [ ] Logic-vs-route split read on the routed checkpoint.
- [ ] Congested resource identified.
- [ ] Pblock kind chosen by the rule above, not by habit.
- [ ] Every primitive type the cells use has a concrete range.
- [ ] REG=10/15 only on real SLR crossings, with LAGUNA budgeted.
- [ ] You are judging a post-route number.
