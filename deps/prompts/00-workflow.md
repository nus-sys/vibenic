# Workflow

How an iteration is shaped, and where the time goes. The governing fact: a
place-and-route pass costs **hours**, so wall time per iteration is not a
productivity property here — it is a correctness property. You get a
few-attempts budget on hardware, and you spend it on things simulation cannot
answer.

## The loop

```
  1. Read the contract        docs/02, and the spec you were given
  2. Decompose                prompts/01  -> stages, interfaces, sizing
  3. Implement + unit-test    per module, at the tier prompts/04 dictates
  4. Integrate + e2e test     byte-exact against a golden model
  5. Block design             prompts/03  -> rp_user.tcl, tie-offs
  6. Smoke                    make app RUN=0  (BD validates, no synthesis)
  7. Build                    make app RUN=1  -> OOC synth, link, place, route
  8. Read the result          prompts/06  -> is it real, and what is it saying
```

Steps 3 and 4 are where correctness is established. Steps 7 and 8 answer
questions about *physics*: does it fit, does it close, where is the congestion.
Arriving at step 7 with functional questions still open is the main way this
process goes wrong.

The case study ran exactly this loop: plan the decomposition, implement each
submodule with its own tests, validate modules in Bluesim and AXI boundaries in
cocotb **before any synthesis**, then three place-and-route attempts — each a
partition-only compile.

## Rules

**MUST: simulate before you synthesise.** A 3-hour build is not a debugger. The
mandates in [04](04-simulation-mandates.md) are the entry condition for step 7,
not a nice-to-have.

**MUST: never kill a running build to try a change.** Let it finish; apply the
new idea to the next iteration. This is not politeness about compute — the
intermediate timing in the implementation log (post-place, post-physopt,
router-init `Estimated/Intermediate Timing Summary` lines) is *itself the data
you are trying to obtain*, and a run is usually closer to done than it looks. A
run was once killed 2h20m in to try a variant; it had already closed setup
(post-physopt WNS +0.003, router-init +0.129 from an original −2.423) with only
hold left, which the router fixes. That threw away both 2.5 hours and the
near-final result.

**MUST: give every build variant its own `PROJ`.** Reusing a `PROJ` does not
merely collide on a directory — a fresh `make app` resets the project and
overwrites `impl_1`, destroying the previous run's opt/placed/physopt/routed
checkpoints. With a distinct `PROJ`, a stopped run stays resumable: open the
project, reset the implementation to the previous step, relaunch, and finish
just the router in 30–60 minutes instead of rebuilding for 3 hours. Reuse it and
that option is gone. (Learned by losing a run this exact way.)

**SHOULD: run variants in parallel instead of serially.** One machine hosts
several Vivado runs at once; budget **≈ 64 GB RAM per run** for Alveo
UltraScale+ and launch as many as `n_runs × 64 GB ≤ machine RAM` with headroom.
Each gets its own `PROJ` and its own log. Routing is the peak-memory phase.

**SHOULD: stage the next variant while the current one runs — carefully.** Safe
only for files Vivado `import_files`'d (each run owns a snapshot under
`build/<PROJ>/.srcs/.../imports/`). A file added *by reference* would be re-read
at opt and place, corrupting the in-flight run. Verify by diffing the run's
`imports/` copy against the source.

## Decomposition and parallel work

Decompose into stages with explicit interfaces before writing any of them
([01](01-architecture-and-decomposition.md)). If you are farming submodules out
to parallel workers, the interface contracts must be pinned *first* — the
contracts are what let independent work compose, and re-negotiating them
afterwards costs more than the parallelism saved.

Each submodule arrives with its own testbench. A submodule that is "done" but
untested is not done; it is a claim.

## Budget and expectations

Orders of magnitude from the case study — one UDP vector-reduce NF, as vendored
in [`../examples/case-study-nf/`](../examples/case-study-nf/): 1,828 lines of
BSV across 10 modules, 796 lines of block-design Tcl, and 4,336 lines of tests
(8 unit testbenches, 4 cocotb suites, and the golden model) — about 2.4 lines
of test per line of design:

| Phase | Cost |
|---|---|
| BSV typecheck | seconds |
| Bluesim unit test | seconds |
| cocotb + Verilator test | seconds to a couple of minutes |
| `make app RUN=0` (BD validate) | minutes |
| Full build (HBM design, au50) | ~1–3 h; place-and-route dominates |
| Place-and-route attempts to a working design | 3 |

Plan around that shape. Ten cheap simulation iterations before one expensive
build is the correct ratio, not a sign of over-caution.

## Reporting

**MUST: disclose what is not closed.** If timing misses, say so with the number.
If a scenario is untested, say which. If you deferred a bug, name it. The case
study's own honest record — functionally complete and byte-exact in simulation,
**timing not met** at 240 MHz because the vendored hash-table IP was never
pipelined for it — is more useful to the next person than a claim of closure
would have been.

**MUST: surface assumptions rather than guess silently.** Where the
specification is ambiguous, state the interpretation you took. Where two
readings would produce materially different hardware, ask.
