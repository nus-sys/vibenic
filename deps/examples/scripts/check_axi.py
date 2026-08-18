#!/usr/bin/env python3
"""
AXI port direction checker for the QDMA shell project.

Checks two things:
  1. AXI convention: for each named AXI interface in each module, every signal
     suffix has the correct input/output direction for the interface role
     (master prefix 'm_' or slave prefix 's_').
  2. Cross-module consistency: ports shared between module pairs (e.g.
     user_block.sv and rp_blk.v) have identical directions and widths, except
     for documented intentional differences.

Usage:
    python3 check_axi.py [--src-dir src] [--files a.v b.sv ...]

Files that are absent from --src-dir are skipped with a note rather than
treated as an error, so this also runs against a partial tree (e.g. the DEPs
corpus, which vendors only rp_blk.v) or against your own RTL via --files. The
cross-module check runs only when both of its files are present.

Exit code: 0 = no issues, 1 = issues found.
"""

import re
import sys
import argparse
from pathlib import Path
from collections import defaultdict

# ---------------------------------------------------------------------------
# AXI signal-suffix → expected direction for a MASTER interface.
# Slave is the exact opposite.
# ---------------------------------------------------------------------------
#  master output → 'output'
#  master input  → 'input'

_AXI4_MASTER_DIR = {
    # AW channel
    'awaddr':  'output', 'awid':    'output', 'awlen':   'output',
    'awsize':  'output', 'awburst': 'output', 'awlock':  'output',
    'awcache': 'output', 'awprot':  'output', 'awqos':   'output',
    'awregion':'output', 'awvalid': 'output', 'awready': 'input',
    # W channel
    'wdata':   'output', 'wstrb':   'output', 'wlast':   'output',
    'wvalid':  'output', 'wready':  'input',
    # B channel
    'bid':     'input',  'bresp':   'input',  'bvalid':  'input',
    'bready':  'output',
    # AR channel
    'araddr':  'output', 'arid':    'output', 'arlen':   'output',
    'arsize':  'output', 'arburst': 'output', 'arlock':  'output',
    'arcache': 'output', 'arprot':  'output', 'arqos':   'output',
    'arregion':'output', 'arvalid': 'output', 'arready': 'input',
    # R channel
    'rdata':   'input',  'rid':     'input',  'rresp':   'input',
    'rlast':   'input',  'rvalid':  'input',  'rready':  'output',
}

_AXIL_MASTER_DIR = {
    'awaddr': 'output', 'awprot': 'output', 'awvalid': 'output', 'awready': 'input',
    'wdata':  'output', 'wstrb':  'output', 'wvalid':  'output', 'wready':  'input',
    'bresp':  'input',  'bvalid': 'input',  'bready':  'output',
    'araddr': 'output', 'arprot': 'output', 'arvalid': 'output', 'arready': 'input',
    'rdata':  'input',  'rresp':  'input',  'rlast':   'input',
    'rvalid': 'input',  'rready': 'output',
}

_AXIS_MASTER_DIR = {
    'tdata':  'output', 'tkeep':  'output', 'tstrb':  'output',
    'tlast':  'output', 'tvalid': 'output', 'tready': 'input',
    'tid':    'output', 'tdest':  'output', 'tuser':  'output',
}

def slave_dir(d):
    return 'input' if d == 'output' else 'output'

def expected_dir(iface_role, suffix, is_axil=False, is_axis=False):
    """Return expected direction of 'suffix' for the given role ('master'/'slave')."""
    if is_axis:
        table = _AXIS_MASTER_DIR
    elif is_axil:
        table = _AXIL_MASTER_DIR
    else:
        table = _AXI4_MASTER_DIR
    base = table.get(suffix)
    if base is None:
        return None  # unknown suffix – skip
    return base if iface_role == 'master' else slave_dir(base)

# ---------------------------------------------------------------------------
# Known intentional width differences between module pairs.
# Each entry: (port_name, file_a_bits, file_b_bits, explanation)
# ---------------------------------------------------------------------------
INTENTIONAL_WIDTH_DIFFS = {
    # user_block.sv uses 34-bit DDR addresses; rp_blk.v uses 33-bit.
    # user_block hardwires bit[33]=0 and passes [32:0] to rp_blk.
    # The full 34-bit bus matches ddr4_wrapper.sv's ddr0/1_axi_*addr ports.
    ('ddrc0_axi_awaddr', 'user_block.sv', 'rp_blk.v'): '34b in user_block (bit[33]=0 hardwired); 33b in rp_blk. user_block passes [32:0] to rp_blk.',
    ('ddrc0_axi_araddr', 'user_block.sv', 'rp_blk.v'): '34b in user_block (bit[33]=0 hardwired); 33b in rp_blk. user_block passes [32:0] to rp_blk.',
    ('ddrc1_axi_awaddr', 'user_block.sv', 'rp_blk.v'): '34b in user_block (bit[33]=0 hardwired); 33b in rp_blk. user_block passes [32:0] to rp_blk.',
    ('ddrc1_axi_araddr', 'user_block.sv', 'rp_blk.v'): '34b in user_block (bit[33]=0 hardwired); 33b in rp_blk. user_block passes [32:0] to rp_blk.',
}

# Known intentional width differences at the shell_top wire level.
# m_axibr master IDs are 4-bit in user_block/rp_blk, but shell_top only
# connects 2-bit wires (pcibr_axi_*id).  Upper bits are unused.
INTENTIONAL_SHELL_WIDTH_DIFFS = {
    'pcibr_axi_awid': 'user_block m_axibr_awid is [3:0]; shell_top wire is [1:0]. Upper 2 bits unused by the static shell.',
    'pcibr_axi_arid': 'user_block m_axibr_arid is [3:0]; shell_top wire is [1:0]. Upper 2 bits unused by the static shell.',
    'pcibr_axi_bid':  'user_block m_axibr_bid is [3:0]; shell_top wire is [1:0]. Upper 2 bits tie to 0.',
    'pcibr_axi_rid':  'user_block m_axibr_rid is [3:0]; shell_top wire is [1:0]. Upper 2 bits tie to 0.',
}

# ---------------------------------------------------------------------------
# Port parser
# ---------------------------------------------------------------------------

def parse_ports(path):
    """
    Return dict  port_name -> {'direction': 'input'|'output', 'bits': int}
    from a Verilog/SystemVerilog file.
    """
    text = Path(path).read_text()
    ports = {}
    # Match:  [optional (*attr*)]  input|output  wire  [optional width]  name
    pat = re.compile(
        r'(?:\(\*[^*]*\*\)\s*)?'     # optional attribute
        r'(input|output)\s+'
        r'(?:wire\s+)?'
        r'(\[[^\]]+\])?\s*'          # optional width
        r'(\w+)'                     # port name
    )
    for m in pat.finditer(text):
        direction = m.group(1)
        width_str = m.group(2)
        name = m.group(3)
        if width_str:
            wm = re.match(r'\[(\d+):(\d+)\]', width_str)
            bits = abs(int(wm.group(1)) - int(wm.group(2))) + 1 if wm else 1
        else:
            bits = 1
        ports[name] = {'direction': direction, 'bits': bits}
    return ports

# ---------------------------------------------------------------------------
# AXI interface grouper
# ---------------------------------------------------------------------------

# Suffixes that belong to AXI / AXI-Lite / AXI-Stream
_ALL_SUFFIXES = (
    set(_AXI4_MASTER_DIR) | set(_AXIL_MASTER_DIR) | set(_AXIS_MASTER_DIR)
)

def classify_iface(iface_name):
    """Return ('axi4'|'axil'|'axis'|None, 'master'|'slave'|None)."""
    name = iface_name.lower()
    # role
    if name.startswith('m_'):
        role = 'master'
    elif name.startswith('s_'):
        role = 'slave'
    else:
        return None, None
    # type
    rest = name[2:]
    if 'axis' in rest:
        kind = 'axis'
    elif 'axil' in rest:
        kind = 'axil'
    elif 'axi' in rest:
        kind = 'axi4'
    else:
        return None, None
    return kind, role

def group_by_interface(ports):
    """
    Group port names by AXI interface prefix.
    Returns  dict  iface_name -> {suffix -> port_name}
    """
    groups = defaultdict(dict)
    for port_name in ports:
        # Try to split off known AXI signal suffixes
        for suffix in sorted(_ALL_SUFFIXES, key=len, reverse=True):
            if port_name.lower().endswith('_' + suffix):
                iface = port_name[:-(len(suffix) + 1)]
                groups[iface][suffix] = port_name
                break
    return groups

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

def check_convention(filename, ports, verbose=False):
    """Check that each AXI port in `ports` follows the master/slave convention."""
    issues = []
    groups = group_by_interface(ports)
    for iface, sigs in groups.items():
        kind, role = classify_iface(iface)
        if kind is None:
            continue
        is_axil = (kind == 'axil')
        is_axis = (kind == 'axis')
        for suffix, port_name in sigs.items():
            exp = expected_dir(role, suffix, is_axil=is_axil, is_axis=is_axis)
            if exp is None:
                continue
            actual = ports[port_name]['direction']
            if actual != exp:
                issues.append(
                    f"  {port_name}: expected {exp} (interface '{iface}' is {role}), "
                    f"got {actual}"
                )
    return issues

def check_pair(file_a, ports_a, file_b, ports_b, verbose=False):
    """Check direction and width of ports shared between two modules."""
    issues = []
    shared = set(ports_a) & set(ports_b)
    name_a = Path(file_a).name
    name_b = Path(file_b).name
    for port in sorted(shared):
        pa = ports_a[port]
        pb = ports_b[port]
        key = (port, name_a, name_b)
        if pa['direction'] != pb['direction']:
            issues.append(
                f"  {port}: direction mismatch — "
                f"{name_a}={pa['direction']}, {name_b}={pb['direction']}"
            )
        elif pa['bits'] != pb['bits']:
            if key in INTENTIONAL_WIDTH_DIFFS:
                if verbose:
                    print(f"  [intentional] {port}: {INTENTIONAL_WIDTH_DIFFS[key]}")
            else:
                issues.append(
                    f"  {port}: width mismatch — "
                    f"{name_a}={pa['bits']}b, {name_b}={pb['bits']}b"
                )
    return issues

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--src-dir', default='src',
                        help='Path to the src/ directory (default: src)')
    parser.add_argument('--files', nargs='+', metavar='FILE',
                        help='Check these files instead of the src-dir set')
    parser.add_argument('--verbose', '-v', action='store_true',
                        help='Print intentional differences too')
    args = parser.parse_args()

    if args.files:
        files = {Path(f).name: Path(f) for f in args.files}
    else:
        src = Path(args.src_dir)
        files = {name: src / name for name in (
            'shell_top.v', 'user_block.sv', 'rp_blk.v',
            'qdma_wrapper.v', 'ddr4_wrapper.sv')}

    # Absent files are skipped, not fatal: the checker is useful on a partial
    # tree (e.g. rp_blk.v alone) and on a user's own RTL.
    missing = sorted(name for name, p in files.items() if not p.exists())
    files = {name: p for name, p in files.items() if p.exists()}
    if missing:
        print(f"NOTE: skipping absent file(s): {', '.join(missing)}")
    if not files:
        print("ERROR: no files to check")
        sys.exit(1)

    all_ports = {name: parse_ports(path) for name, path in files.items()}
    total_issues = 0

    # 1. AXI convention check on each file
    print("=" * 60)
    print("1. AXI convention check (per-file)")
    print("=" * 60)
    for fname, ports in all_ports.items():
        issues = check_convention(fname, ports, verbose=args.verbose)
        if issues:
            print(f"\n  [{fname}]")
            for iss in issues:
                print(iss)
            total_issues += len(issues)
        elif args.verbose:
            print(f"  {fname}: OK")
    if total_issues == 0:
        print("  All files pass convention check.")

    # 2. Cross-module consistency: user_block.sv <-> rp_blk.v
    print()
    print("=" * 60)
    print("2. Cross-module consistency: user_block.sv <-> rp_blk.v")
    print("=" * 60)
    if not {'user_block.sv', 'rp_blk.v'} <= set(all_ports):
        print("  SKIPPED — needs both user_block.sv and rp_blk.v.")
        sys.exit(1 if total_issues else 0)
    issues = check_pair(
        'user_block.sv', all_ports['user_block.sv'],
        'rp_blk.v',      all_ports['rp_blk.v'],
        verbose=args.verbose,
    )
    if issues:
        for iss in issues:
            print(iss)
        total_issues += len(issues)
    else:
        print("  OK — no mismatches (intentional width differences excluded).")
        if args.verbose:
            print("  Intentional width differences:")
            for (port, fa, fb), note in INTENTIONAL_WIDTH_DIFFS.items():
                if fa == 'user_block.sv' and fb == 'rp_blk.v':
                    print(f"    {port}: {note}")

    # 3. Intentional differences reminder
    if not args.verbose and INTENTIONAL_SHELL_WIDTH_DIFFS:
        print()
        print("=" * 60)
        print("3. Known intentional shell_top wire-width differences (not checked)")
        print("   (run with -v to display)")
        print("=" * 60)
    if args.verbose:
        print()
        print("=" * 60)
        print("3. Known intentional shell_top wire-width differences")
        print("=" * 60)
        for wire, note in INTENTIONAL_SHELL_WIDTH_DIFFS.items():
            print(f"  {wire}: {note}")

    print()
    if total_issues:
        print(f"FAIL — {total_issues} issue(s) found.")
        sys.exit(1)
    else:
        print("PASS — no AXI direction issues found.")
        sys.exit(0)

if __name__ == '__main__':
    main()
