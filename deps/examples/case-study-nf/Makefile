SHELL := /bin/bash
# =============================================================================
# VibeNIC DEPs — case-study NF (UDP vector-averaging, `mkVectorAvgNF`).
#
# Self-contained: the BSV building-block library and the vendored Verilog/SV IP
# come from the DEPs tree (../../libs), not from a sibling repo.
#
#   make tc     PKG=FourWayAverager        typecheck one src package (+deps)
#   make bsim   PKG=SimFourWayAverager MOD=mkSimFourWayAverager
#                                          Bluesim a pure-logic testbench
#   make bsim-all                          all 7 pure-logic testbenches
#   make compile                           bsc -> verilog/mkVectorAvgNF.v
#   make compile TOP_PKG=FlowTable TOP_MOD=mkFlowTable
#                                          any other synthesizable top
#   make cocotb                            all 4 cocotb/Verilator suites
#   make golden                            numpy golden-model self-check
#   make pack_ip                           package the NF as a Vivado IP
#   make clean
#
# The Vivado app build (OOC synth -> abstract-shell link -> route -> partial
# bitstream) is NOT driven from here: it runs `make app` in a shell checkout
# against a shell support package. See ../../docs/14-build-and-load-flow.md and
# ../tcl/app-build.tcl.
# =============================================================================

DEPS     := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))../..)
LIB_BSV  := $(DEPS)/libs/bsv
LIB_VL   := $(DEPS)/libs/verilog

SRC_DIR  := ./src
TEST_DIR := ./test
VL_DIR   := ./verilog
OBJ_DIR  := ./build

TOP_PKG  ?= VectorAvgNF
TOP_MOD  ?= mkVectorAvgNF

# ---- Bluespec ---------------------------------------------------------------
# `%` expands to the bsc library root, so this works for any bsc install.
BSLIB_PFX := %/Libraries
BSC_LIBS  := $(BSLIB_PFX):$(BSLIB_PFX)/Bus:$(BSLIB_PFX)/Flute_Addon:$(BSLIB_PFX)/AMBA_TLM3/TLM3:$(BSLIB_PFX)/AMBA_TLM3/Axi:$(BSLIB_PFX)/AMBA_TLM3/Axi4
BSC_VL    := $(SRC_DIR):$(LIB_VL):$(VL_DIR):%/Verilog.Vivado:%/Verilog
BSC_PATH  := $(TEST_DIR):$(SRC_DIR):$(LIB_BSV):$(VL_DIR):$(BSC_LIBS)
BSC_FLAGS := -u -bdir $(OBJ_DIR) -info-dir $(OBJ_DIR) -simdir $(OBJ_DIR) -elab \
             -p $(BSC_PATH) +RTS -K134217728 -RTS
BSC_WARN  := -suppress-warnings G0020:T0127:G0043:G0046:S0080

# The 7 testbenches with no `import "BVI"` in their closure — these run in
# Bluesim. SimFlowTable pulls the CachedCuckoo BVI and must go through
# cocotb + `verilator --cc` instead (see ../../docs/13-simulation-frameworks.md).
BSIM_TBS := SimCtrlRegs SimFourWayAverager SimHBMReadEngine SimLookupDispatcher \
            SimNotifyEngine SimPacketIngress SimResultEgress

# =============================================================================
.PHONY: tc
tc:
	@mkdir -p $(OBJ_DIR)
	bsc $(BSC_FLAGS) $(BSC_WARN) $(SRC_DIR)/$(PKG).bsv

.PHONY: bsim
bsim:
	@mkdir -p $(OBJ_DIR)
	bsc -sim $(BSC_FLAGS) $(BSC_WARN) -g $(MOD) $(TEST_DIR)/$(PKG).bsv
	bsc -sim $(BSC_FLAGS) -e $(MOD) -o $(OBJ_DIR)/$(MOD).bexe
	@echo "====== Bluesim: $(MOD) ======"
	@$(OBJ_DIR)/$(MOD).bexe

.PHONY: bsim-all
bsim-all:
	@set -e; for tb in $(BSIM_TBS); do \
	    $(MAKE) --no-print-directory bsim PKG=$$tb MOD=mk$$tb; \
	done
	@echo "====== all $(words $(BSIM_TBS)) Bluesim testbenches passed ======"

# Generate Verilog for a synthesizable top (default mkVectorAvgNF).
.PHONY: compile
compile:
	@mkdir -p $(VL_DIR) $(OBJ_DIR)
	bsc -verilog $(BSC_FLAGS) $(BSC_WARN) -vdir $(VL_DIR) -g $(TOP_MOD) $(SRC_DIR)/$(TOP_PKG).bsv

# cocotb/Verilator tier: the AXI-facing + BVI-dependent tests. All of them run
# here — an unexercised testbench rots, and one in this suite already did.
.PHONY: cocotb
cocotb: compile
	$(MAKE) --no-print-directory compile TOP_PKG=FlowTable TOP_MOD=mkFlowTable
	python3 tests/cocotb/run_vecavg_e2e.py
	python3 tests/cocotb/run_vecavg_nf.py
	python3 tests/cocotb/run_vecavg_stress.py
	python3 tests/cocotb/run_flow_table.py

# pytest gives better assertion messages but is not required: the self-check
# runs standalone too, and the reference install has no pytest.
.PHONY: golden
golden:
	@if python3 -c "import pytest" 2>/dev/null; then \
	   python3 -m pytest -q tests/golden/test_golden_selfcheck.py; \
	 else \
	   echo "(pytest absent — running standalone)"; \
	   python3 tests/golden/test_golden_selfcheck.py; \
	 fi

# BSV -> Vivado IP (nus.edu.sg:bsv:mkVectorAvgNF).
.PHONY: pack_ip
pack_ip: $(OBJ_DIR)/vivado_ip/component.xml
$(OBJ_DIR)/vivado_ip/component.xml: utils/pack_ip_vivado.tcl $(VL_DIR)/$(TOP_MOD).v
	vivado -mode batch -nojournal -notrace -log $(OBJ_DIR)/pack_ip.log -source $<

.PHONY: clean
clean:
	@rm -rf $(OBJ_DIR) $(VL_DIR) *.vcd ./.Xil sim_build results.xml
