# Examples

Validated code. Everything here has been through synthesis, simulation, or both
on the real platform — none of it is illustrative pseudocode. Where a snippet was
extracted from a larger design, the extraction is noted and the as-built original
is kept alongside it.

## [`case-study-nf/`](case-study-nf/) — a complete network function

The paper's HBM vector-reduce datapath for Alveo U50, **buildable in place**:
its Makefile points `bsc` at [`../libs/bsv`](../libs/bsv) and
[`../libs/verilog`](../libs/verilog), so it compiles and simulates
straight out of this tree.

```bash
cd examples/case-study-nf
make compile      # bsc -> verilog/mkVectorAvgNF.v
make bsim-all     # 7 pure-logic Bluesim testbenches
make cocotb       # all 4 cocotb suites: e2e diff, integration, stress, table
make golden       # numpy golden-model self-check
make pack_ip      # -> a Vivado IP, for the app build (needs Vivado)
```

| Directory | Contents |
|---|---|
| `spec/` | The specification, reference architecture, and test plan it was built from — worked examples of the three-document pattern in [`../prompts/08-spec-authoring.md`](../prompts/08-spec-authoring.md). |
| `src/` | 10 BSV modules: packet ingress, flow-table wrapper, dispatcher, HBM read engine, lane datapath, result egress, notification ring, control registers, shared types, and the top. |
| `test/` | 7 Bluesim testbenches (pure logic) + 1 that needs the Verilator tier. |
| `tests/cocotb/` | 4 cocotb suites and their runners. All four run in `make check`. |
| `tests/golden/` | The numpy specification oracle and its self-check. |
| `utils/` | BSV → Vivado IP packaging. |

**Read it for**: how the stages of a real datapath divide, what an AXI master
written in BSV looks like, how a BVI-wrapped hash table is driven, and how the
tests are structured per interface.

**Status is reported honestly** in the top-level [`../README.md`](../README.md):
functionally complete and byte-exact in simulation; its last U50 build misses
timing, inside the vendored table IP rather than at the partition boundary.

## [`bd/`](bd/) — block-design Tcl

| File | What it is |
|---|---|
| `hbm-subsystem.tcl` | **Extracted, parameterised.** HBM controller, Clocking Wizard, per-channel conversion path, null-ties, and status readback as reusable procs. Source it from a new app's BD generator. |
| `boundary-guard-ring.tcl` | **Extracted.** A register slice on each of au50's eight partition-pin interfaces, with the exact configuration the `rp_blk.v` contract requires — note `m_axibr`'s differs from the two AXI-MM slaves'. Which of the eight your design guards is your call; the file says so. |
| `rp-user-loopback.tcl` | **As built.** The minimal working RP: loopback plus the guard ring. The smallest complete design. |
| `rp-user-flow-reduce.tcl` | **As built.** The case study's full RP: NF, HBM subsystem, SmartConnects, scratchpad, status, guard ring. |

Start from `rp-user-loopback.tcl` for a new design and add the subsystems you
need; read `rp-user-flow-reduce.tcl` to see them assembled.

## [`xdc/`](xdc/) — floorplan constraints

| File | What it is |
|---|---|
| `guard-pblocks-au50.xdc` | **Reusable.** The MMCM LOC and the three `EXCLUDE_PLACEMENT` guard pblocks. Board-level, not design-level — every au50 app should start from it verbatim. |
| `floorplan-hbm-loopback-au50.xdc` | **As built**, closes timing (+0.020 ns). |
| `floorplan-flow-reduce-au50.xdc` | **As built.** Also carries a worked module-compaction pblock with its full diagnostic reasoning in the comments — including why it is *soft* and not `EXCLUDE_PLACEMENT`. Worth reading even if you never use it. |

Design-specific compaction pblocks are not reusable by construction: they name
a particular module. Read the reasoning, then do your own diagnosis
([`../prompts/05-floorplanning-and-timing.md`](../prompts/05-floorplanning-and-timing.md)).

## [`tcl/`](tcl/) — build flow

| File | What it is |
|---|---|
| `app-build.tcl` | The package-driven Vivado project generator an app supplies. Reads the shell support zip for the part, `rp_blk.v`, and the abstract-shell checkpoint. |
| `pr-link-post.tcl` | The `STEPS.INIT_DESIGN.TCL.POST` hook: the abstract-shell link dance, the HBM MMCM's `CLOCK_DEDICATED_ROUTE BACKBONE` exception, and a pblock property dump for verification. |

## [`scripts/`](scripts/) — diagnostics

| File | What it is |
|---|---|
| `check_axi.py` | Boundary linter: AXI port directions per the `m_`/`s_` convention, and cross-module width consistency. Run it before a build, not after one fails. |
| `congestion-report.tcl` | **New here.** Post-route triage: prints the worst paths' logic-vs-route split with a verdict per path, the congestion report, and utilisation. Answers the question you must answer before writing any floorplan constraint. |

```bash
python3 examples/scripts/check_axi.py --src-dir libs/shell
vivado -mode batch -notrace -source examples/scripts/congestion-report.tcl \
       -tclargs <routed.dcp> 10 <outdir>
```
