SHELL := /bin/bash
# =============================================================================
# VibeNIC DEPs — corpus self-checks.
#
#   make check         everything below
#   make check-bsv     compile the case-study NF against libs/  (needs bsc)
#   make check-sim     7 Bluesim testbenches + 4 cocotb suites + golden model
#                                              (needs bsc, verilator, cocotb)
#   make check-links   every relative markdown link resolves
#   make check-paths   no absolute host paths outside PROVENANCE.md
#   make check-axi     RP boundary port directions/widths       (needs python3)
#   make clean
#
# Nothing here needs Vivado; an actual FPGA build is driven from a shell
# checkout — see docs/14-build-and-load-flow.md.
# =============================================================================

NF := examples/case-study-nf

.PHONY: check
check: check-paths check-links check-axi check-bsv check-sim
	@echo
	@echo "====== all DEPs corpus checks passed ======"

# --- the libs/examples split actually compiles -------------------------------
.PHONY: check-bsv
check-bsv:
	@echo "== bsc: compiling $(NF) against libs/bsv =="
	@$(MAKE) --no-print-directory -C $(NF) compile
	@test -f $(NF)/verilog/mkVectorAvgNF.v \
	  || (echo "FAIL: mkVectorAvgNF.v not produced"; exit 1)
	@echo "OK: verilog/mkVectorAvgNF.v"

# --- both simulation tiers ---------------------------------------------------
.PHONY: check-sim
check-sim: check-bsv
	@echo "== golden model self-check =="
	@$(MAKE) --no-print-directory -C $(NF) golden
	@echo "== Bluesim tier =="
	@$(MAKE) --no-print-directory -C $(NF) bsim-all
	@echo "== cocotb/Verilator tier =="
	@$(MAKE) --no-print-directory -C $(NF) cocotb

# --- documentation integrity -------------------------------------------------
.PHONY: check-links
check-links:
	@echo "== markdown link check =="
	@python3 tools/check_links.py .

# Absolute host paths make the corpus non-relocatable. PROVENANCE.md is the one
# place they belong (it records where each file came from).
#
# The pattern matches any /home*/<user> or /local/<user> path, not one
# hard-coded username — a check that only knows its author's home directory
# passes for everyone else by accident. /tools and /opt are deliberately NOT
# matched: tests/cocotb/_paths.py carries one documented last-resort fallback
# to the reference bsc install, after $BSC_VERILOG_LIB and `bsc` on PATH.
# The bracket in the pattern keeps this recipe from matching itself.
.PHONY: check-paths
check-paths:
	@echo "== absolute-path hygiene =="
	@hits=$$(grep -rIn --exclude-dir=build --exclude-dir=.git \
	           --exclude-dir=__pycache__ --exclude-dir=sim_build \
	           --exclude=PROVENANCE.md --exclude=Makefile --exclude=results.xml \
	           -E '/(home[s]?|local|users)/[a-z][a-z0-9_-]+' . || true); \
	 if [ -n "$$hits" ]; then \
	   echo "$$hits"; \
	   echo "FAIL: absolute host paths outside PROVENANCE.md"; exit 1; \
	 fi
	@echo "OK: no absolute host paths outside PROVENANCE.md"

# --- boundary contract linter ------------------------------------------------
.PHONY: check-axi
check-axi:
	@echo "== AXI boundary check on libs/shell =="
	@python3 examples/scripts/check_axi.py --src-dir libs/shell

.PHONY: clean
clean:
	@$(MAKE) --no-print-directory -C $(NF) clean
	@find . -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true
	@rm -f $(NF)/tests/cocotb/results.xml
