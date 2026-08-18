#!/usr/bin/env python3
"""
Golden reference model for the flow_reduce UDP Vector-Averaging NF.

This module is the EXECUTABLE SPEC for the BSV datapath. BSV Bluesim
unit tests and the Phase-3 integration test diff their byte-for-byte
output against the bytes/numbers this module produces.

Spec: ../../spec/spec.md (VibeNIC DEPs, examples/case-study-nf/spec/spec.md)
  - 4.1 ingress packet layout
  - 4.2 HBM storage layout
  - 4.3 egress (result) packet layout
  - 5.1 per-packet pipeline (step 5: four-way average)
  - 7   counters
  - 8   new-flow notification

------------------------------------------------------------------------
THE ARITHMETIC CONTRACT (this is what the BSV mkFourWayAverager must match)
------------------------------------------------------------------------
For each of the 256 lanes i:

    s   = sext16(payload[i]) + sext16(ref0[i]) + sext16(ref2[i]) + sext16(ref4[i])
    out = (s >>> 2) truncated to 16 bits

  * Each input lane is a signed int16 (range -32768..32767).
  * The accumulator `s` is a SIGNED 20-bit value. Four signed 16-bit
    values sum into at most 18 bits of magnitude; 20 bits is the spec's
    declared accumulator width and is wide enough that no sum overflows
    it (max |s| = 4*32768 = 131072 < 2^19, fits signed 20-bit).
  * `>>> 2` is an ARITHMETIC right shift by 2. It rounds toward -inf.
    In Python, `s >> 2` on a plain int is exactly floor(s / 4), which
    is the arithmetic-shift semantics we want (e.g. -1 >> 2 == -1,
    -5 >> 2 == -2). We therefore implement it as Python `>> 2`.
  * The shifted result is then TRUNCATED (NOT saturated) to 16 bits:
    we keep the low 16 bits and reinterpret them as signed int16
    (two's-complement wrap). Saturation is intentionally NOT done;
    per the contract the BSV must also wrap. Given the input domain
    the shifted value is always within int16 range anyway
    (|s>>2| <= 32768 -> after wrap -32768..32767), so wrap == identity
    for in-range data, but the rule is defined for completeness and
    the self-test documents the wrap behavior explicitly.

API summary
-----------
  build_ingress_packet(eth, ip, udp, client_ts, payload_vec) -> bytes (576)
  vector_to_hbm_bytes(vec) -> bytes (512)
  compute_result(input_packet, table, sequence_num) -> (result|None, notify|None, deltas)
  parse_result_packet(bytes) -> dict
  make_table_key(src_ip, dst_ip, src_port, dst_port, proto) -> tuple
"""

import struct
import numpy as np

# --------------------------------------------------------------------------
# Module-level constants
# --------------------------------------------------------------------------

WIRE_LEN      = 576          # full ingress / egress wire packet length
HDR_BEAT_LEN  = 64           # header beat
PAYLOAD_LEN   = 512          # 8 beats * 64 B
VEC_N         = 256          # int16 elements per vector
HBM_VEC_BYTES = 512          # one reference vector in HBM (int16 x 256)

ETH_HDR_LEN   = 14
IPV4_HDR_LEN  = 20           # no options
UDP_HDR_LEN   = 8

IP_TOTAL_LEN  = 562          # IPv4 total_length field value (20 + 8 + 534)
UDP_LEN       = 542          # UDP length field value (8 + 534)
PROTO_UDP     = 17
ETHERTYPE_IP  = 0x0800

# Byte offsets in the (ingress/egress) wire packet
OFF_ETH        = 0
OFF_IPV4       = 14
OFF_UDP        = 34
OFF_FIELD_42   = 42          # ingress: client field; egress: flow_ident
OFF_FIELD_46   = 46          # ingress: client field; egress: sequence_num
OFF_PAD_50     = 50          # 50..55 padding (egress: zeroed)
OFF_CLIENT_TS  = 56          # 56..63 client_timestamp (8 B, echoed)
OFF_PAYLOAD    = 64          # 64..575 vector

# Notification entry (spec 8): 32 bytes, packed, little-endian struct fields
NOTIFY_ENTRY_LEN = 32

# Counter key names (spec 7)
CNT_RX          = "rx"
CNT_DROP_FILTER = "drop_filter"
CNT_HIT         = "hit"
CNT_MISS        = "miss"
CNT_PROCESSED   = "processed"

# Sensible default 5-tuple / L2 addressing for packet builders
DEFAULT_ETH = {
    "dst_mac": "02:00:00:00:00:01",
    "src_mac": "02:00:00:00:00:02",
    "ethertype": ETHERTYPE_IP,
}
DEFAULT_IP = {
    "src_ip": "10.0.0.1",
    "dst_ip": "10.0.0.2",
    "proto": PROTO_UDP,
    "ttl": 64,
}
DEFAULT_UDP = {
    "src_port": 1234,
    "dst_port": 5678,
}


# --------------------------------------------------------------------------
# Small helpers
# --------------------------------------------------------------------------

def _mac_to_bytes(mac):
    if isinstance(mac, (bytes, bytearray)):
        return bytes(mac)
    parts = mac.split(":")
    if len(parts) != 6:
        raise ValueError("bad MAC %r" % (mac,))
    return bytes(int(p, 16) for p in parts)


def _ip_to_int(ip):
    if isinstance(ip, int):
        return ip & 0xFFFFFFFF
    a, b, c, d = (int(x) for x in ip.split("."))
    return (a << 24) | (b << 16) | (c << 8) | d


def _ip_to_bytes(ip):
    return struct.pack(">I", _ip_to_int(ip))


def _int_to_ip(v):
    return "%d.%d.%d.%d" % ((v >> 24) & 0xFF, (v >> 16) & 0xFF,
                            (v >> 8) & 0xFF, v & 0xFF)


def _ipv4_checksum(hdr20):
    """Standard one's-complement IPv4 header checksum over the 20-byte
    header (checksum field assumed zero in the input)."""
    s = 0
    for i in range(0, 20, 2):
        s += (hdr20[i] << 8) | hdr20[i + 1]
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


def vec_to_bytes_be(vec):
    """int16 x 256 -> big-endian, lane-major bytes (element 0 first)."""
    a = np.asarray(vec, dtype="<i2")
    if a.shape != (VEC_N,):
        raise ValueError("vector must be shape (256,), got %r" % (a.shape,))
    # force big-endian on the wire regardless of host endianness
    return a.astype(">i2").tobytes()


def bytes_be_to_vec(buf):
    """big-endian, lane-major bytes -> int16 x 256 numpy array."""
    if len(buf) != VEC_N * 2:
        raise ValueError("expected %d bytes, got %d" % (VEC_N * 2, len(buf)))
    return np.frombuffer(buf, dtype=">i2").astype(np.int16)


def make_table_key(src_ip, dst_ip, src_port, dst_port, proto=PROTO_UDP):
    """Canonical flow-table key: 5-tuple as a hashable tuple of ints.
    IPs are normalized to 32-bit ints so '10.0.0.1' and the int form
    map to the same key."""
    return (_ip_to_int(src_ip), _ip_to_int(dst_ip),
            int(src_port) & 0xFFFF, int(dst_port) & 0xFFFF,
            int(proto) & 0xFF)


# --------------------------------------------------------------------------
# 1. Ingress packet builder
# --------------------------------------------------------------------------

def build_ingress_packet(eth=None, ip=None, udp=None,
                          client_ts=0, payload_vec=None,
                          client_field_42=0, client_field_46=0):
    """Build the exact 576-byte ingress wire packet (spec 4.1).

    Layout:
      0..13    Ethernet II         (dst mac, src mac, ethertype=0x0800)
      14..33   IPv4 (20 B)         total_length=562, proto=17, valid checksum
      34..41   UDP (8 B)           length=542
      42..45   client field        (arbitrary, ignored by NF)
      46..49   client field        (arbitrary, ignored by NF)
      50..55   padding             (don't-care on ingress; we write zero)
      56..63   client_timestamp    (8 B, big-endian)
      64..575  payload vector      int16 x 256, big-endian, lane-major

    eth/ip/udp are dicts; missing keys fall back to DEFAULT_*.
    """
    e = dict(DEFAULT_ETH);  e.update(eth or {})
    i = dict(DEFAULT_IP);   i.update(ip or {})
    u = dict(DEFAULT_UDP);  u.update(udp or {})

    if payload_vec is None:
        payload_vec = np.zeros(VEC_N, dtype=np.int16)

    pkt = bytearray(WIRE_LEN)

    # --- Ethernet (0..13) ---
    pkt[0:6]   = _mac_to_bytes(e["dst_mac"])
    pkt[6:12]  = _mac_to_bytes(e["src_mac"])
    pkt[12:14] = struct.pack(">H", e["ethertype"] & 0xFFFF)

    # --- IPv4 (14..33), no options ---
    ver_ihl   = 0x45
    tos       = 0x00
    total_len = IP_TOTAL_LEN
    ident     = i.get("ident", 0)
    flags_off = 0
    ttl       = i.get("ttl", 64)
    proto     = i.get("proto", PROTO_UDP)
    ip_hdr = bytearray(struct.pack(
        ">BBHHHBBH4s4s",
        ver_ihl, tos, total_len, ident, flags_off, ttl, proto,
        0,  # checksum placeholder
        _ip_to_bytes(i["src_ip"]),
        _ip_to_bytes(i["dst_ip"]),
    ))
    csum = _ipv4_checksum(ip_hdr)
    ip_hdr[10:12] = struct.pack(">H", csum)
    pkt[14:34] = ip_hdr

    # --- UDP (34..41) ---
    pkt[34:42] = struct.pack(">HHHH",
                             u["src_port"] & 0xFFFF,
                             u["dst_port"] & 0xFFFF,
                             UDP_LEN,
                             u.get("checksum", 0) & 0xFFFF)

    # --- client fields (42..49) ---
    pkt[42:46] = struct.pack(">I", client_field_42 & 0xFFFFFFFF)
    pkt[46:50] = struct.pack(">I", client_field_46 & 0xFFFFFFFF)

    # --- padding (50..55) ---
    pkt[50:56] = b"\x00" * 6

    # --- client_timestamp (56..63), big-endian 64-bit ---
    pkt[56:64] = struct.pack(">Q", client_ts & 0xFFFFFFFFFFFFFFFF)

    # --- payload vector (64..575) ---
    pkt[64:576] = vec_to_bytes_be(payload_vec)

    assert len(pkt) == WIRE_LEN
    return bytes(pkt)


# --------------------------------------------------------------------------
# 2. HBM reference-vector encoder
# --------------------------------------------------------------------------

def vector_to_hbm_bytes(vec):
    """int16 x 256 -> the 512-byte HBM storage image (spec 4.2).
    Same big-endian, lane-major encoding as the packet payload, so the
    four inputs sum elementwise with no re-ordering."""
    b = vec_to_bytes_be(vec)
    assert len(b) == HBM_VEC_BYTES
    return b


# --------------------------------------------------------------------------
# Header parsing
# --------------------------------------------------------------------------

def _parse_five_tuple(pkt):
    """Return (five_tuple_or_None, ok_filter).

    ok_filter is True iff: IPv4 (ethertype 0x0800, version 4) AND
    proto == 17 (UDP) AND len(pkt) == 576.  Returns the canonical
    5-tuple key on success, None on filter failure.
    """
    if len(pkt) != WIRE_LEN:
        return None, False

    ethertype = struct.unpack(">H", pkt[12:14])[0]
    if ethertype != ETHERTYPE_IP:
        return None, False

    ver_ihl = pkt[14]
    if (ver_ihl >> 4) != 4:
        return None, False

    proto = pkt[23]
    if proto != PROTO_UDP:
        return None, False

    src_ip = struct.unpack(">I", pkt[26:30])[0]
    dst_ip = struct.unpack(">I", pkt[30:34])[0]
    src_port = struct.unpack(">H", pkt[34:36])[0]
    dst_port = struct.unpack(">H", pkt[36:38])[0]

    key = (src_ip, dst_ip, src_port, dst_port, proto)
    return key, True


# --------------------------------------------------------------------------
# 3. Core: compute_result
# --------------------------------------------------------------------------

def _avg_lane(payload, ref0, ref2, ref4):
    """Four-way average over 256 lanes implementing THE ARITHMETIC
    CONTRACT (see module docstring). Returns int16 x 256 numpy array.

    Steps, per lane, using arbitrary-precision Python ints:
      s   = p + r0 + r2 + r4         (signed, fits signed 20-bit)
      sh  = s >> 2                   (arithmetic shift = floor div 4)
      out = wrap sh into signed 16-bit (truncate low 16 bits)
    """
    p  = np.asarray(payload, dtype=np.int64)
    r0 = np.asarray(ref0,    dtype=np.int64)
    r2 = np.asarray(ref2,    dtype=np.int64)
    r4 = np.asarray(ref4,    dtype=np.int64)

    s = p + r0 + r2 + r4                 # exact signed sum, |s| <= 131072

    # Arithmetic right shift by 2 == floor(s / 4). numpy >> on signed
    # int64 is an arithmetic shift (floor toward -inf), matching Python's
    # `>> 2` on plain ints and the BSV `>>>` on a signed value.
    sh = s >> np.int64(2)

    # Truncate to 16 bits: keep low 16 bits, reinterpret as signed
    # two's-complement (wrap, NOT saturate).
    low16 = (sh & 0xFFFF).astype(np.uint16)
    out = low16.astype(np.int16)         # uint16 -> int16 = wrap
    return out


def compute_result(input_packet, table, sequence_num):
    """Run the per-packet pipeline (spec 5.1) on one wire packet.

    Args:
      input_packet : bytes (expected 576 B; other lengths -> filter drop)
      table        : dict keyed by 5-tuple (use make_table_key); value is
                      a dict {'flow_ident': int,
                              'ref0': int16x256,
                              'ref2': int16x256,
                              'ref4': int16x256}.
                      Either raw 5-tuple ints or values produced by
                      make_table_key work as keys (we normalize).
      sequence_num : the 32-bit global sequence number to stamp into this
                     result (spec 4.3 / 5.1 step 6). On a miss it is
                     unused. Also used as the notification timestamp_cycles
                     fallback if no explicit caller value is supplied.

    Returns (result_packet, notify, counter_deltas):
      result_packet : bytes (576) on a hit, else None
      notify        : dict on a miss (spec 8 fields), else None
      counter_deltas: dict containing ONLY the counters that changed.

    Counter semantics (spec 7):
      - Always 'rx':1 unless the packet fails the header filter, in which
        case it is dropped *before* being counted as rx:
        {'rx':1, 'drop_filter':1}.   (rx counts ingress packets seen;
        drop_filter counts header-filter drops; both increment on a
        filtered packet.)
      - Hit : {'rx':1, 'hit':1, 'processed':1}
      - Miss: {'rx':1, 'miss':1}
    """
    key, ok = _parse_five_tuple(input_packet)

    if not ok:
        # Filter drop. Per spec: counted in CNT_RX (ingress seen) AND
        # CNT_DROP_FILTER.
        return None, None, {CNT_RX: 1, CNT_DROP_FILTER: 1}

    # Normalize lookup against table (accept either pre-normalized or
    # raw int 5-tuples as stored keys).
    norm_key = make_table_key(*key)
    entry = table.get(norm_key)
    if entry is None:
        entry = table.get(key)

    if entry is None:
        # MISS -> notification (spec 8). result is None.
        notify = {
            "src_ip":   key[0],
            "dst_ip":   key[1],
            "src_port": key[2],
            "dst_port": key[3],
            "proto":    key[4],
            # local user-clock cycles at miss; caller supplies via
            # sequence_num slot as the cycle value, default already 0.
            "timestamp_cycles": int(sequence_num) if sequence_num is not None else 0,
        }
        return None, notify, {CNT_RX: 1, CNT_MISS: 1}

    # HIT -> four-way average + result packet (spec 5.1 step 5/6).
    payload = bytes_be_to_vec(input_packet[OFF_PAYLOAD:OFF_PAYLOAD + PAYLOAD_LEN])
    ref0 = np.asarray(entry["ref0"], dtype=np.int16)
    ref2 = np.asarray(entry["ref2"], dtype=np.int16)
    ref4 = np.asarray(entry["ref4"], dtype=np.int16)
    for nm, v in (("ref0", ref0), ("ref2", ref2), ("ref4", ref4)):
        if v.shape != (VEC_N,):
            raise ValueError("table %s must be int16x256, got %r" % (nm, v.shape))

    out_vec = _avg_lane(payload, ref0, ref2, ref4)
    flow_ident = int(entry["flow_ident"]) & 0xFFFFFFFF

    result = bytearray(input_packet)            # bytes 0..41, 56..63 pass-through
    result[OFF_FIELD_42:OFF_FIELD_42 + 4] = struct.pack(">I", flow_ident)
    result[OFF_FIELD_46:OFF_FIELD_46 + 4] = struct.pack(">I",
                                                        int(sequence_num) & 0xFFFFFFFF)
    result[OFF_PAD_50:OFF_PAD_50 + 6] = b"\x00" * 6     # padding zeroed
    # 56..63 client_timestamp already echoed verbatim (untouched copy)
    result[OFF_PAYLOAD:OFF_PAYLOAD + PAYLOAD_LEN] = vec_to_bytes_be(out_vec)

    assert len(result) == WIRE_LEN
    return bytes(result), None, {CNT_RX: 1, CNT_HIT: 1, CNT_PROCESSED: 1}


# --------------------------------------------------------------------------
# 4. parse_result_packet (inverse helper for tests)
# --------------------------------------------------------------------------

def parse_result_packet(pkt):
    """Inverse of the egress format (spec 4.3). Returns a dict:
      flow_ident       : int (bytes 42..45, big-endian)
      sequence_num     : int (bytes 46..49, big-endian)
      padding          : bytes (50..55, expected all-zero on egress)
      client_timestamp : int (bytes 56..63, big-endian, echoed)
      vector           : int16 x 256 numpy array (bytes 64..575)
      eth_dst_mac/src_mac, ethertype
      src_ip/dst_ip    : dotted strings (echoed)
      src_port/dst_port: ints (echoed)
      proto            : int
      five_tuple       : canonical key tuple
      raw              : the original bytes
    """
    if len(pkt) != WIRE_LEN:
        raise ValueError("result packet must be %d bytes, got %d"
                         % (WIRE_LEN, len(pkt)))

    flow_ident   = struct.unpack(">I", pkt[42:46])[0]
    sequence_num = struct.unpack(">I", pkt[46:50])[0]
    padding      = bytes(pkt[50:56])
    client_ts    = struct.unpack(">Q", pkt[56:64])[0]
    vector       = bytes_be_to_vec(pkt[64:576])

    src_ip = struct.unpack(">I", pkt[26:30])[0]
    dst_ip = struct.unpack(">I", pkt[30:34])[0]
    src_port = struct.unpack(">H", pkt[34:36])[0]
    dst_port = struct.unpack(">H", pkt[36:38])[0]
    proto = pkt[23]

    return {
        "eth_dst_mac": pkt[0:6].hex(":"),
        "eth_src_mac": pkt[6:12].hex(":"),
        "ethertype":   struct.unpack(">H", pkt[12:14])[0],
        "src_ip":      _int_to_ip(src_ip),
        "dst_ip":      _int_to_ip(dst_ip),
        "src_ip_int":  src_ip,
        "dst_ip_int":  dst_ip,
        "src_port":    src_port,
        "dst_port":    dst_port,
        "proto":       proto,
        "five_tuple":  (src_ip, dst_ip, src_port, dst_port, proto),
        "flow_ident":  flow_ident,
        "sequence_num": sequence_num,
        "padding":     padding,
        "client_timestamp": client_ts,
        "vector":      vector,
        "raw":         bytes(pkt),
    }


def pack_notify_entry(notify):
    """Serialize a notify dict to the 32-byte ring entry (spec 8).
    struct notify_entry { u32 src_ip; u32 dst_ip; u16 src_port;
    u16 dst_port; u8 proto; u8 rsv[3]; u64 ts_cycles; u64 rsv2; }
    Multi-byte scalars are little-endian (host struct, x86 host)."""
    return struct.pack(
        "<IIHHB3xQQ",
        notify["src_ip"] & 0xFFFFFFFF,
        notify["dst_ip"] & 0xFFFFFFFF,
        notify["src_port"] & 0xFFFF,
        notify["dst_port"] & 0xFFFF,
        notify["proto"] & 0xFF,
        notify["timestamp_cycles"] & 0xFFFFFFFFFFFFFFFF,
        0,
    )


# --------------------------------------------------------------------------
# __main__ demo
# --------------------------------------------------------------------------

def _demo():
    print("flow_reduce golden reference model - demo")
    print("=" * 60)

    # Build a flow-table entry.
    payload = np.arange(VEC_N, dtype=np.int16)            # 0,1,2,...,255
    ref0 = np.full(VEC_N, 4, dtype=np.int16)
    ref2 = np.full(VEC_N, 8, dtype=np.int16)
    ref4 = np.full(VEC_N, -4, dtype=np.int16)

    five = make_table_key("10.0.0.1", "10.0.0.2", 1234, 5678, 17)
    table = {five: {"flow_ident": 0xABCD0001,
                    "ref0": ref0, "ref2": ref2, "ref4": ref4}}

    pkt = build_ingress_packet(client_ts=0x1122334455667788,
                               payload_vec=payload,
                               client_field_42=0xDEADBEEF,
                               client_field_46=0x00C0FFEE)
    print("ingress packet len      :", len(pkt), "B")
    print("IPv4 total_length field :",
          struct.unpack(">H", pkt[16:18])[0], "(spec: 562)")
    print("UDP length field        :",
          struct.unpack(">H", pkt[38:40])[0], "(spec: 542)")

    res, notify, deltas = compute_result(pkt, table, sequence_num=7)
    print("HIT  -> deltas          :", deltas)
    pr = parse_result_packet(res)
    print("  flow_ident           : 0x%08X" % pr["flow_ident"])
    print("  sequence_num         :", pr["sequence_num"])
    print("  client_timestamp     : 0x%016X (echoed)" % pr["client_timestamp"])
    print("  padding[50:56] zero  :", pr["padding"] == b"\x00" * 6)
    # element 8: (8 + 4 + 8 - 4) >> 2 = 16 >> 2 = 4
    print("  out[8] expect 4      :", int(pr["vector"][8]))
    # element 1: (1 + 4 + 8 - 4) >> 2 = 9 >> 2 = 2
    print("  out[1] expect 2      :", int(pr["vector"][1]))

    # Miss
    other = build_ingress_packet(udp={"src_port": 9999}, payload_vec=payload)
    res2, notify2, deltas2 = compute_result(other, table, sequence_num=42)
    print("MISS -> deltas          :", deltas2)
    print("  notify                :", notify2)
    print("  notify entry bytes    :", len(pack_notify_entry(notify2)), "B")

    # Filter drop (truncated packet)
    res3, notify3, deltas3 = compute_result(pkt[:100], table, sequence_num=0)
    print("DROP -> deltas          :", deltas3, "result is None:", res3 is None)

    print("=" * 60)
    print("demo OK")


if __name__ == "__main__":
    _demo()
