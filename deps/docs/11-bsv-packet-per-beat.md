# BSV per-beat packet processing

The header and stream utilities these patterns build on are
[`../libs/bsv/EtherDefines.bsv`](../libs/bsv/EtherDefines.bsv) and
[`../libs/bsv/AxisGetPut.bsv`](../libs/bsv/AxisGetPut.bsv); the worked ingress
and egress stages are
[`PacketIngress.bsv`](../examples/case-study-nf/src/PacketIngress.bsv) and
[`ResultEgress.bsv`](../examples/case-study-nf/src/ResultEgress.bsv).

See also [10 — Dataflow and FIFO handshaking](10-bsv-dataflow-handshaking.md) and
[12 — AXI / TLM transactions](12-bsv-axi-transactions.md).

## Bus / beat model

- A beat is `AxisBeatS#(w) { Bit#(w) data; Bit#(w/8) keep; Bool last; }` (no
  sideband) or `AxisBeatC` (adds `id`/`dest`/`user`). 100GbE CMAC = 512-bit:
  `Cmac_w`, `Cmac_nbyte`, `CmacBeat = AxisBeatS#(512)`.
- One beat moves per rule firing under the FIFO handshake discipline
  ([10 — Dataflow and FIFO handshaking](10-bsv-dataflow-handshaking.md)). The function exposes raw
  AXIS ports:
  `interface AXI4_Stream_Slave_IFC #(0,0,Cmac_w,0) eth_rx;`
  `interface AXI4_Stream_Master_IFC #(0,0,Cmac_w,0) eth_tx;`.
- Convert AXIS ↔ `Get`/`Put` of beats with `mkAxisSlaveAdapterS` /
  `mkAxisMasterAdapterS` / `mkAxisFIFOS` ([`../libs/bsv/AxisGetPut.bsv`](../libs/bsv/AxisGetPut.bsv)). Ingress
  adapter ANDs `tkeep & tstrb`.

## Header overlay via packed struct (endianness-critical)

BSV packs a struct's **first field into the MSBs**. Network bytes arrive at the
**low** bytes of the first beat, so order the struct with the network headers
as the **last** field:

```bsv
typedef struct {
    Bit#(64) user_ts; Bit#(32) rsvd; Bit#(32) resp; Bit#(32) reqid;
    Bit#(8) opcode; Bit#(8) magic;
    UdpIpEthHeader nethdr;          // <-- last field = first wire bytes
} PrstKvsPktHdr deriving (Bits, Eq, FShow);
```

`UdpIpEthHeader` itself nests `{ UdpHeader udp; IPv4Header ip; EtherHeader eth; }`
with `eth` last ([`../libs/bsv/EtherDefines.bsv`](../libs/bsv/EtherDefines.bsv)). Parse beat 0 with
`hdr = unpack(beat.data)` (or `unpack(truncate(beat.data))` when the struct is
narrower than the bus). Constants are stored little-endian
(`ipv4EtherType = 16'h0008`). Validate with `assert_udpid_hdr`. Build replies by
mutating the typed struct (`swap_eth_mac`/`swap_ip_addr`/`swap_udp_port`) then
`pack`.

## Ingress FSM skeleton (beat-counter + state enum)

State `Reg#(OpState)` (`IDLE/LUP/UPD/REM/...`) + `Reg#(UInt#(8)) eth_beatcnt`.
Each stage is a rule guarded by `state`, `beatcnt`, and admission predicates.
Universal tail:
`if (beat.last) begin state<=IDLE; beatcnt<=0; end else beatcnt<=beatcnt+1;`.

- `do_rx_init` (`state==IDLE && beatcnt==0 && inflight < limit`): decode header
  → opcode; decide accept vs drop; on accept push tracking record (into a
  cached-cuckoo / CAM / FIFO keyed by an op-id), bump in-flight counter,
  advance state.
- `do_rx_proc_key` (beat 1, admission still OK):
  `Bit#(kw) key = truncate(beat.data);` then branch per opcode to lookup /
  update / remove sub-paths; route key into the appropriate request FIFO.
- `do_rx_proc_val` (beat > 1, UPD): stream value beats out to the
  value-buffer/persist FIFOs until `beat.last`.
- `do_rx_flush_garbage` (`state==IDLE && beatcnt>0`): consume the remaining
  beats of a short/unaccepted packet so the stream stays frame-aligned
  (optionally divert to a bypass FIFO instead of dropping).

Exactly one beat consumed per firing keeps the FSM beat-accurate.

## Admission / flow control

- Gate `do_rx_init` on `inflight.value < cfgLimit` (config via `mkConfigReg` +
  `always_ready Put`); `.up` on accept, `.down` on completion in the egress
  side.
- Drop-on-full guarded by a config bool (`drop_fullprst`); otherwise natural
  backpressure via the accepted-path FIFOs.
- `mkPktLenProbe` shows wrapping a FIFO to record min/max beats per packet for
  debug without altering the dataflow.

## Egress / completion side

Decoupled Tx rules:

- First response beat carries only the op-id. Look the original header back up
  by op-id in the tracking cuckoo (`cmpl_ccht.lookup.put(opid)`), splice in a
  response code, `pack`, then
  `tx.put(AxisBeatS{data:.., keep:'1, last:!found})`.
- A follow-on rule gated by a `tx_luval_xmit` Reg streams the value beats,
  setting `last` on the final beat.
- On completion: `inflight.down` and free/evict the tracking slot
  (`ccht_updbuf.enq(tuple3(True, opid, ?))`).
- Use `preempts` to give write-completion priority over lookup-start and over
  `do_rx_init` so the egress path drains under load.

## Traffic split — reuse, don't reimplement

`mkEtherPingbackOthers(matchFn, swapOpt)` ([`../libs/bsv/EtherDefines.bsv`](../libs/bsv/EtherDefines.bsv)):

- `matchFn :: Bit#(Cmac_w) -> Bool` runs on the first beat; matching frames go
  to the module's `user` `Client#(CmacBeat,CmacBeat)`, everything else is auto
  MAC/IP/UDP-swapped and looped back out `eth_tx`.
- `swapOpt` ∈ `{ASIS, LEARN, ETH, IP, UDP}` controls how *your* egress headers
  are rewritten.
- Net effect: your function only sees its own packets and never has to forward
  unrelated traffic. Wrap its `user.request` with a probe FIFO if you want
  length stats.

## Keep/strobe handling

`axis_mask_keep` / `axis_beatc_mask_keep` zero out data bytes whose `keep` bit
is 0 — apply before hashing or storing partial last beats.
