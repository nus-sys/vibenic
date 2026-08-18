"""
End-to-end hit-path test for mkVectorAvgNF (cocotb + Verilator).

Cold-start scenario (spec §2, test-plan scenario 1), driving the RAW bsc top
(no BD): bit-banged AXIS + AXI-Lite + 3 HBM read-slave models + m_axibr
write-slave. Verifies the WHOLE NF — ingress → flowtable → dispatcher → 3 HBM
reads → pipelined averager → result egress — by diffing the emitted C2H packet
byte-for-byte against the numpy golden.

  1. reset + URAM-wipe warmup; AXI-L: CTRL.enable=1, NOTIFY ring programmed
  2. send packet for an uninstalled flow  -> MISS: 32-B notification on m_axibr
  3. preload 3 HBM slave models with golden reference vectors
  4. AXI-L upsert the flow entry (key = NF-parsed 5-tuple, val = offsets+ident)
  5. resend the packet -> HIT: 3 HBM reads -> average -> result on m_axis_rpout
  6. diff result packet vs vecavg_golden.compute_result; check §7 counters

bsc flat AXI names (uppercase suffix): hbm_axi_N_{ARADDR,ARLEN,ARID,ARVALID,
ARREADY,RDATA,RID,RRESP,RLAST,RVALID,RREADY,...}; m_axibr_{AW*,W*,B*};
s_axil_{AR/AW/W/R/B*}; s_axis_rpin_/m_axis_rpout_ t*.
"""
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "golden"))
import numpy as np
import vecavg_golden as g

SETTLE = Timer(100, units="ps")
WARMUP = 2600
TO = 8000

CNT_RX, CNT_DROP_FILTER = 0x80, 0x84
CNT_HIT, CNT_MISS = 0x88, 0x8C
CNT_PROCESSED, CNT_HBM_ERR = 0x90, 0x94
CNT_NOTIFY_DROP = 0x98
# spec §7 scratch / command / notify-ring regs
R_CTRL = 0x00
R_TBL_KEY0, R_TBL_KEY1, R_TBL_KEY2, R_TBL_KEY3 = 0x10, 0x14, 0x18, 0x1C
R_TBL_VCH0, R_TBL_VCH2, R_TBL_VCH4, R_TBL_VFID = 0x20, 0x24, 0x28, 0x2C
R_TBL_CMD = 0x30
R_NBASE_LO, R_NBASE_HI, R_NSIZE, R_NTAIL = 0x40, 0x44, 0x48, 0x50

OFF_CH = {0: 0x0000_0800, 1: 0x2000_0800, 2: 0x4000_0800}   # per-chan HBM addr
NOTIFY_BASE = 0x0001_0000
NOTIFY_SIZE_LOG2 = 4


async def step(dut):
    await RisingEdge(dut.CLK)
    await SETTLE


def beats_to_bytes(beats):
    return b"".join(int(b).to_bytes(64, "little") for b in beats)


def bytes_to_beat(bs):
    return int.from_bytes(bs, "little")


async def reset(dut):
    dut.RST_N.value = 0
    for s in ("s_axis_rpin_tvalid", "s_axis_rpin_tlast", "s_axil_ARVALID",
              "s_axil_RREADY", "s_axil_AWVALID", "s_axil_WVALID",
              "s_axil_BREADY"):
        getattr(dut, s).value = 0
    for s in ("s_axis_rpin_tdata", "s_axis_rpin_tkeep", "s_axis_rpin_tstrb",
              "s_axis_rpin_tid", "s_axis_rpin_tdest", "s_axis_rpin_tuser",
              "s_axil_ARADDR", "s_axil_AWADDR", "s_axil_WDATA", "s_axil_WSTRB"):
        getattr(dut, s).value = 0
    dut.m_axis_rpout_tready.value = 1
    # HBM read-slave: accept AR immediately, no writes expected
    for n in (0, 1, 2):
        getattr(dut, f"hbm_axi_{n}_ARREADY").value = 1
        getattr(dut, f"hbm_axi_{n}_AWREADY").value = 1
        getattr(dut, f"hbm_axi_{n}_WREADY").value = 1
        getattr(dut, f"hbm_axi_{n}_BVALID").value = 0
        getattr(dut, f"hbm_axi_{n}_RVALID").value = 0
    # m_axibr write-slave: accept AW/W, no reads expected
    dut.m_axibr_AWREADY.value = 1
    dut.m_axibr_WREADY.value = 1
    dut.m_axibr_BVALID.value = 0
    dut.m_axibr_ARREADY.value = 1
    dut.m_axibr_RVALID.value = 0
    for _ in range(12):
        await RisingEdge(dut.CLK)
    dut.RST_N.value = 1
    for _ in range(WARMUP):                 # cuckoo uram_bank valid-wipe
        await RisingEdge(dut.CLK)
    await SETTLE


# ---- AXI-Lite master (bit-banged, flat uppercase names) --------------------
async def axil_write(dut, addr, val):
    dut.s_axil_AWADDR.value = addr
    dut.s_axil_AWVALID.value = 1
    dut.s_axil_WDATA.value = val
    dut.s_axil_WSTRB.value = 0xF
    dut.s_axil_WVALID.value = 1
    gaw = gw = False
    for _ in range(TO):
        await step(dut)
        if not gaw and dut.s_axil_AWREADY.value == 1:
            dut.s_axil_AWVALID.value = 0
            gaw = True
        if not gw and dut.s_axil_WREADY.value == 1:
            dut.s_axil_WVALID.value = 0
            gw = True
        if gaw and gw:
            break
    dut.s_axil_BREADY.value = 1
    for _ in range(TO):
        await step(dut)
        if dut.s_axil_BVALID.value == 1:
            break
    dut.s_axil_BREADY.value = 0


async def axil_read(dut, addr):
    dut.s_axil_ARADDR.value = addr
    dut.s_axil_ARVALID.value = 1
    for _ in range(TO):
        await step(dut)
        if dut.s_axil_ARREADY.value == 1:
            break
    dut.s_axil_ARVALID.value = 0
    dut.s_axil_RREADY.value = 1
    data = 0
    for _ in range(TO):
        await step(dut)
        if dut.s_axil_RVALID.value == 1:
            data = int(dut.s_axil_RDATA.value)
            break
    dut.s_axil_RREADY.value = 0
    return data


# ---- AXIS source (s_axis_rpin) --------------------------------------------
async def send_packet(dut, pkt):
    full = (1 << 64) - 1
    for i in range(9):
        dut.s_axis_rpin_tdata.value = bytes_to_beat(pkt[i * 64:(i + 1) * 64])
        dut.s_axis_rpin_tkeep.value = full
        dut.s_axis_rpin_tstrb.value = full
        dut.s_axis_rpin_tlast.value = 1 if i == 8 else 0
        dut.s_axis_rpin_tvalid.value = 1
        for _ in range(TO):
            await step(dut)
            if dut.s_axis_rpin_tready.value == 1:
                break
    dut.s_axis_rpin_tvalid.value = 0
    dut.s_axis_rpin_tlast.value = 0


# ---- AXIS sink (m_axis_rpout) — background collector ----------------------
async def egress_collector(dut, out):
    while True:
        await step(dut)
        if dut.m_axis_rpout_tvalid.value == 1 and dut.m_axis_rpout_tready.value == 1:
            out["beats"].append(int(dut.m_axis_rpout_tdata.value))
            if dut.m_axis_rpout_tlast.value == 1:
                out["pkts"].append(out["beats"])
                out["beats"] = []


# ---- 3x HBM read-slave models ---------------------------------------------
async def hbm_read_slave(dut, n, mem):
    """Respond to NF read bursts on hbm_axi_n from a {addr: bytes512} model."""
    ar = lambda s: getattr(dut, f"hbm_axi_{n}_{s}")
    while True:
        await step(dut)
        if ar("ARVALID").value == 1 and ar("ARREADY").value == 1:
            addr = int(ar("ARADDR").value)
            alen = int(ar("ARLEN").value)
            aid = int(ar("ARID").value)
            for k in range(alen + 1):
                blk = mem.get(addr + k * 64, b"\x00" * 64)
                ar("RDATA").value = bytes_to_beat(blk)
                ar("RID").value = aid
                ar("RRESP").value = 0
                ar("RLAST").value = 1 if k == alen else 0
                ar("RVALID").value = 1
                for _ in range(TO):
                    await step(dut)
                    if ar("RREADY").value == 1:
                        break
            ar("RVALID").value = 0
            ar("RLAST").value = 0


# ---- m_axibr write-slave (capture notifications) --------------------------
# Order-independent: latch AW and W as they arrive (AWREADY/WREADY tied 1),
# issue B once both seen, record (addr, wdata0). Handles any AW/W interleave
# and back-to-back writes.
async def notify_write_slave(dut, caps):
    aw_seen = w_seen = False
    addr = 0
    wd = 0
    awid = 0
    while True:
        await step(dut)
        if not aw_seen and dut.m_axibr_AWVALID.value == 1 \
                and dut.m_axibr_AWREADY.value == 1:
            addr = int(dut.m_axibr_AWADDR.value)
            awid = int(dut.m_axibr_AWID.value)
            aw_seen = True
        if not w_seen and dut.m_axibr_WVALID.value == 1 \
                and dut.m_axibr_WREADY.value == 1:
            wd = int(dut.m_axibr_WDATA.value)
            w_seen = True
        if aw_seen and w_seen:
            dut.m_axibr_BVALID.value = 1
            dut.m_axibr_BRESP.value = 0
            dut.m_axibr_BID.value = awid
            for _ in range(TO):
                await step(dut)
                if dut.m_axibr_BREADY.value == 1:
                    break
            dut.m_axibr_BVALID.value = 0
            caps.append((addr, wd))
            aw_seen = w_seen = False


async def settle(dut, n):
    for _ in range(n):
        await RisingEdge(dut.CLK)
    await SETTLE


@cocotb.test()
async def vecavg_e2e_coldstart(dut):
    cocotb.start_soon(Clock(dut.CLK, 10, units="ns").start())
    await reset(dut)

    egr = {"beats": [], "pkts": []}
    hbm_mem = {0: {}, 1: {}, 2: {}}
    notif = []
    cocotb.start_soon(egress_collector(dut, egr))
    for n in (0, 1, 2):
        cocotb.start_soon(hbm_read_slave(dut, n, hbm_mem[n]))
    cocotb.start_soon(notify_write_slave(dut, notif))

    # ---- enable + program notification ring --------------------------------
    await axil_write(dut, R_CTRL, 0x1)
    await axil_write(dut, R_NBASE_LO, NOTIFY_BASE & 0xFFFFFFFF)
    await axil_write(dut, R_NBASE_HI, NOTIFY_BASE >> 32)
    await axil_write(dut, R_NSIZE, NOTIFY_SIZE_LOG2)
    await axil_write(dut, R_NTAIL, 0)

    # ---- build the flow's packet (fixed 5-tuple, known query vector) -------
    qvec = np.arange(-128, 128, dtype=np.int16)
    qvec = np.tile(qvec, 1)[:256].astype(np.int16)
    pkt = g.build_ingress_packet(payload_vec=qvec, client_ts=0x1122334455667788)
    pkt = bytes(pkt)

    # NF-parsed 5-tuple: every multibyte IP/UDP field is read little-endian of
    # its wire bytes by the bsc header struct (same rule as total_len).
    src_ip = int.from_bytes(pkt[26:30], "little")
    dst_ip = int.from_bytes(pkt[30:34], "little")
    src_pt = int.from_bytes(pkt[34:36], "little")
    dst_pt = int.from_bytes(pkt[36:38], "little")
    proto = pkt[23]
    assert proto == 17, f"proto {proto} != 17"

    FLOW_IDENT = 0x0000_00AB

    # ---- (1) MISS: flow not installed -> notification, no egress ----------
    await send_packet(dut, pkt)
    await settle(dut, 1500)        # cuckoo lookup + miss + notify AXI write
    assert len(egr["pkts"]) == 0, "miss must not emit a result"
    assert (await axil_read(dut, CNT_MISS)) == 1, "CNT_MISS != 1 after miss"
    assert (await axil_read(dut, CNT_NOTIFY_DROP)) == 0, "notification dropped"
    assert len(notif) == 1, f"expected 1 notification, got {len(notif)}"
    naddr, ndata = notif[0]
    assert naddr == NOTIFY_BASE, f"notify addr {naddr:#x} != {NOTIFY_BASE:#x}"
    nbytes = ndata.to_bytes(64, "little")[:32]
    # spec §8: src_ip@0 dst_ip@4 src_port@8 dst_port@10 proto@12 (network order
    # = the raw wire bytes; the NF stores the parsed values directly)
    assert int.from_bytes(nbytes[0:4], "little") == src_ip, "notify src_ip"
    assert int.from_bytes(nbytes[4:8], "little") == dst_ip, "notify dst_ip"
    assert nbytes[12] == 17, "notify proto"
    dut._log.info("(1) miss -> notification captured & decoded OK")

    # ---- (2) preload HBM reference vectors --------------------------------
    rng = np.random.default_rng(0xC0FFEE)
    refs = {c: rng.integers(-2000, 2000, size=256).astype(np.int16)
            for c in (0, 2, 4)}
    chan_idx = {0: 0, 2: 1, 4: 2}     # cuckoo off_ch0/2/4 -> hbm_axi_0/1/2
    for c in (0, 2, 4):
        blk = g.vector_to_hbm_bytes(refs[c])
        base = OFF_CH[chan_idx[c]]
        for k in range(8):
            hbm_mem[chan_idx[c]][base + k * 64] = blk[k * 64:(k + 1) * 64]

    # ---- (3) install the flow entry via AXI-L upsert ----------------------
    await axil_write(dut, R_TBL_KEY0, src_ip)
    await axil_write(dut, R_TBL_KEY1, dst_ip)
    await axil_write(dut, R_TBL_KEY2, (src_pt << 16) | dst_pt)
    await axil_write(dut, R_TBL_KEY3, proto << 24)
    await axil_write(dut, R_TBL_VCH0, OFF_CH[0])
    await axil_write(dut, R_TBL_VCH2, OFF_CH[1])
    await axil_write(dut, R_TBL_VCH4, OFF_CH[2])
    await axil_write(dut, R_TBL_VFID, FLOW_IDENT)
    await axil_write(dut, R_TBL_CMD, (1 << 31) | 0)     # commit, op=upsert
    await settle(dut, 300)                              # cuckoo absorb

    # ---- (4) resend -> HIT -> result --------------------------------------
    await send_packet(dut, pkt)
    await settle(dut, 800)
    assert len(egr["pkts"]) == 1, f"hit must emit 1 result, got {len(egr['pkts'])}"
    got = beats_to_bytes(egr["pkts"][0])
    assert len(got) == 576, f"result len {len(got)} != 576"

    # ---- (5) golden compare ----------------------------------------------
    # Golden keys the table on its OWN network-order parse of the packet
    # (independent of the NF's little-endian-of-wire struct key used for the
    # hardware TBL_KEY_* registers above).
    gkey, gok = g._parse_five_tuple(pkt)
    assert gok, "golden filtered the test packet"
    table = {g.make_table_key(*gkey): {
        "flow_ident": FLOW_IDENT, "ref0": refs[0], "ref2": refs[2],
        "ref4": refs[4]}}
    exp, _, _ = g.compute_result(pkt, table, sequence_num=0)
    assert exp is not None, "golden returned drop for the hit packet"
    if got != exp:
        for off in range(0, 576, 16):
            if got[off:off+16] != exp[off:off+16]:
                dut._log.error(f"  byte {off}: got {got[off:off+16].hex()} "
                               f"exp {exp[off:off+16].hex()}")
        assert False, "result packet != golden"
    dut._log.info("(4) hit -> result packet byte-exact vs numpy golden OK")

    # ---- (6) counter conservation (spec §7) -------------------------------
    rx = await axil_read(dut, CNT_RX)
    df = await axil_read(dut, CNT_DROP_FILTER)
    hit = await axil_read(dut, CNT_HIT)
    miss = await axil_read(dut, CNT_MISS)
    proc = await axil_read(dut, CNT_PROCESSED)
    herr = await axil_read(dut, CNT_HBM_ERR)
    assert rx == 2 and df == 0 and hit == 1 and miss == 1 and proc == 1, \
        f"counters RX={rx} DF={df} HIT={hit} MISS={miss} PROC={proc}"
    assert rx == df + hit + miss, "conservation RX != DF+HIT+MISS"
    assert hit == proc + herr, "conservation HIT != PROC+HBM_ERR"
    dut._log.info("(5) counters + conservation OK")
    dut._log.info("PASS mkVectorAvgNF e2e: cold-start miss->install->hit")
