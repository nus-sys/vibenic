# App-local constraints for the flow_reduce (UDP Vector-Averaging NF) RP.
#
# Two things live here:
#   1. The HBM-clock MMCM LOC (bottom of the die, by the HBM).
#   2. A ring of EXCLUDE_PLACEMENT guard pblocks hugging the RP partpin columns,
#      each holding only that region's boundary register slices (added in
#      rp_user.tcl). This registers each partpin crossing right at the boundary
#      and pushes the rest of the RP logic off the congested edge -- the
#      technique app/hbm_loopback and app/au50_lb_guard use to close timing on
#      the same shell.
#
# Scoping note: build.tcl imports this SCOPED_TO_REF rp_blk, so it is evaluated
# once inside the RP module (get_cells never reaches the identically-named
# static-side slices), captured into the RP linked checkpoint, then translated
# by the abstract-shell link_design into the full user_block_inst/rp_user_inst/
# scope.

# --- HBM-clock MMCM ---------------------------------------------------------
# hbm_mmcm_i0 is a Clocking Wizard (xilinx.com:ip:clk_wiz:6.0) cell in
# rp_user.tcl; the underlying MMCME4_ADV primitive inside its generated
# hierarchy is named `mmcme4_adv_inst` (Vivado's standard clk_wiz naming).
# -hierarchical matches the leaf cell name at any depth, so this is correct in
# both the OOC-synth context and after the link. MMCM_X0Y0 is at the bottom of
# SLR0 by the HBM -- clear of the SLICE-range guard pblocks below (Y180..Y418).
set_property LOC MMCM_X0Y0 [get_cells -hierarchical mmcme4_adv_inst]

# --- Boundary guard pblocks -------------------------------------------------
# au50 has THREE disjoint partpin regions (boards/au50/base.xdc), so three guard
# pblocks. EXCLUDE_PLACEMENT reserves each strip for only its boundary register
# slices and pushes the rest of the RP logic off; routing is left unconstrained.
# Ranges are the proven hbm_loopback / au50_lb_guard rectangles (same shell
# package -> same partpins). Real partpin ranges, for reference (base.xdc):
#
#   AXI-MM  (s_axi_dma/pcie/axil, m_axibr)  SLICE_X162Y240:X175Y389
#   AXIS-in (s_axis_rph2c/ethrx0)           SLICE_X42Y375 :X51Y409
#   AXIS-out(m_axis_rpout0/1)               SLICE_X129Y375:X140Y409

# AXI-MM region: guard the s_axi_dma / s_axi_pcie / s_axil slices. (m_axibr is
# driven directly from nf_0 with no boundary slice; if a post-route report shows
# the m_axibr partpin crossing as critical, add an axi_regsl on it here.)
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

# --- Flow-table compaction pblock (timing closure) --------------------------
# Root cause of the post-route user_clk_m WNS -2.423 ns failure (7826 EPs): the
# cuckoo flow table (nf_0/inst/ft, the mkCachedCuckooServer wrap) was placed
# ENTIRELY in the top clock-region row -- CR X2Y6 (5718 prims) + X3Y6 (9691
# prims), a 1-CR-tall strip -- with all 16 of its URAMs stacked in X3Y6 and its
# victim-cache associative logic (fo=107/fo=34 broadcast nets) packed against
# those 100%-occupied URAM columns. Consequently the worst path is 79.5% ROUTE
# delay (5.21 ns of congested detour) with only 1.34 ns of logic over 12
# levels: a placement/congestion failure, NOT logic depth. The same top strip
# is also fought over by the 81k-prim HBM SmartConnects (hbm_sc_00/02/04).
#
# Fix (functionality-preserving -- golden stays byte-identical): pin the whole
# flow table with a SOFT, loosely-sized pblock in the wide-open lower-left 2x2
# clock-region block X0Y1:X1Y2. SOFT (no EXCLUDE_PLACEMENT) is the correct tool
# for a chunky, connected datapath module: it merely ATTRACTS the cuckoo cells
# to a resource-rich, roomy region off the congested top strip, while still
# letting neighbours (incl. logic wired to ft) share the area -- so nothing is
# starved or repelled. Sized LOOSE for decongestion: ~6.8k slices for ft's
# ~0.8-1.2k logic slices (~15-20% util), with URAM OVER-PROVISIONED
# (URAM288_X0Y16..47 = 32 sites for the 16 needed) so the placer never packs
# URAMs against each other (the 100%-URAM windows were the congestion trigger).
# The region is inside pb_user (which owns CLOCKREGION_X0Y1:X3Y2 -> fully RP, no
# static logic) and physically CLOSER to the HBMReadEngine/averager datapath
# (Y49..338) than the top strip; vacating the top also frees it for the HBM
# converters (aids the secondary hbm_axiclk -0.187 downsizer).
#
# Do NOT use EXCLUDE_PLACEMENT here: reserving the region would deny ft's unused
# space to everyone else and push connected neighbours away, HURTING their
# timing -- EXCLUDE is only for self-contained timing-critical blocks (and the
# tiny boundary guard strips above). And never trade SmartConnect mode/depth for
# timing. See benchmark/FLOORPLAN_TIMING.md "Module-compaction pblocks".
#
# RP-nested-pblock rules (learned the hard way -- a CLOCKREGION range fails):
#   * A pblock nested in the HD.RECONFIGURABLE partition must range EVERY
#     primitive type its cells use with concrete site ranges (DRC HDPR-18). ft
#     uses only SLICE-hosted prims (LUT/FF/CARRY/MUXF/SRL) + URAM288, so give an
#     explicit SLICE range AND a URAM288 range. A bare CLOCKREGION range does
#     NOT satisfy HDPR-18.
#   * SNAPPING_MODE OFF, so the exact ranges are kept and Vivado parents pb_ft
#     directly under pb_user (geometric containment) instead of snapping it into
#     a guard pblock -> avoids DRC HDPR-14 "no common ancestor". The lower-left
#     ranges below overlap none of the three guard pblocks (all at Y>=180 or
#     Y>=360), so pb_ft nests under pb_user as intended.
# Ranges are the device extents of clock regions X0Y1..X1Y2 on xcu50 (fsvh2104):
# SLICE_X0Y60:X56Y179 (6840 slices) and URAM288_X0Y16:X0Y47 (32 URAM sites, in
# the URAM-bearing CR column X1).
create_pblock pb_ft
set_property SNAPPING_MODE OFF [get_pblocks pb_ft]
resize_pblock [get_pblocks pb_ft] -add {SLICE_X0Y60:SLICE_X56Y179}
resize_pblock [get_pblocks pb_ft] -add {URAM288_X0Y16:URAM288_X0Y47}
add_cells_to_pblock [get_pblocks pb_ft] [get_cells -quiet -hierarchical -filter {
    NAME =~ "*rp_user_i*nf_0/inst/ft"
}]
