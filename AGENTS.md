# Working in this repository

This is the VibeNIC DEPs corpus — Documentation, Examples, and Prompts for
building FPGA SmartNIC datapaths on the VibeNIC shell. If you are developing a
network function against this shell, read this file first.

The design space here is deliberately large: the shell exposes nearly everything
and restricts almost nothing. What follows are the clamps that make that space
tractable. They restrict *habits*, not capability.

## Non-negotiables

**Read the contract before you touch an interface.**
[`libs/shell/rp_blk.v`](libs/shell/rp_blk.v) is authoritative — names, widths,
directions exactly, or the abstract-shell link fails. It is explained in
[`docs/02-rp-boundary-contract.md`](docs/02-rp-boundary-contract.md). Three
things that catch people: `s_axil` has no `prot` and no `wstrb`; AXI-MM has no
`region`; and `tdest 0xFFF0/0xFFF1` **bypass** the partition entirely, so a
packet must enter with `tdest ≤ 0xFFEF` and something inside the partition must
rewrite it to leave toward the wire.

**Drive every boundary output.** An undriven one collides with the static side's
driver after the link (`DRC MDRV-1`). `RUN=0` does not catch this.

**BSV on the packet stream.** Dataflow logic is Bluespec, expressed as rules over
FIFOs. Never hand-wire ready/valid — the implicit conditions are the point.
→ [`prompts/02-bsv-coding-clamp.md`](prompts/02-bsv-coding-clamp.md)

**Block Design for vendor IPs.** Anything the Xilinx catalog provides is
instantiated as catalog IP in a Tcl-generated block design, never hand-rolled in
RTL. A hand-rolled module cell's pins carry no clock metadata, and
`set_property CONFIG.FREQ_HZ` on them *silently no-ops*.
→ [`prompts/03-vivado-bd-clamp.md`](prompts/03-vivado-bd-clamp.md)

**Simulate before you synthesise, at the tier the interface dictates.** Pure
logic → Bluesim. Anything AXI-facing or containing a BVI import → cocotb +
Verilator (`verilator --cc`; iverilog cannot parse the vendored SV and
`--binary --timing` needs C++20). Use `cocotbext-axi` agents — never hand-roll
an AXI or AXI-Stream driver or collector. Keep a byte-exact end-to-end diff
against an independent golden model green; it is the only thing pinning byte
order and rounding to the specification.
→ [`prompts/04-simulation-mandates.md`](prompts/04-simulation-mandates.md)

**Start every design from the boundary guard-slice ring**, and diagnose the
logic-vs-route split before writing any other constraint.
→ [`prompts/05-floorplanning-and-timing.md`](prompts/05-floorplanning-and-timing.md)

**Never kill a running build to try a change**, and give every build variant its
own `PROJ` — reusing one destroys the previous run's checkpoints and with them
any chance of resuming it.
→ [`prompts/00-workflow.md`](prompts/00-workflow.md)

**Compose, don't reinvent.** Check
[`docs/08-bsv-library-catalog.md`](docs/08-bsv-library-catalog.md) before
writing anything generic — muxes, arbiters, AXI masters, stream adapters, CAMs
and a hash table already exist and are validated.

**Report honestly.** Post-route WNS/TNS/WHS/THS as they are; name what you did
not verify; state your assumptions where the specification was ambiguous.

## Where to look

| Task | Read |
|---|---|
| Anything touching a shell interface | [`docs/02`](docs/02-rp-boundary-contract.md) |
| Host software, register offsets | [`docs/03`](docs/03-address-map-and-control.md), [`docs/15`](docs/15-host-runtime-and-bringup.md) |
| Adding a clock or CDC | [`docs/04`](docs/04-clocking-and-reset.md) |
| Any pblock, IP placement, timing | [`docs/05`](docs/05-floorplan-au50.md) + [`prompts/05`](prompts/05-floorplanning-and-timing.md) |
| Instantiating vendor IP | [`docs/07`](docs/07-vendored-ip-catalog.md) + [`prompts/03`](prompts/03-vivado-bd-clamp.md) |
| Writing BSV | [`docs/09`](docs/09-bsv-language-essentials.md) → [`docs/10`](docs/10-bsv-dataflow-handshaking.md)–[`12`](docs/12-bsv-axi-transactions.md) + [`prompts/02`](prompts/02-bsv-coding-clamp.md) |
| Testbenches | [`docs/13`](docs/13-simulation-frameworks.md) + [`prompts/04`](prompts/04-simulation-mandates.md) |
| Launching or reading a build | [`docs/14`](docs/14-build-and-load-flow.md) + [`prompts/06`](prompts/06-build-debug-iteration.md) |
| Turning a spec into modules | [`prompts/01`](prompts/01-architecture-and-decomposition.md) |
| Writing the spec | [`prompts/08`](prompts/08-spec-authoring.md) |
| A one-page check before committing | [`prompts/07`](prompts/07-dos-and-donts.md) |
| A working design to read | [`examples/case-study-nf/`](examples/case-study-nf/) |
| Non-au50 boards | [`docs/06`](docs/06-board-deltas.md) |

## Conventions in this repository

- **`libs/` is read-only in spirit.** Those are the validated building blocks; if
  one is wrong, say so rather than forking it into your design.
- **`libs/shell/rp_blk.v` is read-only in fact.** It is a copy of a
  shell-supplied file; editing it here changes nothing and misleads the next
  reader.
- **Paths in documents are relative to this tree.** Absolute host paths appear
  only in [`PROVENANCE.md`](PROVENANCE.md); `make check-paths` enforces that.
- **Prose rules use MUST / SHOULD.** MUST means violating it breaks a build or a
  design and has already done so once. SHOULD is the validated default —
  deviating is fine, deviating silently is not.
- **When a document and the code disagree, the code wins.** Check the source,
  then report the discrepancy.

## Verifying the tree

```bash
make check          # bsc compile + simulation + links + path hygiene
make check-bsv      # just the compile
make check-sim      # just the simulations
```

`make check-sim` needs `bsc`, Verilator, and cocotb on `PATH`; nothing here
needs Vivado except an actual FPGA build.
