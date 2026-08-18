"""
Top-level integration smoke for mkVectorAvgNF (cocotb + Verilator).

Scope (matches the agreed "core" verification depth): exercise the integrated
ingress -> flowtable -> dispatcher -> ctrlregs/counters path end-to-end and the
spec §7 counter-conservation law, without modeling the HBM / notify AXI slaves
(the hit datapath — averager / HBM read / egress byte-map — is covered by the
per-module sims + the numpy golden).

  * filter-drop : a non-IPv4 packet -> CNT_RX++ , CNT_DROP_FILTER++ , no egress
  * miss        : a valid UDP packet for an uninstalled flow -> CNT_RX++ ,
                  CNT_MISS++ , no egress (NotifyEngine drives m_axibr; with no
                  slave it just stalls, which does not gate CNT_MISS)
  * conservation: CNT_RX == CNT_DROP_FILTER + CNT_HIT + CNT_MISS
                  CNT_HIT == CNT_PROCESSED + CNT_HBM_ERR

bsc port conventions: AXIS slave s_axis_rpin_{tdata,tkeep,tstrb,tlast,tid,
tdest,tuser,tvalid,tready}; AXI4-Lite slave flat s_axil_{ARADDR,ARVALID,
ARREADY,RDATA,RVALID,RRESP,RREADY,...}.  mkFlowTable's vendor uram_bank wipes
its valid RAM ~1024 cyc/bank after reset -> long warmup before traffic.
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
TIMEOUT = 4000

# spec §7 register offsets
CNT_RX, CNT_DROP_FILTER = 0x80, 0x84
CNT_HIT, CNT_MISS = 0x88, 0x8C
CNT_PROCESSED, CNT_HBM_ERR = 0x90, 0x94


async def step(dut):
    await RisingEdge(dut.CLK)
    await SETTLE


async def reset(dut):
    dut.RST_N.value = 0
    dut.s_axis_rpin_tvalid.value = 0
    dut.s_axis_rpin_tdata.value = 0
    dut.s_axis_rpin_tkeep.value = 0
    dut.s_axis_rpin_tstrb.value = 0
    dut.s_axis_rpin_tlast.value = 0
    dut.s_axis_rpin_tid.value = 0
    dut.s_axis_rpin_tdest.value = 0
    dut.s_axis_rpin_tuser.value = 0
    dut.m_axis_rpout_tready.value = 1
    dut.s_axil_ARADDR.value = 0
    dut.s_axil_ARVALID.value = 0
    dut.s_axil_ARPROT.value = 0
    dut.s_axil_RREADY.value = 0
    dut.s_axil_AWADDR.value = 0
    dut.s_axil_AWVALID.value = 0
    dut.s_axil_AWPROT.value = 0
    dut.s_axil_WDATA.value = 0
    dut.s_axil_WSTRB.value = 0
    dut.s_axil_WVALID.value = 0
    dut.s_axil_BREADY.value = 0
    for _ in range(12):
        await RisingEdge(dut.CLK)
    dut.RST_N.value = 1
    for _ in range(WARMUP):              # let the uram_bank valid-wipe finish
        await RisingEdge(dut.CLK)
    await SETTLE


async def send_packet(dut, pkt: bytes):
    """Drive a 576-byte packet as 9x64-byte AXIS beats on s_axis_rpin."""
    assert len(pkt) == 576
    full = (1 << 64) - 1
    for i in range(9):
        chunk = pkt[i * 64:(i + 1) * 64]
        dut.s_axis_rpin_tdata.value = int.from_bytes(chunk, "little")
        dut.s_axis_rpin_tkeep.value = full
        dut.s_axis_rpin_tstrb.value = full
        dut.s_axis_rpin_tlast.value = 1 if i == 8 else 0
        dut.s_axis_rpin_tvalid.value = 1
        for _ in range(TIMEOUT):
            await step(dut)
            if dut.s_axis_rpin_tready.value == 1:
                break
        else:
            assert False, f"s_axis_rpin not ready on beat {i}"
    dut.s_axis_rpin_tvalid.value = 0
    dut.s_axis_rpin_tlast.value = 0


async def axil_read(dut, addr: int) -> int:
    dut.s_axil_ARADDR.value = addr
    dut.s_axil_ARVALID.value = 1
    for _ in range(TIMEOUT):
        await step(dut)
        if dut.s_axil_ARREADY.value == 1:
            break
    else:
        assert False, f"s_axil ARREADY timeout @ {addr:#x}"
    dut.s_axil_ARVALID.value = 0
    dut.s_axil_RREADY.value = 1
    for _ in range(TIMEOUT):
        await step(dut)
        if dut.s_axil_RVALID.value == 1:
            data = int(dut.s_axil_RDATA.value)
            break
    else:
        assert False, f"s_axil RVALID timeout @ {addr:#x}"
    dut.s_axil_RREADY.value = 0
    return data


async def watch_egress(dut, flag):
    """Background: record if m_axis_rpout ever asserts tvalid."""
    while True:
        await step(dut)
        if dut.m_axis_rpout_tvalid.value == 1:
            flag[0] = True


@cocotb.test()
async def vecavg_nf_smoke(dut):
    cocotb.start_soon(Clock(dut.CLK, 10, units="ns").start())
    await reset(dut)

    saw_egress = [False]
    cocotb.start_soon(watch_egress(dut, saw_egress))

    # CTRL.enable defaults to 0 -> ingress gated. Enable it (CTRL @ 0x00 bit0).
    # AXI-Lite write via flat ports.
    async def axil_write(addr, val):
        dut.s_axil_AWADDR.value = addr
        dut.s_axil_AWVALID.value = 1
        dut.s_axil_WDATA.value = val
        dut.s_axil_WSTRB.value = 0xF
        dut.s_axil_WVALID.value = 1
        got_aw = got_w = False
        for _ in range(TIMEOUT):
            await step(dut)
            if not got_aw and dut.s_axil_AWREADY.value == 1:
                dut.s_axil_AWVALID.value = 0
                got_aw = True
            if not got_w and dut.s_axil_WREADY.value == 1:
                dut.s_axil_WVALID.value = 0
                got_w = True
            if got_aw and got_w:
                break
        else:
            assert False, f"s_axil write handshake timeout @ {addr:#x}"
        dut.s_axil_BREADY.value = 1
        for _ in range(TIMEOUT):
            await step(dut)
            if dut.s_axil_BVALID.value == 1:
                break
        dut.s_axil_BREADY.value = 0

    await axil_write(0x00, 0x1)                 # CTRL.enable = 1
    assert (await axil_read(dut, 0x00)) & 1 == 1, "CTRL.enable did not stick"

    # ---- filter-drop: non-IPv4 packet (corrupt EtherType) -------------------
    pkt = bytearray(g.build_ingress_packet(payload_vec=np.zeros(256, dtype=np.int16)))
    pkt[12] = 0x99
    pkt[13] = 0x99                              # ethertype != 0x0800
    await send_packet(dut, bytes(pkt))
    for _ in range(200):
        await step(dut)
    rx = await axil_read(dut, CNT_RX)
    df = await axil_read(dut, CNT_DROP_FILTER)
    hit = await axil_read(dut, CNT_HIT)
    miss = await axil_read(dut, CNT_MISS)
    assert rx == 1 and df == 1 and hit == 0 and miss == 0, \
        f"filter: RX={rx} DROP_FILTER={df} HIT={hit} MISS={miss}"
    assert not saw_egress[0], "filter: unexpected egress on a dropped packet"
    dut._log.info("(1) filter-drop: RX=1 DROP_FILTER=1, no egress OK")

    # ---- miss: valid UDP packet, flow not installed -------------------------
    good = g.build_ingress_packet(
        payload_vec=np.arange(256, dtype=np.int16),
        client_ts=0xDEADBEEF12345678)
    await send_packet(dut, good)
    for _ in range(400):
        await step(dut)
    rx = await axil_read(dut, CNT_RX)
    df = await axil_read(dut, CNT_DROP_FILTER)
    hit = await axil_read(dut, CNT_HIT)
    miss = await axil_read(dut, CNT_MISS)
    proc = await axil_read(dut, CNT_PROCESSED)
    herr = await axil_read(dut, CNT_HBM_ERR)
    assert rx == 2 and df == 1 and hit == 0 and miss == 1, \
        f"miss: RX={rx} DROP_FILTER={df} HIT={hit} MISS={miss}"
    assert not saw_egress[0], "miss: unexpected egress on a dropped packet"

    # ---- spec §7 counter-conservation --------------------------------------
    assert rx == df + hit + miss, \
        f"conservation RX!=DROP+HIT+MISS ({rx}!={df}+{hit}+{miss})"
    assert hit == proc + herr, \
        f"conservation HIT!=PROCESSED+HBM_ERR ({hit}!={proc}+{herr})"
    dut._log.info("(2) miss: RX=2 MISS=1, conservation holds OK")

    dut._log.info("PASS mkVectorAvgNF: integration smoke (filter + miss + conservation)")
