# Libraries

The building blocks. Compose these; do not reimplement them, and do not fork one
into your design — if something here is wrong, say so.

Annotated catalog with contracts and usage:
[`../docs/08-bsv-library-catalog.md`](../docs/08-bsv-library-catalog.md).

## [`bsv/`](bsv/) — the BSV building-block library

| File | Provides |
|---|---|
| `Axi4BusesDefines.bsv` | Bus parameter presets (HBM `6,33,512,8,0`; DDR4; XDMA bypass) and their type aliases |
| `Axi4Utilities.bsv` | TLM ↔ AXI4 transactors; FIFO-pair → master/slave adapters; burst-read expander |
| `AxisGetPut.bsv` | AXI-Stream beat types and `Get`/`Put` adapters, with and without sideband |
| `BufferedConnection.bsv` | Pipelined `Get`↔`Put` and `Client`↔`Server` connections — the timing knob between blocks |
| `CachedCuckoo.bsv` | BVI wrapper over the vendored cuckoo hash table; `mkCachedCuckooServer` is the usual entry point |
| `KvsDefines.bsv` | `KvPair`, `KvsReq`, `KvsResp` |
| `EtherDefines.bsv` | Ethernet/IPv4/UDP header structs, swap helpers, validation, `mkEtherPingbackOthers` |
| `GPMux.bsv` | `Vector#(n, Put)` → `Get` mux and its dual, round-robin or fixed-priority |
| `CAM.bsv` | Small binary CAM |
| `DebugPutSink.bsv` | `Get`/`Put` probes that tee tokens without perturbing the schedule |

Compile against them with `bsc -p <...>:libs/bsv`; see
[`../examples/case-study-nf/Makefile`](../examples/case-study-nf/Makefile).

Two contracts that will bite you if you skip them:

- **`mkCachedCuckooServer` needs ~2600 idle cycles after reset** before its first
  command — the vendored URAM banks clear their valid RAM one entry per cycle.
- **Nothing may be buffered between its `drain.get` and `update.put`.** The
  victim-reinsert path must be a single atomic hop.

## [`verilog/`](verilog/) — vendored RTL

Everything the BSV closure needs at the Verilog level:

- **The cuckoo hash-table IP**: `cached_cuckoo.sv`, `uram_cuckoo.sv`,
  `uram_bank.sv`, `cam_cache.sv`, `cuckoo_hash8_16_ultra_dsp_final.sv`,
  `hash_func.sv`, `priority_encoder.sv`, `uram_infer.v`, plus the BVI-visible
  `CachedCuckoo.v`.
- **Two Vitis-HLS-generated path hashers**: `MdsPathHasher.v`,
  `MdsPathResolveHasher.v`.
- **bsc primitive copies**: `FIFO*.v`, `SizedFIFO.v`, `BRAM*.v`, `RegFile.v`,
  `Counter.v`, `SyncResetA.v`, `MakeResetA.v`, and friends — so a Verilator or
  Vivado run resolves the closure from one `-y` directory.

Point `-y` here for simulation and add it to the app's synthesis sources.

> This IP is **not pipelined for 240 MHz**. Its victim/delmask logic runs 12–14
> logic levels at roughly 6.5 ns, which misses even at 200 MHz — the case study's
> residual timing failure is here, not in generated logic. Plan for pipelining it
> or giving it its own slower clock domain if you need closure with it.

## [`ip/`](ip/) — packaged Vivado IP

`AxisPacketRouterDual` (`pktrte_dual`, packed variant
`mkAxisPacketRouterCmac27`): a header match-action AXI-Stream router, 512-bit,
2 downstream ports, 8 entries, full throughput. The shell uses it statically per
CMAC; an RP instantiates it when it needs programmable egress steering — on
au280 that is the only way to send an RP-range packet out the wire.

Register model:
[`../docs/03-address-map-and-control.md`](../docs/03-address-map-and-control.md).
`common/` holds the bsc primitives its packaged sources reference.

## [`shell/`](shell/) — the boundary contract

**Read-only.** These are copies of files the shell support package supplies:

| File | What it is |
|---|---|
| `rp_blk.v` | **The authoritative RP boundary.** Every port name, width, and direction your design must match. Editing this copy changes nothing and misleads the next reader. |
| `board_config.au50.vh` | The au50 macro set — `HAS_2ND_QSFP`, `HAS_DDR`, `HAS_HBM` all undefined, which is why au50 has no `ethrx1` and no shell-side memory ports. |

Explained in
[`../docs/02-rp-boundary-contract.md`](../docs/02-rp-boundary-contract.md); check
your design against it with:

```bash
python3 examples/scripts/check_axi.py --src-dir libs/shell
```
