"""Shared path resolution for the cocotb runners.

Keeps the runners free of absolute host paths so the DEPs tree is relocatable.

  APP    the case-study NF root            (examples/case-study-nf)
  DEPS   the DEPs corpus root              (two levels up from APP)
  LIBVL  vendored Verilog/SV IP + bsc prims (libs/verilog)
  BSCV   the bsc Verilog primitive library

BSCV resolution order:
  1. $BSC_VERILOG_LIB
  2. <dir of `bsc` on PATH>/../lib/Verilog
"""
import os
import shutil
from pathlib import Path

APP = Path(__file__).resolve().parents[2]
DEPS = APP.parents[1]
LIBVL = DEPS / "libs" / "verilog"


def _find_bsc_verilog_lib() -> Path:
    env = os.environ.get("BSC_VERILOG_LIB")
    if env:
        return Path(env)
    bsc = shutil.which("bsc")
    if bsc:
        cand = Path(bsc).resolve().parent.parent / "lib" / "Verilog"
        if cand.is_dir():
            return cand
    raise RuntimeError(
        "cannot locate the bsc Verilog primitive library: set $BSC_VERILOG_LIB "
        "to <bsc-install>/lib/Verilog, or put `bsc` on PATH"
    )


BSCV = _find_bsc_verilog_lib()

#: Verilator build args shared by every runner in this directory.
BUILD_ARGS = [
    "-Wno-fatal",
    "-y", str(LIBVL),          # CachedCuckoo.v + the cuckoo SV closure
    "-y", str(BSCV),           # bsc primitives (FIFO2 / FIFOL1 / SizedFIFO / BRAM*)
    "+libext+.v+.sv",
    "--no-timing",             # cocotb drives `verilator --cc`, not --binary/--timing
]
