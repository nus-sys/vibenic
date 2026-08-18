# App-local constraints for the HBM-loopback RP.
#
# Two things live here:
#   1. The HBM-clock MMCM LOC (bottom of the die, by the HBM).
#   2. A ring of EXCLUDE_PLACEMENT guard pblocks hugging the RP partpin columns,
#      each holding only that region's boundary register slices (the slices added
#      in rp_user.tcl). This registers each partpin crossing right at the boundary
#      and pushes the rest of the RP logic off the congested edge -- the technique
#      app/au50_lb_guard uses to close timing on the same shell. Applied here to
#      close the prior -0.026 ns rpout boundary path.
#
# Scoping note: build.tcl imports this SCOPED_TO_REF rp_blk, so it is evaluated
# once inside the RP module (get_cells never reaches the identically-named
# static-side slices), captured into the RP linked checkpoint, then translated by
# the abstract-shell link_design into the full user_block_inst/rp_user_inst/...
# scope.

# --- HBM-clock MMCM ---------------------------------------------------------
# hbm_mmcm_i0 is a Clocking Wizard (xilinx.com:ip:clk_wiz:6.0) cell in
# rp_user.tcl; the underlying MMCME4_ADV primitive inside its generated
# hierarchy is named `mmcme4_adv_inst` (Vivado's standard clk_wiz naming, not
# documented anywhere obvious). -hierarchical matches the leaf cell name at any
# depth, so this is correct in both the OOC-synth context and after the link.
# MMCM_X0Y0 is at the bottom of SLR0 by the HBM -- clear of the SLICE-range
# guard pblocks below (Y180..Y418), so no conflict.
set_property LOC MMCM_X0Y0 [get_cells -hierarchical mmcme4_adv_inst]

# --- Boundary guard pblocks -------------------------------------------------
# au50 has THREE disjoint partpin regions (boards/au50/base.xdc), so three guard
# pblocks. EXCLUDE_PLACEMENT reserves each strip for only its boundary register
# slices and pushes the rest of the RP logic off; routing is left unconstrained.
# Ranges are the proven au50_lb_guard rectangles (same shell package, so the same
# partpins). Real partpin ranges, for reference (base.xdc):
#
#   AXI-MM  (s_axi_dma/pcie/axil, m_axibr)  SLICE_X162Y240:X175Y389
#   AXIS-in (s_axis_rph2c/ethrx0)           SLICE_X42Y375 :X51Y409
#   AXIS-out(m_axis_rpout0/1)               SLICE_X129Y375:X140Y409

# AXI-MM region: guard the s_axi_dma / s_axi_pcie / s_axil slices. (m_axibr has
# no slice here -- it is null-tied to constants in rp_user.tcl.)
create_pblock pb_guard_aximm
set_property EXCLUDE_PLACEMENT true [get_pblocks pb_guard_aximm]
resize_pblock [get_pblocks pb_guard_aximm] -add {SLICE_X160Y180:SLICE_X175Y389}
add_cells_to_pblock [get_pblocks pb_guard_aximm] [get_cells -quiet -hierarchical -filter {
    NAME =~ "*rp_user_i*axi_regsl_dma*"  || NAME =~ "*rp_user_i*axi_regsl_pcie*" ||
    NAME =~ "*rp_user_i*axil_regsl*"
}]

# AXIS-in region: s_axis_rph2c / s_axis_ethrx0 slices.
# SNAPPING_MODE OFF: this strip lies entirely in pb_user's CLOCKREGION-defined
# region; with default snapping the nested SLICE range collapses to empty
# (HDPR-14/18). OFF keeps the exact SLICE range so it nests under pb_user.
create_pblock pb_guard_axis_in
set_property SNAPPING_MODE OFF [get_pblocks pb_guard_axis_in]
set_property EXCLUDE_PLACEMENT true [get_pblocks pb_guard_axis_in]
resize_pblock [get_pblocks pb_guard_axis_in] -add {SLICE_X41Y360:SLICE_X52Y418}
add_cells_to_pblock [get_pblocks pb_guard_axis_in] [get_cells -quiet -hierarchical -filter {
    NAME =~ "*rp_user_i*axis_regsl_rph2c*" || NAME =~ "*rp_user_i*axis_regsl_ethrx0*"
}]

# AXIS-out region: m_axis_rpout0 / m_axis_rpout1 slices.
# SNAPPING_MODE OFF for the same reason as pb_guard_axis_in.
create_pblock pb_guard_axis_out
set_property SNAPPING_MODE OFF [get_pblocks pb_guard_axis_out]
set_property EXCLUDE_PLACEMENT true [get_pblocks pb_guard_axis_out]
resize_pblock [get_pblocks pb_guard_axis_out] -add {SLICE_X128Y360:SLICE_X141Y418}
add_cells_to_pblock [get_pblocks pb_guard_axis_out] [get_cells -quiet -hierarchical -filter {
    NAME =~ "*rp_user_i*axis_regsl_rpout0*" || NAME =~ "*rp_user_i*axis_regsl_rpout1*"
}]
