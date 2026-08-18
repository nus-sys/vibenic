# =============================================================================
# VibeNIC DEPs — reusable RP boundary floorplan for Alveo U50.
#
# This is the constraint half of the boundary guard-slice technique; the cell
# half is ../bd/boundary-guard-ring.tcl. Every au50 RP app should start from
# this file — it is board-level, not design-level, and it is what makes the
# RP<->static partition-pin crossings close timing on this shell.
#
# "Start from", not "copy blindly": WHICH slices you put in the guard regions is
# a design decision. The filters below name all eight of ../bd/boundary-guard-ring.tcl's
# cells, which is the conservative default. Every `get_cells` here is `-quiet`,
# so a design that omits a slice (flow_reduce drives m_axibr straight from the
# NF and omits axi_regsl_pcibr) still applies this file unchanged — the filter
# simply matches nothing for that cell. Add or drop names to match what you
# actually built, and base the choice on your own post-route report.
#
# It does two things:
#   1. LOCs the HBM-clock MMCM to the one MMCM site the RP may use.
#   2. Creates three EXCLUDE_PLACEMENT guard pblocks over au50's three disjoint
#      partpin regions and puts ONLY the boundary register slices in them,
#      pushing the rest of the RP off the congested edge.
#
# Bespoke, design-specific floorplanning (module-compaction pblocks for an
# internally congested module) does NOT belong here — see
# ../../prompts/05-floorplanning-and-timing.md, and
# ./floorplan-flow-reduce-au50.xdc for a worked example of one.
#
# HOW IT MUST BE READ IN (app build.tcl):
#     import_files -fileset constrs_1 -norecurse <this file>
#     set_property SCOPED_TO_REF rp_blk   [get_files guard-pblocks-au50.xdc]
#     set_property USED_IN_SYNTHESIS false [get_files guard-pblocks-au50.xdc]
#
# SCOPED_TO_REF rp_blk is mandatory: bd_user contains identically-named
# static-side register slices, and an unscoped `get_cells -hierarchical` match
# hits both.
#
# IDEMPOTENCY is mandatory: this file is evaluated TWICE (once captured into the
# RP checkpoint, once re-applied at the abstract-shell link). That produces one
# `Vivado 12-795` "pblock already exists" critical PER PBLOCK — three here.
# Treat that count as a checksum; a different count means something changed.
# Never add `-remove` or any statement whose second application diverges.
# =============================================================================

# --- HBM-clock MMCM ----------------------------------------------------------
# `hbm_mmcm_i0` is a Clocking Wizard cell (see ../bd/hbm-subsystem.tcl). The
# MMCME4_ADV primitive inside its generated hierarchy is named `mmcme4_adv_inst`
# (standard clk_wiz naming), so -hierarchical leaf matching works both in the OOC
# synth context and after the link.
#
# MMCM_X0Y0 is the ONLY MMCM site in the X0 CMT column the RP may use on au50:
# MMCM_X0Y1 and MMCM_X0Y4 are carved out by the static shell (sysclk, pcie_rstn,
# hbm_cattrip). It sits at the bottom of SLR0 next to the HBM, and clear of the
# guard pblocks below (all at Y >= 180).
#
# Pair this with the `CLOCK_DEDICATED_ROUTE BACKBONE` exception in the app's
# post-link hook — the MMCM is in SLR0 but its free_100m_clk source BUFGCE is
# locked in SLR1 by the abstract shell, so the cascade cannot be vertically
# adjacent (Place 30-718). See ../tcl/pr-link-post.tcl.
set_property LOC MMCM_X0Y0 [get_cells -hierarchical mmcme4_adv_inst]

# --- Boundary guard pblocks --------------------------------------------------
# au50 has THREE disjoint partpin regions. Real partpin ranges (shell
# boards/au50/base.xdc), for reference — the guards below add a small margin:
#
#   AXI-MM  (s_axi_dma / s_axi_pcie / s_axil / m_axibr)  SLICE_X162Y240:X175Y389
#   AXIS-in (s_axis_rph2c / s_axis_ethrx0)               SLICE_X42Y375 :X51Y409
#   AXIS-out(m_axis_rpout0 / m_axis_rpout1)              SLICE_X129Y375:X140Y409
#
# EXCLUDE_PLACEMENT is correct HERE and almost nowhere else: these strips hold
# only their few boundary slices by design, so reserving them costs nothing and
# buys the decongestion. Do NOT reach for EXCLUDE_PLACEMENT on a chunky
# connected datapath module — it starves and repels its own neighbours.

create_pblock pb_guard_aximm
set_property EXCLUDE_PLACEMENT true [get_pblocks pb_guard_aximm]
resize_pblock [get_pblocks pb_guard_aximm] -add {SLICE_X160Y180:SLICE_X175Y389}
add_cells_to_pblock [get_pblocks pb_guard_aximm] [get_cells -quiet -hierarchical -filter {
    NAME =~ "*rp_user_i*axi_regsl_dma*"   || NAME =~ "*rp_user_i*axi_regsl_pcie*" ||
    NAME =~ "*rp_user_i*axi_regsl_pcibr*" || NAME =~ "*rp_user_i*axil_regsl*"
}]

# SNAPPING_MODE OFF on the two AXIS guards: they lie entirely inside pb_user's
# CLOCKREGION-defined region, and with default snapping the nested SLICE range
# collapses to empty (DRC HDPR-14 / HDPR-18). OFF keeps the exact range so the
# guard nests under pb_user by geometric containment.
create_pblock pb_guard_axis_in
set_property SNAPPING_MODE OFF [get_pblocks pb_guard_axis_in]
set_property EXCLUDE_PLACEMENT true [get_pblocks pb_guard_axis_in]
resize_pblock [get_pblocks pb_guard_axis_in] -add {SLICE_X41Y360:SLICE_X52Y418}
add_cells_to_pblock [get_pblocks pb_guard_axis_in] [get_cells -quiet -hierarchical -filter {
    NAME =~ "*rp_user_i*axis_regsl_rph2c*" || NAME =~ "*rp_user_i*axis_regsl_ethrx0*"
}]

create_pblock pb_guard_axis_out
set_property SNAPPING_MODE OFF [get_pblocks pb_guard_axis_out]
set_property EXCLUDE_PLACEMENT true [get_pblocks pb_guard_axis_out]
resize_pblock [get_pblocks pb_guard_axis_out] -add {SLICE_X128Y360:SLICE_X141Y418}
add_cells_to_pblock [get_pblocks pb_guard_axis_out] [get_cells -quiet -hierarchical -filter {
    NAME =~ "*rp_user_i*axis_regsl_rpout0*" || NAME =~ "*rp_user_i*axis_regsl_rpout1*"
}]
