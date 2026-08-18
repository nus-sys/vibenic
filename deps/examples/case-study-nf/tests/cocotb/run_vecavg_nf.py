#!/usr/bin/env python3
"""
Run the mkVectorAvgNF top-level integration smoke on the Verilator backend
(cocotb --cc path; the top pulls the CachedCuckoo BVI so iverilog/--binary
are not options — see project memory).

Prereq (from examples/case-study-nf/):  make compile     # -> verilog/mk*.v

Usage:  python3 tests/cocotb/run_vecavg_nf.py
"""
import sys
from pathlib import Path
from cocotb.runner import get_runner

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _paths import APP, BUILD_ARGS  # noqa: E402


# All bsc-generated module Verilog (top + submodules); Sim*.v excluded. The
# CachedCuckoo BVI + cuckoo SV closure + bsc primitives auto-resolve from -y.
SOURCES = sorted(
    str(p) for p in (APP / "verilog").glob("*.v")
    if not p.name.startswith("mkSim")
)



def main():
    if not (APP / "verilog" / "mkVectorAvgNF.v").exists():
        sys.exit("verilog/mkVectorAvgNF.v missing — run `make compile` first")
    runner = get_runner("verilator")
    runner.build(
        verilog_sources=SOURCES,
        hdl_toplevel="mkVectorAvgNF",
        build_args=BUILD_ARGS,
        build_dir=str(APP / "build" / "cocotb_vecavg"),
        always=True,
    )
    runner.test(
        hdl_toplevel="mkVectorAvgNF",
        test_module="test_vecavg_nf",
        test_dir=str(APP / "tests" / "cocotb"),
        build_dir=str(APP / "build" / "cocotb_vecavg"),
    )


if __name__ == "__main__":
    main()
