# Building a network function on VibeNIC

You are working on **VibeNIC**: an FPGA SmartNIC platform whose shell is already
built, timing-closed and loaded, and whose reconfigurable partition (RP) is the
part you write. Your job is to turn what the user asks for into a datapath that
lives in that partition — specified, written in BSV, simulated, built into a
partial bitstream, and reported on honestly.

Read this file first. It names the non-negotiables and routes you to the
document that covers whatever you are about to do. Everything it points at is
in [`deps/`](deps).

## The ground you stand on

| | |
|---|---|
| [`deps/docs/`](deps/docs) | **What is true.** The shell, the boundary contract, address maps, clocking, the floorplan, vendor IP, the BSV library, simulation, build, bring-up. Facts, not advice. |
| [`deps/prompts/`](deps/prompts) | **How to work.** The clamps. MUST means violating it breaks a build or a design and has already done so once; SHOULD is the validated default. |
| [`deps/examples/`](deps/examples) | **What is validated.** A complete network function, block-design and constraint Tcl, diagnostic scripts. Read before inventing. |
| [`deps/libs/`](deps/libs) | **What you build on.** The BSV building blocks, the vendored IP, and a read-only copy of the boundary contract. |
| [`qnic-shell/`](qnic-shell) | The shell itself, and the `make app` flow that links your partition against it. |
| [`qnic-driver/`](qnic-driver) | The host side: kernel module, DPDK library, `qnic-smi` for loading a bitstream and bringing up ports. |

**Your own work goes in `build/<design-name>/`**, one directory per design. It
is not tracked by this repository. The layout that has worked:

```
build/<name>/
  spec/     spec.md, refarch.md, test-plan.md   — write these first
  src/      BSV sources
  test/     Bluesim testbenches (pure logic)
  tests/    cocotb/ (Verilator suites) and golden/ (the Python oracle)
  bd/       rp_user.tcl — the RP block design
  xdc/      floorplan.xdc
  tcl/      app-build.tcl, pr-link-post.tcl
  utils/    pack_ip_vivado.tcl — BSV → Vivado IP
  REPORT.md what you built, what you measured, what you did not verify
```

## Non-negotiables

**Read the contract before you touch an interface.**
[`deps/libs/shell/rp_blk.v`](deps/libs/shell/rp_blk.v) is authoritative — names,
widths, directions exactly, or the abstract-shell link fails. It is explained in
[`deps/docs/02`](deps/docs/02-rp-boundary-contract.md). Three things that catch
people: `s_axil` has no `prot` and no `wstrb`; AXI-MM has no `region`; and
`tdest 0xFFF0/0xFFF1` **bypass** the partition entirely, so a packet must enter
with `tdest ≤ 0xFFEF` and something inside the partition must rewrite it to
leave toward the wire.

**Drive every boundary output.** An undriven one collides with the static side's
driver after the link (`DRC MDRV-1`). `RUN=0` does not catch this.

**BSV on the packet stream.** Dataflow logic is Bluespec, expressed as rules over
FIFOs. Never hand-wire ready/valid — the implicit conditions are the point.
→ [`deps/prompts/02`](deps/prompts/02-bsv-coding-clamp.md)

**Block Design for vendor IPs.** Anything the Xilinx catalog provides is
instantiated as catalog IP in a Tcl-generated block design, never hand-rolled in
RTL. A hand-rolled module cell's pins carry no clock metadata, and
`set_property CONFIG.FREQ_HZ` on them *silently no-ops*.
→ [`deps/prompts/03`](deps/prompts/03-vivado-bd-clamp.md)

**Simulate before you synthesise, at the tier the interface dictates.** Pure
logic → Bluesim. Anything AXI-facing or containing a BVI import → cocotb +
Verilator. Use `cocotbext-axi` agents — never hand-roll an AXI or AXI-Stream
driver or collector. Keep a byte-exact end-to-end diff against an independent
golden model green; it is the only thing pinning byte order and rounding to the
specification.
→ [`deps/prompts/04`](deps/prompts/04-simulation-mandates.md)

**Start every design from the boundary guard-slice ring**, and diagnose the
logic-vs-route split before writing any other constraint. A pblock copied from
another design is scoped to *that* design's resource mix and will fail DRC on
yours.
→ [`deps/prompts/05`](deps/prompts/05-floorplanning-and-timing.md)

**Never kill a running build to try a change**, and give every build variant its
own `PROJ` — reusing one destroys the previous run's checkpoints and with them
any chance of resuming it.
→ [`deps/prompts/00`](deps/prompts/00-workflow.md)

**Compose, don't reinvent.** Check
[`deps/docs/08`](deps/docs/08-bsv-library-catalog.md) before writing anything
generic — muxes, arbiters, AXI masters, stream adapters, CAMs and a hash table
already exist and are validated.

**Report honestly.** Post-route WNS/TNS/WHS/THS as they are; name what you did
not verify rather than leaving it implied; state your assumptions where the
specification was ambiguous, and say when the specification and the code
disagreed rather than explaining it away.

## The order of work

1. **Specify.** Three documents — what (`spec.md`), how (`refarch.md`), how it
   is shown to be right (`test-plan.md`). Ambiguity resolved on paper is orders
   of magnitude cheaper than ambiguity resolved in place-and-route.
   → [`deps/prompts/08`](deps/prompts/08-spec-authoring.md)
2. **Decompose** into stages with named interfaces, so each is testable alone.
   → [`deps/prompts/01`](deps/prompts/01-architecture-and-decomposition.md)
3. **Write and simulate**, module by module, in the correct tier. Nothing
   proceeds past a red test.
4. **Validate the block design** with `RUN=0` — seconds, and it catches address
   map and IP configuration errors that would otherwise surface hours in.
5. **Build** with `RUN=1` and a unique `PROJ`. A three-hour build is not a
   debugger.
6. **Bring up** on the card, and report.

Steps 1–4 need no Vivado and no board. Step 5 needs Vivado and a shell support
package; step 6 needs a card and the driver.

## Where to look

| Task | Read |
|---|---|
| Anything touching a shell interface | [`docs/02`](deps/docs/02-rp-boundary-contract.md) |
| Host software, register offsets | [`docs/03`](deps/docs/03-address-map-and-control.md), [`docs/15`](deps/docs/15-host-runtime-and-bringup.md) |
| Adding a clock or CDC | [`docs/04`](deps/docs/04-clocking-and-reset.md) |
| Any pblock, IP placement, timing | [`docs/05`](deps/docs/05-floorplan-au50.md) + [`prompts/05`](deps/prompts/05-floorplanning-and-timing.md) |
| Instantiating vendor IP | [`docs/07`](deps/docs/07-vendored-ip-catalog.md) + [`prompts/03`](deps/prompts/03-vivado-bd-clamp.md) |
| Writing BSV | [`docs/09`](deps/docs/09-bsv-language-essentials.md) → [`docs/10`](deps/docs/10-bsv-dataflow-handshaking.md)–[`12`](deps/docs/12-bsv-axi-transactions.md) + [`prompts/02`](deps/prompts/02-bsv-coding-clamp.md) |
| Testbenches | [`docs/13`](deps/docs/13-simulation-frameworks.md) + [`prompts/04`](deps/prompts/04-simulation-mandates.md) |
| Launching or reading a build | [`docs/14`](deps/docs/14-build-and-load-flow.md) + [`prompts/06`](deps/prompts/06-build-debug-iteration.md) |
| Turning a spec into modules | [`prompts/01`](deps/prompts/01-architecture-and-decomposition.md) |
| Writing the spec | [`prompts/08`](deps/prompts/08-spec-authoring.md) |
| A one-page check before committing | [`prompts/07`](deps/prompts/07-dos-and-donts.md) |
| A working design to read | [`examples/case-study-nf/`](deps/examples/case-study-nf/) |
| Non-au50 boards | [`docs/06`](deps/docs/06-board-deltas.md) |

## Conventions

- **`deps/libs/` is read-only in spirit.** Those are the validated building
  blocks; if one is wrong, say so rather than forking it into your design.
- **`deps/libs/shell/rp_blk.v` is read-only in fact.** It is a copy of a
  shell-supplied file; editing it here changes nothing and misleads the next
  reader. The buildable source is in [`qnic-shell/`](qnic-shell).
- **Paths in documents are relative to this tree.** No absolute host paths
  anywhere; `make check-paths` enforces it.
- **Prose rules use MUST / SHOULD.** MUST means violating it breaks a build or a
  design and has already done so once. SHOULD is the validated default —
  deviating is fine, deviating silently is not.
- **When a document and the code disagree, the code wins.** Check the source,
  then report the discrepancy.
- **Vendored IP is not above suspicion.** The corpus records several places
  where a vendored block does not do what its interface implies — it answers
  success unconditionally, or hangs instead of failing, or ignores a second
  reset. Check the RTL when behaviour surprises you.

## Verifying the tree

```bash
make check          # bsc compile + simulation + links + path hygiene
make check-bsv      # just the compile
make check-sim      # just the simulations
```

`make check-sim` needs `bsc`, Verilator and cocotb on `PATH`. Nothing here needs
Vivado except an actual FPGA build.
