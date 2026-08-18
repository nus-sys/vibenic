# App-local copy of script/pr_link_post.tcl (STEPS.INIT_DESIGN.TCL.POST hook)
# for flow_reduce: identical to the shared hook, plus one clocking exception
# between link and place. Not folded into the shared script because it's
# specific to this app's HBM MMCM and must not affect the other packaged apps.
#
# mmcme4_adv_inst (inside the hbm_mmcm_i0 Clocking Wizard cell, see
# rp_user.tcl) is LOC'd to MMCM_X0Y0 (SLR0, by the HBM -- floorplan.xdc) while
# its CLKIN1 source BUFGCE (user_block_inst/u_bufgce_rp_100m, gating the static
# free_100m_clk) is locked in SLR1 by the abstract shell. That MMCM-BUFGCE-MMCM
# cascade can't be vertically adjacent, so the clock placer's rule_bufg_mmcm
# fails (Place 30-718). BACKBONE routes it on the dedicated clock backbone
# across regions/SLR. The net only exists once the RP is folded into shell_top,
# hence it's set here (post-link), not in the OOC-synth-scoped floorplan.xdc.

puts ">>> Init Design: Swap Abstract Shell Top Design <<<"

set rpCellRef   user_block_inst/rp_user_inst
set rpLinkedDcp rp_user_inst_linked.dcp
# Abstract-shell DCP staged in the project root (build/<prjname>/), which is
# ../../ from this impl_1 run dir.
set absTopDcp   [lindex [glob ../../abs_shell_*.dcp] 0]

write_checkpoint -force $rpLinkedDcp
close_design
add_files $rpLinkedDcp
set_property SCOPED_TO_CELLS $rpCellRef [get_files $rpLinkedDcp]
add_files $absTopDcp
link_design -top shell_top -reconfig_partitions $rpCellRef

puts ">>> HBM MMCM clock exception: CLOCK_DEDICATED_ROUTE BACKBONE <<<"
set cdr_net [get_nets -quiet user_block_inst/rp_100m_clk]
if { $cdr_net eq "" } {
  error "expected static net user_block_inst/rp_100m_clk not found in linked design"
}
set_property CLOCK_DEDICATED_ROUTE BACKBONE $cdr_net
puts "Applied CLOCK_DEDICATED_ROUTE BACKBONE to $cdr_net"

write_checkpoint -force shell_linked.dcp

puts ">>> Floorplan Pblock Properties <<<"
foreach pb [get_pblocks] {
    puts "Pblock: $pb"
    puts "  PARENT          : [get_property PARENT          $pb]"
    puts "  CONTAIN_ROUTING : [get_property CONTAIN_ROUTING $pb]"
    puts "  IS_SOFT         : [get_property IS_SOFT         $pb]"
    puts "  GRID_RANGES     : [get_property GRID_RANGES     $pb]"
    puts "  DERIVED_RANGES  : [get_property DERIVED_RANGES  $pb]"
}
