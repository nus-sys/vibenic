#!/usr/bin/env python3
"""
Run the mkFlowTable cocotb test on the Verilator backend.

Why Verilator (not iverilog): the vendor cuckoo (libs/verilog/cached_cuckoo.sv et al.)
uses SV-2012 that iverilog 10.3 cannot parse. cocotb's Verilator backend uses
`verilator --cc` (C++14, no --timing/--binary), which g++ 10.5 compiles fine —
unlike the Makefile's `verilator --binary --timing` path that needs C++20.

Prereq: generate the DUT Verilog first (from examples/case-study-nf/):
    make compile TOP_PKG=FlowTable TOP_MOD=mkFlowTable   (-> verilog/mkFlowTable.v)

Usage:  python3 tests/cocotb/run_flow_table.py
"""
import os
import sys
from pathlib import Path
from cocotb.runner import get_runner

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _paths import APP, BUILD_ARGS  # noqa: E402


# Top DUT explicitly; the CachedCuckoo BVI + its SV closure (uram_cuckoo,
# uram_bank, hash_func, cuckoo_hash*, cam_cache, priority_encoder) and the bsc
# primitives (FIFO2/FIFOL1/SizedFIFO) are auto-resolved from the -y libdirs.
SOURCES = [
    APP / "verilog" / "mkFlowTable.v",
]



def main():
    missing = [str(s) for s in SOURCES if not s.exists()]
    if missing:
        sys.exit("Missing sources (run bsc -g mkFlowTable first):\n  " +
                  "\n  ".join(missing))

    runner = get_runner("verilator")
    runner.build(
        verilog_sources=[str(s) for s in SOURCES],
        hdl_toplevel="mkFlowTable",
        build_args=BUILD_ARGS,
        build_dir=str(APP / "build" / "cocotb_flowtable"),
        always=True,
    )
    runner.test(
        hdl_toplevel="mkFlowTable",
        test_module="test_flow_table",
        test_dir=str(APP / "tests" / "cocotb"),
        build_dir=str(APP / "build" / "cocotb_flowtable"),
    )


if __name__ == "__main__":
    os.environ.setdefault("PYTHONUNBUFFERED", "1")
    main()
