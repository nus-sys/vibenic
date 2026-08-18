"""
cocotb test for mkFlowTable (wraps the CachedCuckoo BVI).

Runs on the Verilator backend (cocotb --cc path, g++ 10.5 OK — iverilog 10.3
cannot parse the vendor SV).

bsc port/handshake convention for mkFlowTable:
  CLK, RST_N (active-low)
  Put  lookup_req : lookup_req_put[103:0], EN_lookup_req_put, RDY_lookup_req_put
  Get  lookup_resp: lookup_resp_get[129:0], EN_lookup_resp_get, RDY_lookup_resp_get
  meth enq_cmd    : enq_cmd_c[232:0], EN_enq_cmd        (always_ready, no RDY)
  meth cmd_full   : cmd_full
  meth cntPulse   : cntPulse[7:0]

Encodings (bsc packs first struct field / first union member into the MSBs):
  TableCmd  = {is_delete:1, key:104, val:128} -> [232], [231:128], [127:0]
  KvsResp   = Found(0)|Succ(1)|Fail(2): [129:128]=tag, [127:0]=value
  CntPulse  = {rx,...,tbl_q_drop}  -> tbl_q_drop = cntPulse[0]

Handshake helpers sample settled values just after a clock edge (RisingEdge +
small Timer so Verilator combinational logic settles), then drive in the same
(writable) region — never write during ReadOnly.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

KEY_W, VAL_W = 104, 128
RESP_TIMEOUT = 600          # cycles to wait for a cuckoo response
SETTLE = Timer(100, units="ps")


async def step(dut):
    await RisingEdge(dut.CLK)
    await SETTLE


async def reset(dut):
    dut.RST_N.value = 0
    dut.EN_lookup_req_put.value = 0
    dut.EN_lookup_resp_get.value = 0
    dut.EN_enq_cmd.value = 0
    dut.lookup_req_put.value = 0
    dut.enq_cmd_c.value = 0
    for _ in range(12):
        await RisingEdge(dut.CLK)
    dut.RST_N.value = 1
    # The vendor uram_bank clears its valid RAM one entry/cycle after reset
    # (~2**AWIDTH cycles per bank; htSize=1024 -> ~1024). Warm up well past
    # that before issuing any command, or early writes get wiped.
    for _ in range(2600):
        await RisingEdge(dut.CLK)
    await SETTLE


async def enq_cmd(dut, is_delete, key, val):
    """always_ready: pulse EN_enq_cmd for exactly one cycle."""
    dut.enq_cmd_c.value = (is_delete << (KEY_W + VAL_W)) | (key << VAL_W) | val
    dut.EN_enq_cmd.value = 1
    await step(dut)
    dut.EN_enq_cmd.value = 0


async def put_lookup(dut, key):
    """Wait (EN low) until RDY, then pulse EN one cycle."""
    dut.lookup_req_put.value = key
    dut.EN_lookup_req_put.value = 0
    for _ in range(RESP_TIMEOUT):
        await step(dut)
        if dut.RDY_lookup_req_put.value == 1:
            break
    else:
        assert False, "lookup_req never became RDY"
    dut.EN_lookup_req_put.value = 1
    await step(dut)
    dut.EN_lookup_req_put.value = 0


async def get_resp(dut):
    """Wait (EN low) for RDY, sample the value, then pulse EN to dequeue."""
    for _ in range(RESP_TIMEOUT):
        await step(dut)
        if dut.RDY_lookup_resp_get.value == 1:
            break
    else:
        assert False, "lookup_resp never became RDY"
    raw = int(dut.lookup_resp_get.value)
    dut.EN_lookup_resp_get.value = 1
    await step(dut)
    dut.EN_lookup_resp_get.value = 0
    tag = (raw >> VAL_W) & 0b11
    val = raw & ((1 << VAL_W) - 1)
    if tag == 0:
        return ("found", val)
    if tag == 2:
        return ("fail", None)
    assert False, f"unexpected KvsResp tag {tag} (Succ leaked to lookup_resp?)"


async def settle(dut, n):
    for _ in range(n):
        await RisingEdge(dut.CLK)
    await SETTLE


@cocotb.test()
async def flow_table_test(dut):
    cocotb.start_soon(Clock(dut.CLK, 10, units="ns").start())
    await reset(dut)

    K1 = 0xA5A5_0000_1111_2222_3333_4400 & ((1 << KEY_W) - 1)
    V1 = 0xDEAD_BEEF_0000_0000_0000_0000_0000_0001
    K2 = 0x1234_5678_9ABC_DEF0_1122_3300 & ((1 << KEY_W) - 1)

    # (1) upsert K1 -> V1, then lookup K1 -> Found V1
    await enq_cmd(dut, 0, K1, V1)
    await settle(dut, 80)
    await put_lookup(dut, K1)
    kind, val = await get_resp(dut)
    assert kind == "found" and val == V1, f"(1) expected Found {V1:#x}, got {kind} {val}"
    dut._log.info("(1) upsert+lookup hit OK")

    # (2) lookup an absent key -> Fail
    await put_lookup(dut, K2)
    kind, _ = await get_resp(dut)
    assert kind == "fail", f"(2) expected Fail, got {kind}"
    dut._log.info("(2) miss -> Fail OK")

    # (3) delete K1, then lookup K1 -> Fail
    await enq_cmd(dut, 1, K1, 0)
    await settle(dut, 80)
    await put_lookup(dut, K1)
    kind, _ = await get_resp(dut)
    assert kind == "fail", f"(3) expected Fail after delete, got {kind}"
    dut._log.info("(3) delete -> Fail OK")

    # (4) upsert 64 distinct keys, then look them all up
    N = 64
    keys = [((0x10_0000_0000 + i * 0x7919) & ((1 << KEY_W) - 1)) for i in range(N)]
    vals = [(0xC0DE_0000 + i) for i in range(N)]
    for k, v in zip(keys, vals):
        await enq_cmd(dut, 0, k, v)
        await settle(dut, 10)            # let do_submit_cmd drain between upserts
    await settle(dut, 200)
    for k, v in zip(keys, vals):
        await put_lookup(dut, k)
        kind, val = await get_resp(dut)
        assert kind == "found" and val == v, \
            f"(4) key {k:#x}: expected {v:#x}, got {kind} {val}"
    dut._log.info(f"(4) {N} upserts all retrievable OK")

    # (5) interleaved lookups (responses must stay in request order)
    seq = [keys[3], keys[40], K2, keys[7], keys[63]]
    exp = [("found", vals[3]), ("found", vals[40]), ("fail", None),
           ("found", vals[7]), ("found", vals[63])]
    for k in seq:
        await put_lookup(dut, k)
    for k, (ek, ev) in zip(seq, exp):
        kind, val = await get_resp(dut)
        assert kind == ek and (ev is None or val == ev), \
            f"(5) key {k:#x}: expected {ek} {ev}, got {kind} {val}"
    dut._log.info("(5) interleaved lookups in-order OK")

    # (6) overflow: blast >16 enq_cmd back-to-back; cmd_full must assert and a
    #     dropped command must pulse cntPulse.tbl_q_drop (bit 0).
    saw_full = False
    saw_drop = False
    for i in range(48):
        dut.enq_cmd_c.value = ((0x9000 + i) << VAL_W) | i
        dut.EN_enq_cmd.value = 1
        await step(dut)
        if dut.cmd_full.value == 1:
            saw_full = True
            if (int(dut.cntPulse.value) & 0x1) == 1:
                saw_drop = True
    dut.EN_enq_cmd.value = 0
    assert saw_full, "(6) cmd_full never asserted under back-to-back enq_cmd"
    assert saw_drop, "(6) tbl_q_drop never pulsed while cmd_full"
    dut._log.info("(6) overflow: cmd_full + tbl_q_drop OK")

    dut._log.info("PASS mkFlowTable: all 6 scenarios")
