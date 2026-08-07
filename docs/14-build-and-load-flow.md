# Build and load flow

Your build compiles **only your partition**, against a pre-implemented shell.
That is the isolation property the whole framework rests on: the shell's timing
is closed once and reused, and an iteration is a partial place-and-route, not a
full-device one. A minimal user design that takes 3.4 h built flat with the
shell closes in 47 minutes as a partition-only compile.

Working practice around long builds — parallelism, when not to kill a run, how
to resume one — is in
[`../prompts/06-build-debug-iteration.md`](../prompts/06-build-debug-iteration.md).

## The four stages

```
  BSV sources                    (examples/case-study-nf/src)
      │  bsc -verilog
      ▼
  verilog/mkYourTop.v
      │  make pack_ip            (utils/pack_ip_vivado.tcl)
      ▼
  a Vivado IP  (vendor:library:mkYourTop:1.0)
      │
      │  ┌── shell support package (.zip): part, rp_blk.v,
      │  │    board_config.vh, abstract-shell DCP
      ▼  ▼
  make app  ──►  OOC synth of rp_blk
                     │  STEPS.INIT_DESIGN.TCL.POST hook
                     ▼
                 abstract-shell link  ──►  place  ──►  route
                     │
                     ▼
                 rp_partial.bit / .bin
```

## 1. BSV → Verilog → Vivado IP

```bash
cd examples/case-study-nf
make compile      # bsc -verilog -g mkVectorAvgNF  -> verilog/mkVectorAvgNF.v
make pack_ip      # -> build/vivado_ip/component.xml
```

`pack_ip` runs [`utils/pack_ip_vivado.tcl`](../examples/case-study-nf/utils/pack_ip_vivado.tcl),
which wraps the generated Verilog as an IP with proper AXI interface inference,
so the block design can connect to it with `connect_bd_intf_net`. The IP repo
path then goes into the app build's `ip_repo_paths`.

## 2. The shell support package

An app build does **not** read the shell repository. It reads a self-describing
zip produced by the shell's `script/mk_support_pkg.py`:

```
manifest.json           git hash, shell UUID, part, board
src/rp_blk.v            the RP boundary — the contract
src/board_config.vh     HAS_2ND_QSFP / HAS_DDR / HAS_HBM macros
shell/abs_shell_*.dcp   the abstract shell checkpoint to link against
shell/*.bit             full shell bitstream
rp/*                    the default RP's partial bitstream
```

`script/prep_app_pkg.py` unpacks and validates it into `build/<PROJ>_pkg/`.
Everything after that is package-driven, which is what makes an app build
reproducible and independent of the shell tree's state.

The package name carries the shell UUID (e.g.
`au50_shell_v03_support_eac7a3b3.zip`), and `mk_app_pkg.py` tags a finished app
release with the same UUID — so an app bitstream and a shell image can always be
matched in the field. A host reading the on-card info page can tell a
monolithic image from a PR-capable shell by the UUID alone: a non-PR build
forces the UUID's low 32-bit word to `0xFFFFFFFF`.

## 3. The app build

Driven from a shell checkout:

```bash
source /tools/Xilinx/Vivado/2024.2/settings64.sh      # 2023.2 for au280
make app BOARD=au50 APP=<your-app> PROJ=<unique-name> \
     SHELL_PKG=build/au50_shell_v03_support_eac7a3b3.zip \
     RUN=1 NTHRD=16
```

| Variable | Meaning |
|---|---|
| `BOARD` | Must match the package. |
| `APP` | Directory under `app/`. |
| `PROJ` | **Vivado project name — give every build variant its own.** See below. |
| `SHELL_PKG` | The support zip. Not `SHELL` — that is a reserved make variable. |
| `RUN` | **The gate, and it defaults to 0.** `RUN=0` creates the project and validates the block design without synthesis (the fast smoke pass); `RUN=1` runs the full flow. |
| `NTHRD` | Vivado job count for the run, default 16. `RUN=0` forces it to 0 regardless. |

> `RUN` defaults to 0, so **`make app … NTHRD=16` on its own does not build** —
> it validates and exits, looking like a suspiciously fast success. The full
> flow needs `RUN=1` explicitly.

An app directory supplies four files, all copied here as examples:

| File | Role | Example |
|---|---|---|
| `build.tcl` | Package-driven project generator | [`../examples/tcl/app-build.tcl`](../examples/tcl/app-build.tcl) |
| `rp_user.tcl` | The RP block design | [`../examples/bd/`](../examples/bd/) |
| `floorplan.xdc` | Guard pblocks and any design-specific pinning | [`../examples/xdc/`](../examples/xdc/) |
| `pr_link_post_*.tcl` | `STEPS.INIT_DESIGN.TCL.POST` hook | [`../examples/tcl/pr-link-post.tcl`](../examples/tcl/pr-link-post.tcl) |

Note that `rp_blk.v` is **not** an app file under this flow — it comes from the
package and is imported.

### The link hook

The interesting step is the abstract-shell link, which runs *inside* the
implementation run via `STEPS.INIT_DESIGN.TCL.POST`:

```tcl
write_checkpoint -force rp_user_inst_linked.dcp
close_design
add_files rp_user_inst_linked.dcp
set_property SCOPED_TO_CELLS user_block_inst/rp_user_inst [get_files ...]
add_files <abs_shell_*.dcp>
link_design -top shell_top -reconfig_partitions user_block_inst/rp_user_inst
```

Anything that can only be constrained on the linked design goes here — the HBM
MMCM's `CLOCK_DEDICATED_ROUTE BACKBONE` exception being the standard case,
because the net it names only exists once the RP is folded into `shell_top`.

Then `write_bitstream -cell user_block_inst/rp_user_inst -bin_file` emits the
partial bitstream.

> **`set_property strategy` RESETS every `STEPS.*` property on a run.** Set the
> strategy **first**, then the step customisations (link hook, `-cell`,
> `BIN_FILE`). Getting this backwards routes cleanly out-of-context and then
> fails at `write_bitstream` with `HDOOC-3`, hours in.

### Give every variant its own `PROJ`

Not a style preference — a data-integrity rule. A fresh `make app` on an
existing `PROJ` **resets the project and overwrites `impl_1`**, destroying the
prior run's opt/placed/physopt/routed checkpoints. A stopped run can normally be
resumed (open the project, reset the implementation to the previous step,
relaunch — finishing just the router in 30–60 min instead of a 3 h rebuild), but
only if its `PROJ` was never reused. This was learned by losing a run that had
already closed setup.

Budget roughly **64 GB RAM per concurrent Vivado run**; routing is the
peak-memory phase.

## 4. Loading

| Artifact | Path |
|---|---|
| Full shell `.bit` | JTAG, or SPI flash for a persistent image |
| Partial `.bin` | Over PCIe through `axi_hwicap` at AXI-Lite `0x20F000` |

Partial load sequence:

1. Assert `rp_detach` (PR-control GPIO at `0x20E000`).
2. Wait for the `rpen` domain to quiesce.
3. Stream the partial `.bin` through HWICAP.
4. Deassert `rp_detach`.
5. Pulse `rp_reset`.

Everything in the RP is destroyed by this, including HBM contents behind an
RP-instantiated controller — and HBM needs ~100 ms of re-init before traffic may
flow. Poll the init-complete status bit; do not assume.

Full host-side detail is in [15](15-host-runtime-and-bringup.md).

## Editing sources while a build runs

Safe **only** for files Vivado `import_files`'d: those are copied into
`build/<PROJ>/<PROJ>.srcs/.../imports/`, so each run owns its own snapshot and
an edit to the repository source cannot reach a run already in flight. The app
`build.tcl` imports `rp_blk.v`, `floorplan.xdc`, and the link hook, so staging
the next variant's constraints while a build runs is fine.

A file **added by reference** (`add_files` / `read_xdc` on a repo path) is a
different story: constraints and RTL get re-read at opt and place, so a mid-run
edit can corrupt the running build. Copy first, or wait. When in doubt, diff the
run's `imports/` copy against the repo source.

## Before you launch

- [ ] Vivado version matches the board (2023.2 for au280).
- [ ] `make pack_ip` is current — the IP is rebuilt from the *current* BSV.
- [ ] Boundary slice configs match `rp_blk.v` ([02](02-rp-boundary-contract.md)).
      `RUN=0` does not catch a mismatch.
- [ ] Every unused RP output is tied off ([02](02-rp-boundary-contract.md)).
- [ ] The design passes simulation
      ([`../prompts/04-simulation-mandates.md`](../prompts/04-simulation-mandates.md)).
      A 3 h build is not a debugger.
- [ ] `PROJ` is unique.
