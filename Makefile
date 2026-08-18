SHELL := /bin/bash
# =============================================================================
# VibeNIC — umbrella repository.
#
# The platform components are git submodules; the DEPs corpus is in deps/ and
# carries the self-checks.
#
#   make init          fetch qnic-shell and qnic-driver
#   make check         everything below
#   make check-bsv     compile the corpus case study    (needs bsc)
#   make check-sim     Bluesim + cocotb/Verilator tiers (needs bsc, verilator,
#                                                        cocotb)
#   make check-links   every relative markdown link resolves
#   make check-paths   no absolute host paths anywhere
#   make check-axi     RP boundary port directions/widths
#   make clean
#
# Nothing here needs Vivado. An FPGA build is driven from qnic-shell — see
# deps/docs/14-build-and-load-flow.md.
#
# Submodules are excluded from every check: their contents are another
# repository's responsibility.
# =============================================================================

SUBMODULES := qnic-shell qnic-driver

.PHONY: init
init:
	git submodule update --init --recursive

.PHONY: check
check: check-paths check-links check-axi check-bsv check-sim
	@echo
	@echo "====== all VibeNIC checks passed ======"

# --- delegated to the corpus --------------------------------------------------
.PHONY: check-bsv check-sim check-axi clean
check-bsv check-sim check-axi clean:
	@$(MAKE) --no-print-directory -C deps $@

# --- umbrella-wide documentation integrity ------------------------------------
.PHONY: check-links
check-links:
	@echo "== markdown link check =="
	@python3 deps/tools/check_links.py .

# Absolute host paths make the tree non-relocatable and leak the machine it was
# authored on. The pattern matches any /home*/<user>, /local/<user> or
# /users/<user> path rather than one hard-coded username -- a check that only
# knows its author's home directory passes for everyone else by accident. The
# bracket in the pattern keeps this recipe from matching itself.
.PHONY: check-paths
check-paths:
	@echo "== absolute-path hygiene =="
	@hits=$$(grep -rIn --exclude-dir=build --exclude-dir=.git \
	           --exclude-dir=__pycache__ --exclude-dir=sim_build \
	           $(addprefix --exclude-dir=,$(SUBMODULES)) \
	           --exclude=Makefile --exclude=results.xml \
	           -E '/(home[s]?|local|users)/[a-z][a-z0-9_-]+' . || true); \
	 if [ -n "$$hits" ]; then \
	   echo "$$hits"; \
	   echo "FAIL: absolute host paths in the tree"; exit 1; \
	 fi
	@echo "OK: no absolute host paths"
