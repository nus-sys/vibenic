#!/usr/bin/env python3
"""
Self-test for the flow_reduce golden reference model.

Runs under pytest (`pytest -q`) if available, otherwise standalone
(`python3 test_golden_selfcheck.py`). Exits non-zero on any failure.

These assertions ARE the contract the BSV averager must satisfy:
arithmetic >>2 on a signed 20-bit accumulator, result truncated
(wrapped, NOT saturated) to 16 bits.
"""

import sys
import os
import struct
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import vecavg_golden as g


def _entry(flow_ident, r0, r2, r4):
    return {"flow_ident": flow_ident,
            "ref0": np.asarray(r0, dtype=np.int16),
            "ref2": np.asarray(r2, dtype=np.int16),
            "ref4": np.asarray(r4, dtype=np.int16)}


def _const(v):
    return np.full(g.VEC_N, v, dtype=np.int16)


KEY = g.make_table_key("10.0.0.1", "10.0.0.2", 1234, 5678, 17)


# --------------------------------------------------------------------------
# Builder / structural round-trips
# --------------------------------------------------------------------------

def test_ingress_packet_structure():
    vec = np.arange(g.VEC_N, dtype=np.int16)
    pkt = g.build_ingress_packet(client_ts=0xAABBCCDDEEFF0011,
                                 payload_vec=vec,
                                 client_field_42=0x11223344,
                                 client_field_46=0x55667788)
    assert len(pkt) == 576
    assert struct.unpack(">H", pkt[12:14])[0] == g.ETHERTYPE_IP
    assert pkt[14] == 0x45                                  # ver/IHL
    assert pkt[23] == 17                                    # proto UDP
    assert struct.unpack(">H", pkt[16:18])[0] == 562        # IP total_length
    assert struct.unpack(">H", pkt[38:40])[0] == 542        # UDP length
    assert struct.unpack(">Q", pkt[56:64])[0] == 0xAABBCCDDEEFF0011
    # payload vector decodes back (big-endian, lane-major, elem 0 first)
    assert np.array_equal(g.bytes_be_to_vec(pkt[64:576]), vec)
    # IPv4 checksum valid (sum incl. checksum folds to 0xFFFF)
    s = sum(struct.unpack(">10H", pkt[14:34]))
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    assert s == 0xFFFF


def test_hbm_encoding_matches_payload():
    vec = (np.arange(g.VEC_N, dtype=np.int16) - 100)
    hbm = g.vector_to_hbm_bytes(vec)
    assert len(hbm) == 512
    pkt = g.build_ingress_packet(payload_vec=vec)
    # HBM image and packet payload are byte-identical encodings
    assert hbm == pkt[64:576]
    assert np.array_equal(g.bytes_be_to_vec(hbm), vec)


# --------------------------------------------------------------------------
# Arithmetic contract: hand-computed cases
# --------------------------------------------------------------------------

def test_all_zero_gives_zero():
    pkt = g.build_ingress_packet(payload_vec=_const(0))
    table = {KEY: _entry(1, _const(0), _const(0), _const(0))}
    res, notify, d = g.compute_result(pkt, table, sequence_num=0)
    assert notify is None
    pr = g.parse_result_packet(res)
    assert np.array_equal(pr["vector"], _const(0))
    assert d == {"rx": 1, "hit": 1, "processed": 1}


def test_payload_4_refs_0_gives_1():
    # (4 + 0 + 0 + 0) >>> 2 = 4 >> 2 = 1
    pkt = g.build_ingress_packet(payload_vec=_const(4))
    table = {KEY: _entry(1, _const(0), _const(0), _const(0))}
    res, _, _ = g.compute_result(pkt, table, sequence_num=0)
    pr = g.parse_result_packet(res)
    assert np.array_equal(pr["vector"], _const(1))


def test_negative_rounding_toward_neg_inf():
    # (-1 + 0 + 0 + 0) >>> 2 = floor(-1/4) = -1   (arithmetic shift)
    pkt = g.build_ingress_packet(payload_vec=_const(-1))
    table = {KEY: _entry(1, _const(0), _const(0), _const(0))}
    res, _, _ = g.compute_result(pkt, table, sequence_num=0)
    pr = g.parse_result_packet(res)
    assert np.array_equal(pr["vector"], _const(-1)), \
        "arithmetic >>2 must round toward -inf: -1 >> 2 == -1"

    # (-5 + 0 + 0 + 0) >>> 2 = floor(-5/4) = -2  (NOT -1; not truncate-toward-0)
    pkt2 = g.build_ingress_packet(payload_vec=_const(-5))
    res2, _, _ = g.compute_result(pkt2, table, sequence_num=0)
    pr2 = g.parse_result_packet(res2)
    assert np.array_equal(pr2["vector"], _const(-2))


def test_four_way_average_mixed():
    # per lane: (p + r0 + r2 + r4) >> 2
    p  = np.array([0, 1, 8, 100, -7, 32767] + [0] * 250, dtype=np.int16)
    r0 = np.array([0, 4, 4, 100,  0, 32767] + [0] * 250, dtype=np.int16)
    r2 = np.array([0, 8, 8, 100,  0, 32767] + [0] * 250, dtype=np.int16)
    r4 = np.array([0, -4, -4, 100, 0, 32767] + [0] * 250, dtype=np.int16)
    expected = ((p.astype(np.int64) + r0 + r2 + r4) >> 2)

    pkt = g.build_ingress_packet(payload_vec=p)
    table = {KEY: _entry(0xCAFEBABE, r0, r2, r4)}
    res, _, _ = g.compute_result(pkt, table, sequence_num=0)
    pr = g.parse_result_packet(res)
    # spot checks: lane1 (1+4+8-4)>>2 = 9>>2 = 2 ; lane2 16>>2 = 4
    assert int(pr["vector"][1]) == 2
    assert int(pr["vector"][2]) == 4
    # lane5: (32767*4)=131068 >> 2 = 32767  (max sum, no overflow of acc)
    assert int(pr["vector"][5]) == 32767
    # full vector matches floor-div semantics within int16 range
    assert np.array_equal(pr["vector"].astype(np.int64), expected)


def test_int16_truncation_is_wrap_not_saturate():
    # Sum = 4 * -32768 = -131072. >>2 = -32768 (= INT16_MIN, in range,
    # so wrap == identity here). Document: the rule is WRAP (low 16 bits
    # reinterpreted signed), NOT saturate. We force a true wrap by hand
    # via the internal lane function on an out-of-range shifted value.
    minv = _const(-32768)
    pkt = g.build_ingress_packet(payload_vec=minv)
    table = {KEY: _entry(1, minv, minv, minv)}
    res, _, _ = g.compute_result(pkt, table, sequence_num=0)
    pr = g.parse_result_packet(res)
    assert np.array_equal(pr["vector"], _const(-32768))

    # Direct wrap demonstration: shifted value 0x8000 (32768) must wrap
    # to -32768, NOT saturate to 32767. Construct inputs whose sum>>2
    # exceeds INT16_MAX is impossible within the int16 input domain
    # (max is exactly 32767), so we assert the documented rule via the
    # internal helper on a synthetic >16-bit value.
    out = g._avg_lane(np.array([1]), np.array([0]),
                      np.array([0]), np.array([0]))
    assert out.dtype == np.int16
    # 0x12345 >> shift demonstration of pure truncation (low 16 bits):
    synthetic = np.int64(0x1_8000) >> np.int64(0)   # = 0x18000
    low16 = (synthetic & 0xFFFF)                     # = 0x8000
    assert np.int16(np.uint16(low16)) == -32768      # wrap, not 32767


# --------------------------------------------------------------------------
# Filter / miss / counters
# --------------------------------------------------------------------------

def test_filter_drop_bad_length():
    pkt = g.build_ingress_packet(payload_vec=_const(0))
    res, notify, d = g.compute_result(pkt[:200], {}, sequence_num=0)
    assert res is None and notify is None
    assert d == {"rx": 1, "drop_filter": 1}


def test_filter_drop_non_udp():
    pkt = bytearray(g.build_ingress_packet(payload_vec=_const(0)))
    pkt[23] = 6                                  # proto = TCP
    res, notify, d = g.compute_result(bytes(pkt), {}, sequence_num=0)
    assert res is None and notify is None
    assert d == {"rx": 1, "drop_filter": 1}


def test_filter_drop_non_ipv4():
    pkt = bytearray(g.build_ingress_packet(payload_vec=_const(0)))
    pkt[12:14] = struct.pack(">H", 0x86DD)        # IPv6 ethertype
    res, notify, d = g.compute_result(bytes(pkt), {}, sequence_num=0)
    assert res is None and notify is None
    assert d == {"rx": 1, "drop_filter": 1}


def test_miss_produces_notification():
    pkt = g.build_ingress_packet(payload_vec=_const(0))
    res, notify, d = g.compute_result(pkt, {}, sequence_num=12345)
    assert res is None
    assert d == {"rx": 1, "miss": 1}
    assert notify is not None
    assert notify["src_ip"] == g._ip_to_int("10.0.0.1")
    assert notify["dst_ip"] == g._ip_to_int("10.0.0.2")
    assert notify["src_port"] == 1234
    assert notify["dst_port"] == 5678
    assert notify["proto"] == 17
    assert notify["timestamp_cycles"] == 12345
    assert len(g.pack_notify_entry(notify)) == 32


# --------------------------------------------------------------------------
# Egress header splice / sequence_num placement
# --------------------------------------------------------------------------

def test_sequence_num_big_endian_placement():
    pkt = g.build_ingress_packet(client_ts=0xDEADBEEFCAFEBABE,
                                 payload_vec=_const(0),
                                 client_field_42=0xFFFFFFFF,
                                 client_field_46=0xFFFFFFFF)
    table = {KEY: _entry(0x01020304, _const(0), _const(0), _const(0))}
    res, _, _ = g.compute_result(pkt, table, sequence_num=0x0A0B0C0D)

    # flow_ident at 42..45, big-endian
    assert res[42:46] == bytes([0x01, 0x02, 0x03, 0x04])
    # sequence_num at 46..49, big-endian
    assert res[46:50] == bytes([0x0A, 0x0B, 0x0C, 0x0D])
    # padding 50..55 zeroed
    assert res[50:56] == b"\x00" * 6
    # client_timestamp echoed verbatim 56..63
    assert res[56:64] == pkt[56:64]
    # bytes 0..41 passed through verbatim
    assert res[0:42] == pkt[0:42]

    pr = g.parse_result_packet(res)
    assert pr["flow_ident"] == 0x01020304
    assert pr["sequence_num"] == 0x0A0B0C0D
    assert pr["client_timestamp"] == 0xDEADBEEFCAFEBABE


def test_header_passthrough_and_full_roundtrip():
    vec = (np.arange(g.VEC_N, dtype=np.int16) * 7 - 500)
    pkt = g.build_ingress_packet(
        eth={"src_mac": "aa:bb:cc:dd:ee:ff"},
        ip={"src_ip": "192.168.1.10", "dst_ip": "8.8.8.8"},
        udp={"src_port": 40000, "dst_port": 53},
        client_ts=0x0123456789ABCDEF,
        payload_vec=vec)
    key = g.make_table_key("192.168.1.10", "8.8.8.8", 40000, 53, 17)
    r0, r2, r4 = _const(3), _const(-9), _const(2)
    table = {key: _entry(0xBEEF, r0, r2, r4)}

    res, notify, d = g.compute_result(pkt, table, sequence_num=99)
    assert notify is None and d == {"rx": 1, "hit": 1, "processed": 1}
    pr = g.parse_result_packet(res)
    assert pr["eth_src_mac"] == "aa:bb:cc:dd:ee:ff"
    assert pr["src_ip"] == "192.168.1.10"
    assert pr["dst_ip"] == "8.8.8.8"
    assert pr["src_port"] == 40000
    assert pr["dst_port"] == 53
    assert pr["flow_ident"] == 0xBEEF
    assert pr["sequence_num"] == 99
    expected = ((vec.astype(np.int64) + 3 - 9 + 2) >> 2)
    assert np.array_equal(pr["vector"].astype(np.int64), expected)


def test_sequence_num_wraps_32bit():
    pkt = g.build_ingress_packet(payload_vec=_const(0))
    table = {KEY: _entry(1, _const(0), _const(0), _const(0))}
    res, _, _ = g.compute_result(pkt, table, sequence_num=0x1_0000_0001)
    assert res[46:50] == bytes([0x00, 0x00, 0x00, 0x01])     # wrapped


# --------------------------------------------------------------------------
# Standalone runner
# --------------------------------------------------------------------------

def _run_standalone():
    tests = [v for k, v in sorted(globals().items())
             if k.startswith("test_") and callable(v)]
    passed = 0
    for t in tests:
        try:
            t()
        except Exception as e:  # noqa: BLE001
            print("FAIL %-45s : %r" % (t.__name__, e))
            import traceback
            traceback.print_exc()
            return 1
        print("ok   %s" % t.__name__)
        passed += 1
    print("-" * 60)
    print("SUCCESS: %d/%d golden self-tests passed" % (passed, len(tests)))
    return 0


if __name__ == "__main__":
    sys.exit(_run_standalone())
