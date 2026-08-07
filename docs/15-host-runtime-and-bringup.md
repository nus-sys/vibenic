# Host runtime and bring-up

The shell is a working NIC before your logic exists, and stays one after your
logic breaks. That property is what makes bring-up tractable: a failed attempt
costs a partial reload and minutes, not a reboot.

## The NIC, as the host sees it

The static shell alone presents a standard DPDK-capable NIC: QDMA queues for
host DMA, a 100 GbE CMAC on the wire, ~18 Mpps DMA and sub-3 µs round-trip —
comparable to a commercial NIC. Host software binds it through VFIO; a card
reset is a VFIO reset, not a machine reboot.

Traffic reaches the host with **no RP loaded and no RP required**: `rpen` gating
keeps a detached or blank partition from stalling any path.

- **Receive (wire → host).** `pkt_route_N` by default forwards received frames
  out `m_axis_0` with a host-range `tdest`, so `nicsw` delivers them to QDMA
  C2H. Frames it steers out `m_axis_1` go into the RP instead.
- **Transmit (host → wire).** The host writes a packet through a QDMA H2C queue;
  `h2c_dst_trans_i` stamps the AXI-Stream `tdest` from the descriptor.
  `0xFFF0` reaches CMAC0, `0xFFF1` CMAC1, `≤ 0xFFEF` goes into the RP.

## Bring-up order

1. **Sanity-check the shell.** Read `bsver` from the PR-control GPIO at
   `0x20E000`; it must return `0xabcd1234`.
2. **Bring CMAC0 up.** Standard Xilinx CMAC AXI-Lite sequence at `0x310000`,
   per PG203. The per-CMAC sub-map is not board-portable — use PG203, not a
   constant copied from another project.
3. **Program the steering** (below).
4. **Open QDMA queues** from the host, descriptor mode, fixed-size or variable.
   The QDMA AXI-Stream adapter already aligns sizes and packs to
   `MAX_PKT_LEN = 9600`.
5. **Load your partial bitstream** if it is not already resident, and
   **re-initialise anything the reconfiguration destroyed** — notably HBM.

## Steering traffic through the RP

With an unmodified shell, host register writes alone can route traffic *through*
the RP. This is the primary way to exercise a datapath on silicon.

Three programmable blocks are involved, across **two different host windows**:

| Block | Where |
|---|---|
| `pkt_route_0` (`AxisPacketRouterDual`, CMAC0) | AXI-Lite `0x208000` |
| `h2c_dst_trans_i` (`AxisDestTrans`) | AXI-Lite `0x20C000` |
| the RP's own `AxisPacketRouterDual_0` | **QDMA AXI-MM `0x08200000`** — via BAR4 or an MM DMA, *not* the AXI-Lite crossbar |

> Remember the bypass trap: `tdest 0xFFF0`/`0xFFF1` make `h2c_sw` skip the RP
> entirely. A packet must enter the RP with `tdest ≤ 0xFFEF`, and something
> *inside* the RP must rewrite the egress `tdest` to `0xFFF0` for it to leave
> toward the wire. And the RP must be attached — do not leave `rp_detach`
> asserted.

### RX (port 0) → RP → host (C2H)

Path: `eth_rx_0 → pkt_route_0.m_axis_1 → ethrx0 → RP → rpout0 → nicsw.M00 →
QDMA C2H`. Only `pkt_route_0` needs programming; the stock RP already loops to
the host.

Reprogram **entry 1** — at reset its mask is zero, and a zero mask matches
everything, so entry 1 is what is actually steering your traffic (writing entry
0 alone does nothing):

```
wr 0x208020 = 0x0000_0001   # entry1 word0: downstream port = 1 (m_axis_1 -> RP)
wr 0x208024 = 0x0000_0000   # entry1 word1: tdest = 0x0000 (host range)
```

### H2C → RP → wire (port 0)

Path: `H2C → h2c_dst_trans_i → h2c_sw.M01 → rph2c → RP →
AxisPacketRouterDual_0 (rewrites tdest = 0xFFF0) → rpout0 → nicsw.M01 →
eth_tx_0`.

```
# (a) force H2C into the RP range so it does not bypass  — AXI-Lite window
wr 0x20C004 = 0xFFFF_0000   # DEFAULT_TRANS: mask=0xFFFF value=0x0000 -> tdest -> 0

# (b) make the RP emit a CMAC0-TX tdest        — QDMA AXI-MM window
wr 0x08200020 = 0x0000_0000 # RP entry1 word0: rpout port = 0
wr 0x08200024 = 0x0000_FFF0 # RP entry1 word1: egress tdest = 0xFFF0 (CMAC0 TX)
```

au50 and au55c can do this with their stock RP. **au280 cannot** — its stock RP
egress is a fixed switch with no `tdest` rewrite. Load a custom RP carrying an
`AxisPacketRouterDual` (the `au280_lb_guard` reference app is exactly that) and
it works there too.

### Confirm the loop actually traversed the RP

Do not infer it from the fact that packets arrived. Read the per-entry match
counters:

- `pkt_route_0` entry 1: `0x208028` / `0x20802C` (low / high)
- RP router entry 1: `0x08200028` / `0x0820002C`

## Getting data into device memory

For an RP-instantiated HBM, the host has two routes, and they address the same
bytes:

- **BAR4** (`s_axi_pcie`) — direct load/store, good for small pokes and
  registers.
- **QDMA MM descriptors** (`s_axi_dma`) — bulk transfer, the right tool for
  preloading a working set.

Because the lateral switch is off and each SAXI's window is fixed at `NN × PC`,
the host preload path and your read masters see the **same fixed offsets**. An
offset stored in an on-chip table is therefore an HBM-absolute byte address for
both sides. Preserve that symmetry in your own designs — it removes a whole
class of host/device disagreement.

The pseudo-channel size differs by part: 256 MB on 8 GB (au50, au280), 512 MB on
16 GB (au55c).

## Partial reconfiguration from the host

```
assert rp_detach        (GPIO 0x20E000)
wait for the rpen domain to quiesce
stream the partial .bin through axi_hwicap at 0x20F000
deassert rp_detach
pulse rp_reset
```

Then, before any traffic:

- **Re-initialise HBM.** Reconfiguration destroys the controller's state; it
  needs ~100 ms of init/scrub. Poll `init_complete` — the reference designs
  expose it (and `cattrip`) on an `axi_gpio` so you never have to touch APB for
  this. See `vnd_hbm_status` in
  [`../examples/bd/hbm-subsystem.tcl`](../examples/bd/hbm-subsystem.tcl).
- **Re-program your control registers.** Everything in the RP is gone.
- **Re-check the steering** if your RP owns a router.

## Debugging on silicon

The framework's containment properties, and how to use them:

- **A faulty RP cannot hang the DMA IP or the host driver.** DMA-sensitive
  metadata — packet size, destination — is policed shell-side. Hallucinated user
  logic produces wrong packets, not a wedged machine.
- **Flow redirection lets host software drive the Ethernet port with no RP, or a
  broken one, loaded.** Reprogram `pkt_route_0` to send traffic to the host
  instead of the RP and the wire keeps working while you investigate.
- **The board resets under VFIO.** A failed attempt costs a reload and minutes.
- **The per-entry packet counters are the cheapest observability you have.**
  Before adding an ILA, ask whether a counter delta already answers the
  question: did the frame match the entry, did it enter the RP, did it come
  back.
- **A JTAG debug bridge is available** through the RP's `S_BSCAN` ports if you
  do need in-fabric visibility.

## What is not in this corpus

The host userspace driver itself. This document is the NIC-side contract:
register offsets, sequences, and what the hardware guarantees. Sequences here
have been exercised against the reference designs; a driver built on them is a
separate deliverable.
