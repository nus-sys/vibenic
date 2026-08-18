# Build and debug iteration

Reading a build's output correctly is a skill with a measurable cost of failure:
chasing a benign warning wastes an afternoon, and missing a real one wastes a
build. This document is the triage.

Flow mechanics: [`../docs/14-build-and-load-flow.md`](../docs/14-build-and-load-flow.md).
On-silicon debug: [`../docs/15-host-runtime-and-bringup.md`](../docs/15-host-runtime-and-bringup.md).

## Known-benign — do not chase these

Verified against known-good routed runs.

| Message | Cause | Benign because |
|---|---|---|
| `Vivado 12-795` "pblock already exists" (×N pblocks) | The guard XDC is applied twice — captured into the RP checkpoint, re-applied at the link | Idempotent re-apply. **The count should equal your pblock count** — treat it as a checksum. |
| `Common 17-55` / `Constraints 18-512/513` XPM CDC, `xpm_memory_xdc` | IP-internal XDC scoped to cells absent in this link context | The static side is locked; those constraints were applied at shell build. |
| `Constraints 18-1067` PPLOC congestion in `pb_user` | Shell-fixed partpin density | Informational. It is the canary for route congestion, not something you act on from the app. |
| `TIMING-17` "non-clocked sequential cell" (~1000 criticals, au280) | Static logic across CDCs from the RP whose GT-derived clock roots are pruned from the abstract shell | Those cells are locked — placed, routed and timed at shell build. |
| `BD 41-1306` "connection overridden" | The unused-SAXI null-tie | Intentional. |
| `BD 41-1356` direct master→port unassigned segment | Direct port connection | Intentional. |
| `Vivado 12-4431` stream partpin outside the AXI-MM guard | The stream partpins are in a different region | Places freely; correct. |
| `Constraints 18-5685` child pblock before parent | Ordering of pblock creation | Does not reassign — verify `GRID_RANGES` in the post-link pblock dump. |

## Not benign — stop and investigate

- Any **`HDPR-*`** critical.
- **`Route 35-54`** or **`Route 35-4445`**, especially during *initial* routing.
  (`Route 35-447` with a *shrinking* overlap count across global iterations is
  the router recovering and is fine; the same message during initial routing is
  not.)
- A **`TIMING-17`** naming an `rp_user_i/...` cell — that is your logic, not the
  pruned static side.
- Any **critical during `write_bitstream`**.
- A **`12-795` count that does not match your pblock count** — something in the
  floorplan changed shape.
- A **boundary-interface timing probe that returns no path**
  (`report_timing -through` the partpin nets of each interface).
- **`HDOOC-3` at `write_bitstream`** after a clean route — you set
  `set_property strategy` *after* the `STEPS.*` customisations, and it reset
  them. Set the strategy first.
- **`Place 30-718`** on the HBM MMCM — the `CLOCK_DEDICATED_ROUTE BACKBONE`
  exception is missing from the post-link hook.
- **`DRC MDRV-1`** with flip-flop outputs and GND driving one net — an undriven
  RP boundary output.

## Reading timing

**MUST: judge only the post-`route_design` summary.** Intermediate
"Estimated Timing Summary" lines at post-place, post-physopt and router-init are
leading indicators that the router can and does unwind — see the A/B in
[05](05-floorplanning-and-timing.md), where both variants showed setup met at
router-init and finished at about −1.17 ns.

But **do read them while the run is in flight**: they tell you whether a run is
converging, which is exactly the information you need in order *not* to kill it.

**MUST: report WNS, TNS, WHS, THS and the failing-endpoint count**, not "timing
closed" or "nearly closes". If it misses, name the worst path and its
logic-vs-route split.

## When a run is in progress

**MUST NOT: kill it to try a change.** Detailed reasoning in
[00 — Workflow](00-workflow.md); the short version is that a run killed 2h20m in
had already closed setup and was 30–60 minutes from a bitstream, and both the
time and the result were lost.

**SHOULD: launch the variant in parallel** with its own `PROJ` and its own log
if RAM allows (≈ 64 GB per run). Otherwise queue it.

**MUST: never relaunch over an existing `PROJ`.** It resets the project and
overwrites `impl_1`, destroying the checkpoints that would have let you resume.

### Resuming a stopped run

Only possible if the `PROJ` was never reused:

```
open the project
reset the implementation run to the previous completed step
relaunch
```

Finishing just the router takes 30–60 minutes against a 3-hour rebuild.

### Editing sources mid-run

Safe **only** for files Vivado `import_files`'d — each run holds its own
snapshot under `build/<PROJ>/.srcs/.../imports/`, so editing the source cannot
reach a run in flight. Files added *by reference* (`add_files` / `read_xdc` on a
repo path) are re-read at opt and place, and a mid-run edit corrupts the run.
Copy first or wait. Verify by diffing the run's `imports/` copy against the
source.

## Debugging on silicon

The framework is built so that a failed attempt is cheap. Use that.

- **A faulty RP cannot hang the DMA IP or the host driver** — DMA-sensitive
  metadata is policed shell-side. You get wrong packets, not a wedged machine.
- **The board resets under VFIO**; a bad partial costs a reload and minutes.
- **Flow redirection keeps the wire alive with no RP, or a broken one, loaded.**
  Reprogram `pkt_route_0` to send traffic to the host and debug from there.
- **Read the per-entry packet counters before adding an ILA.** They answer "did
  the frame match", "did it enter the RP", "did it come back" for the cost of
  two register reads. `pkt_route_0` entry 1 at `0x208028`/`0x20802C`; the RP
  router's at `0x08200028`/`0x0820002C`.
- **A JTAG debug bridge** is available through the RP's `S_BSCAN` ports when you
  genuinely need in-fabric visibility.

## Triage order for a failed build

1. **Errors first**, then criticals, then the not-benign list above. Ignore the
   benign table entirely.
2. **If it is a link/DRC failure** — check the boundary: slice configs against
   `rp_blk.v`, every output driven, cell-name globs matching.
3. **If it is a routing failure** — was it *initial* routing (real: geometry or
   LAGUNA) or global iterations with shrinking overlap (the router working)?
4. **If it is timing** — get the logic-vs-route split and the congestion report
   before touching a constraint ([05](05-floorplanning-and-timing.md)).
5. **If it is functional** — you should not be here. Go back to simulation
   ([04](04-simulation-mandates.md)); a build is not a debugger.

## What to report

- The post-route numbers, as they are.
- Which criticals appeared and which you classified benign, with the reason.
- What you changed between attempts, one variable at a time where possible.
- What you did *not* verify.

An honest "misses timing at −2.4 ns, worst paths inside the vendored table IP,
not at the partition boundary" is a useful result. "Builds successfully" when
timing missed is not.
