#!/usr/bin/env python3
"""
Run the mkVectorAvgNF end-to-end hit-path test on the Verilator backend
(cocotb --cc path; the top pulls the CachedCuckoo BVI).

Prereq (from examples/case-study-nf/):  make compile     # -> verilog/mk*.v

Usage:  python3 tests/cocotb/run_vecavg_e2e.py
"""
import sys
from pathlib import Path
from cocotb.runner import get_runner

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _paths import APP, BUILD_ARGS  # noqa: E402


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
        build_dir=str(APP / "build" / "cocotb_e2e"),
        always=True,
    )
    runner.test(
        hdl_toplevel="mkVectorAvgNF",
        test_module="test_vecavg_e2e",
        test_dir=str(APP / "tests" / "cocotb"),
        build_dir=str(APP / "build" / "cocotb_e2e"),
    )


if __name__ == "__main__":
    main()
