# Prompts

The soft policy layer. [`../docs/`](../docs/) tells you what is true; these tell
you how to work. They exist because the design space this shell exposes is
deliberately large — nearly everything stays reconfigurable — and a large space
leaves generation underdetermined. Every unvetted microarchitectural choice is a
fresh opportunity to invent something that has never been built here.

So these documents spend **guidance density**: they clamp generation to patterns
that are known to work on this platform, and they say plainly which rules are
mandatory and which are defaults you may argue with. They restrict *habits*, not
capability.

Three clamps carry most of the weight:

- **BSV on the packet stream.** Dataflow logic is written in Bluespec with
  FIFO-implicit handshaking. → [02](02-bsv-coding-clamp.md)
- **Block Design for vendor IPs.** Anything the Xilinx catalog provides is
  instantiated as catalog IP in a block design, never hand-rolled in RTL.
  → [03](03-vivado-bd-clamp.md)
- **Simulate before you synthesise, at the tier the interface dictates.**
  → [04](04-simulation-mandates.md)

## Which one to load

| Task | Read |
|---|---|
| Starting a project; planning an iteration budget | [00 — Workflow](00-workflow.md) |
| Turning a specification into modules | [01 — Architecture and decomposition](01-architecture-and-decomposition.md) |
| Writing or reviewing BSV | [02 — BSV coding clamp](02-bsv-coding-clamp.md) |
| Writing `rp_user.tcl` or any block-design Tcl | [03 — Vivado BD clamp](03-vivado-bd-clamp.md) |
| Planning or writing tests | [04 — Simulation mandates](04-simulation-mandates.md) |
| Writing a pblock; chasing timing | [05 — Floorplanning and timing](05-floorplanning-and-timing.md) |
| Reading a build log; a run failed | [06 — Build and debug iteration](06-build-debug-iteration.md) |
| Any time — a one-page check | [07 — Dos and don'ts](07-dos-and-donts.md) |
| Writing the specification itself | [08 — Spec authoring](08-spec-authoring.md) |

## How to read a rule here

- **MUST** — violating it produces a broken build, a broken design, or a wasted
  multi-hour run. Each one is here because it already cost someone that.
- **SHOULD** — the validated default. Deviating is allowed; deviating silently
  is not. Say what you are doing differently and why.
- Everything else is context for judgement.

If a rule conflicts with the specification you were given, the specification
wins and you say so. If a rule conflicts with what the code actually does,
**the code wins** — check
[`../libs/shell/rp_blk.v`](../libs/shell/rp_blk.v) and the sources, and report
the discrepancy.
