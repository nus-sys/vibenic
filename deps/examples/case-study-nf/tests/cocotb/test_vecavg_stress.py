"""
Hit-path pressure / backpressure test for mkVectorAvgNF (cocotb + Verilator).

Install one flow, preload the 3 HBM reference vectors, then push many
distinct-payload packets through the HIT path:

  Phase 1 — N1 packets back-to-back at full rate (tvalid never drops between
            beats or packets), egress always ready, HBM zero-latency.
  Phase 2 — N2 packets with random ingress gaps, random m_axis_rpout_tready
            backpressure, and variable HBM-slave RVALID latency.

Every emitted result packet is checked, IN ORDER, byte-for-byte against the
numpy golden (sequence_num = k); no packet may be lost, duplicated or
reordered. This exercises the per-beat FSMs (ingress BODY, dispatcher FWD_PL,
the 2-stage averager, egress HDR/VEC, HBM response reassembly + the top
RRESP-gate) and every FIFO's backpressure path.
"""
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer, ReadOnly, NextTimeStep
from cocotbext.axi import AxiStreamBus, AxiStreamSink

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "golden"))
import numpy as np
import vecavg_golden as g

SETTLE = Timer(100, units="ps")
WARMUP = 2600
TO = 8000
N1 = 24            # back-to-back full rate
N2 = 24            # with gaps + backpressure + HBM latency

CNT_RX, CNT_DROP_FILTER = 0x80, 0x84
CNT_HIT, CNT_MISS = 0x88, 0x8C
CNT_PROCESSED, CNT_HBM_ERR = 0x90, 0x94
R_CTRL = 0x00
R_TBL_KEY0, R_TBL_KEY1, R_TBL_KEY2, R_TBL_KEY3 = 0x10, 0x14, 0x18, 0x1C
R_TBL_VCH0, R_TBL_VCH2, R_TBL_VCH4, R_TBL_VFID = 0x20, 0x24, 0x28, 0x2C
R_TBL_CMD = 0x30

OFF_CH = {0: 0x0000_0800, 1: 0x2000_0800, 2: 0x4000_0800}
FLOW_IDENT = 0x0000_0042


async def step(dut):
    await RisingEdge(dut.CLK)
    await SETTLE


def b2beat(bs):
    return int.from_bytes(bs, "little")


def beats2bytes(beats):
    return b"".join(int(b).to_bytes(64, "little") for b in beats)


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
    for n in (0, 1, 2):
        getattr(dut, f"hbm_axi_{n}_ARREADY").value = 1
        getattr(dut, f"hbm_axi_{n}_AWREADY").value = 1
        getattr(dut, f"hbm_axi_{n}_WREADY").value = 1
        getattr(dut, f"hbm_axi_{n}_BVALID").value = 0
        getattr(dut, f"hbm_axi_{n}_RVALID").value = 0
    dut.m_axibr_AWREADY.value = 1
    dut.m_axibr_WREADY.value = 1
    dut.m_axibr_BVALID.value = 0
    dut.m_axibr_ARREADY.value = 1
    dut.m_axibr_RVALID.value = 0
    for _ in range(12):
        await RisingEdge(dut.CLK)
    dut.RST_N.value = 1
    for _ in range(WARMUP):
        await RisingEdge(dut.CLK)
    await SETTLE


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


async def send_packet(dut, pkt, gap_rng=None):
    """Drive 9 beats; gap_rng (an RNG) -> 0..3 bubble cycles between beats."""
    full = (1 << 64) - 1
    for i in range(9):
        if gap_rng is not None:
            for _ in range(int(gap_rng.integers(0, 4))):
                dut.s_axis_rpin_tvalid.value = 0
                await step(dut)
        dut.s_axis_rpin_tdata.value = b2beat(pkt[i * 64:(i + 1) * 64])
        dut.s_axis_rpin_tkeep.value = full
        dut.s_axis_rpin_tstrb.value = full
        dut.s_axis_rpin_tlast.value = 1 if i == 8 else 0
        dut.s_axis_rpin_tvalid.value = 1
        ok = False
        for _ in range(TO):
            await step(dut)
            if dut.s_axis_rpin_tready.value == 1:
                ok = True
                break
        assert ok, f"s_axis_rpin stalled >{TO} cyc on beat {i} (ingress bp)"
    dut.s_axis_rpin_tvalid.value = 0
    dut.s_axis_rpin_tlast.value = 0


# NOTE: the egress is collected with cocotbext-axi AxiStreamSink (see the test
# body). A prior hand-rolled "egress_collector" that drove tready itself and
# sampled in ReadOnly mis-scored transfers by one cycle under backpressure,
# producing a spurious ~27% "header drop" that the NF does not actually have.


async def hbm_read_slave(dut, n, mem, lat):
    """Read-burst responder; lat[0] = max random pre-burst latency cycles."""
    p = lambda s: getattr(dut, f"hbm_axi_{n}_{s}")
    rng = np.random.default_rng(0x5A5A + n)
    while True:
        await step(dut)
        if p("ARVALID").value == 1 and p("ARREADY").value == 1:
            addr = int(p("ARADDR").value)
            alen = int(p("ARLEN").value)
            aid = int(p("ARID").value)
            for _ in range(int(rng.integers(0, lat[0] + 1))):
                await step(dut)
            for k in range(alen + 1):
                p("RDATA").value = b2beat(mem.get(addr + k * 64, b"\x00" * 64))
                p("RID").value = aid
                p("RRESP").value = 0
                p("RLAST").value = 1 if k == alen else 0
                p("RVALID").value = 1
                for _ in range(TO):
                    await step(dut)
                    if p("RREADY").value == 1:
                        break
            p("RVALID").value = 0
            p("RLAST").value = 0


async def settle(dut, n):
    for _ in range(n):
        await RisingEdge(dut.CLK)
    await SETTLE


@cocotb.test()
async def vecavg_stress(dut):
    cocotb.start_soon(Clock(dut.CLK, 10, units="ns").start())
    await reset(dut)

    hbm_mem = {0: {}, 1: {}, 2: {}}
    hbm_lat = [0]                       # phase-1: zero HBM latency
    bp_en = [False]                     # phase-2 flips this on
    # Egress sink: cocotbext-axi AxiStreamSink (test-plan §2). Backpressure is
    # gated by bp_en through the pause generator (phase 1 = always ready; phase 2
    # = ~45% random pause). A correctly-timed sink is REQUIRED here: the previous
    # hand-rolled egress_collector mis-scored transfers by one cycle under
    # backpressure, which manifested as a spurious ~27% "header drop" the NF does
    # NOT have (confirmed: with AxiStreamSink the NF is byte-exact, 432/432 beats
    # under backpressure + HBM latency).
    import random as _random
    _rbp = _random.Random(7)
    sink = AxiStreamSink(AxiStreamBus.from_prefix(dut, "m_axis_rpout"),
                         dut.CLK, dut.RST_N, reset_active_level=False)
    sink.set_pause_generator(iter(lambda: bp_en[0] and _rbp.random() < 0.45, object()))
    for n in (0, 1, 2):
        cocotb.start_soon(hbm_read_slave(dut, n, hbm_mem[n], hbm_lat))

    await axil_write(dut, R_CTRL, 0x1)

    # fixed flow; vary payload per packet
    base_pkt = bytes(g.build_ingress_packet(payload_vec=np.zeros(256, np.int16)))
    src_ip = int.from_bytes(base_pkt[26:30], "little")
    dst_ip = int.from_bytes(base_pkt[30:34], "little")
    src_pt = int.from_bytes(base_pkt[34:36], "little")
    dst_pt = int.from_bytes(base_pkt[36:38], "little")
    proto = base_pkt[23]

    rng = np.random.default_rng(0xBEEF)
    refs = {c: rng.integers(-3000, 3000, size=256).astype(np.int16)
            for c in (0, 2, 4)}
    cidx = {0: 0, 2: 1, 4: 2}
    for c in (0, 2, 4):
        blk = g.vector_to_hbm_bytes(refs[c])
        for k in range(8):
            hbm_mem[cidx[c]][OFF_CH[cidx[c]] + k * 64] = blk[k * 64:(k + 1) * 64]

    # install the flow entry
    await axil_write(dut, R_TBL_KEY0, src_ip)
    await axil_write(dut, R_TBL_KEY1, dst_ip)
    await axil_write(dut, R_TBL_KEY2, (src_pt << 16) | dst_pt)
    await axil_write(dut, R_TBL_KEY3, proto << 24)
    await axil_write(dut, R_TBL_VCH0, OFF_CH[0])
    await axil_write(dut, R_TBL_VCH2, OFF_CH[1])
    await axil_write(dut, R_TBL_VCH4, OFF_CH[2])
    await axil_write(dut, R_TBL_VFID, FLOW_IDENT)
    await axil_write(dut, R_TBL_CMD, (1 << 31) | 0)
    await settle(dut, 300)

    gkey, ok = g._parse_five_tuple(base_pkt)
    assert ok
    table = {g.make_table_key(*gkey): {
        "flow_ident": FLOW_IDENT, "ref0": refs[0], "ref2": refs[2],
        "ref4": refs[4]}}

    # build the N1+N2 distinct-payload packets + their golden results
    N = N1 + N2
    pvr = np.random.default_rng(0x1234)
    pkts, golds = [], []
    for k in range(N):
        qv = pvr.integers(-30000, 30000, size=256).astype(np.int16)
        pk = bytes(g.build_ingress_packet(payload_vec=qv,
                                          client_ts=0x1000 + k))
        ex, _, _ = g.compute_result(pk, table, sequence_num=k)
        assert ex is not None, f"golden dropped pkt {k}"
        pkts.append(pk)
        golds.append(ex)

    # Phase 1 — back-to-back, no backpressure, zero HBM latency
    for k in range(N1):
        await send_packet(dut, pkts[k])
    # Phase 2 — gaps + egress backpressure + variable HBM latency
    bp_en[0] = True
    hbm_lat[0] = 7
    gap = np.random.default_rng(0x99)
    for k in range(N1, N):
        await send_packet(dut, pkts[k], gap_rng=gap)
    bp_en[0] = False

    # drain: wait for the AxiStreamSink to collect all N frames
    for _ in range(TO):
        await settle(dut, 50)
        if sink.count() >= N:
            break
    nq = sink.count()
    frames = [bytes((await sink.recv()).tdata) for _ in range(nq)]
    ncol = len(frames)

    # NF-internal accounting (read regardless, for diagnosis).
    rx = await axil_read(dut, CNT_RX)
    df = await axil_read(dut, CNT_DROP_FILTER)
    hit = await axil_read(dut, CNT_HIT)
    miss = await axil_read(dut, CNT_MISS)
    proc = await axil_read(dut, CNT_PROCESSED)
    herr = await axil_read(dut, CNT_HBM_ERR)
    dut._log.info(f"collected={ncol}/{N}  CNT_RX={rx} DF={df} HIT={hit} "
                  f"MISS={miss} PROC={proc} HBM_ERR={herr}")

    # Beat accounting: NF emits 9 beats/pkt (1 hdr + 8 vec). total_beats == N*9
    # with N tlast-delimited frames == NF emitted every beat correctly.
    grp = [len(f) // 64 for f in frames]
    tot = sum(grp)
    from collections import Counter as _C
    dut._log.info(f"BEATACCT total_beats={tot} expect={N*9} "
                  f"groups={ncol} tail_partial=0 "
                  f"len_hist={dict(_C(grp))} "
                  f"first_bad_idx={next((i for i,n in enumerate(grp) if n!=9), None)}")

    assert ncol == N, f"expected {N} result pkts, got {ncol} (loss/stall; PROC={proc})"

    for k in range(N):
        assert len(frames[k]) == 576, f"pkt {k} len {len(frames[k])}"
        if frames[k] != golds[k]:
            for off in range(0, 576, 16):
                if frames[k][off:off+16] != golds[k][off:off+16]:
                    dut._log.error(
                        f"pkt {k} byte {off}: got "
                        f"{frames[k][off:off+16].hex()} "
                        f"exp {golds[k][off:off+16].hex()}")
            assert False, f"result pkt {k} != golden (seqnum/order/datapath)"
    dut._log.info(f"({N}) result packets byte-exact & in-order vs golden OK")

    assert rx == N and df == 0 and hit == N and miss == 0 and proc == N, \
        f"counters RX={rx} DF={df} HIT={hit} MISS={miss} PROC={proc} (N={N})"
    assert rx == df + hit + miss and hit == proc + herr, "conservation"
    dut._log.info("counters + conservation OK")
    dut._log.info(f"PASS mkVectorAvgNF stress: {N} hits "
                  f"(backpressure + gaps + HBM latency)")
