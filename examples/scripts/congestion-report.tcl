# =============================================================================
# VibeNIC DEPs — post-route timing/congestion triage for an RP app.
#
# Answers the one question you must answer BEFORE writing any floorplan
# constraint: is the worst path deep (logic-bound) or detoured (route-bound)?
#
#   logic >> route  -> the module is too deep. Pipeline it. A pblock will not help.
#   route >> logic  -> the module is badly placed or congested. Floorplan it.
#
# The case study's worst path was 79.5 % route / 1.34 ns logic over 12 levels —
# a placement problem misdiagnosed as a depth problem costs a 3 h build.
#
# Reference: ../../prompts/05-floorplanning-and-timing.md
#            ../../docs/05-floorplan-au50.md
#
# Usage (Vivado batch, on a ROUTED checkpoint — not post-place, not
# router-init; those numbers are provisional and can unwind during rip-up):
#
#   source /tools/Xilinx/Vivado/2024.2/settings64.sh
#   vivado -mode batch -notrace -source congestion-report.tcl \
#          -tclargs <routed.dcp> [n_paths] [out_dir]
# =============================================================================

set dcp   [lindex $argv 0]
set npath [expr {[llength $argv] > 1 ? [lindex $argv 1] : 10}]
set outd  [expr {[llength $argv] > 2 ? [lindex $argv 2] : "."}]

if { $dcp eq "" || ![file exists $dcp] } {
  puts "ERROR: give a routed .dcp as the first -tclargs argument"
  exit 1
}
file mkdir $outd
open_checkpoint $dcp

# --- 1. The real number ------------------------------------------------------
# Only a post-route summary counts. A "setup met" at post-physopt or router-init
# is not a result: on the case study BOTH a soft and an EXCLUDE flow-table
# pblock showed setup met at router-init and then degraded to ~-1.17 ns during
# Phase 5 Rip-up-And-Reroute.
puts "\n===== report_timing_summary (post-route) ====="
report_timing_summary -delay_type min_max -max_paths 5 \
    -file $outd/timing_summary.rpt
report_timing_summary -delay_type min_max -max_paths 1 -no_detailed_paths

# --- 2. Logic vs route split on the worst paths ------------------------------
# `Data Path Delay: ... (logic X% route Y%)` is the diagnosis line. A low logic%
# with fanout-1 nets burning 0.3-0.7 ns (vs ~0.05 uncongested) is the congestion
# signature.
puts "\n===== worst $npath setup paths: logic vs route ====="
report_timing -setup -max_paths $npath -nworst $npath -path_type full_clock_expanded \
    -input_pins -file $outd/worst_paths.rpt

foreach p [get_timing_paths -setup -max_paths $npath -nworst $npath] {
  set slack [get_property SLACK $p]
  set logic [get_property DATAPATH_LOGIC_DELAY $p]
  set route [get_property DATAPATH_NET_DELAY $p]
  set lvls  [get_property LOGIC_LEVELS $p]
  set total [expr {$logic + $route}]
  set pct   [expr {$total > 0 ? 100.0 * $route / $total : 0}]
  set verdict [expr {$pct > 60 ? "ROUTE-BOUND (floorplan it)" \
                               : "LOGIC-BOUND (pipeline it)"}]
  puts [format "  slack %7.3f  levels %3d  logic %6.3f  route %6.3f  route%%%5.1f  %s" \
        $slack $lvls $logic $route $pct $verdict]
  puts [format "      startpoint %s" [get_property STARTPOINT_PIN $p]]
  puts [format "      endpoint   %s" [get_property ENDPOINT_PIN   $p]]
}

# --- 3. Which cells are congested, and on which resource ---------------------
# Names the congested window's cells and the saturated resource. On the case
# study every window was the cuckoo table with URAM = 100 %: the fix was to
# OVER-PROVISION URAM sites in a soft pblock so the placer stops packing them,
# not to shrink anything.
puts "\n===== report_design_analysis -congestion ====="
report_design_analysis -congestion -complexity -timing \
    -file $outd/design_analysis.rpt
report_design_analysis -congestion

# --- 4. Utilisation, per the RP pblock ---------------------------------------
# pb_user congestion NEVER means resource shortage on this shell — the RP pblock
# is huge and the RP design is small. If utilisation is low and congestion is
# high, the cause is the static/partpin geometry squeezing the RP's shape.
puts "\n===== utilization ====="
report_utilization -file $outd/utilization.rpt
if { [llength [get_pblocks -quiet pb_user]] } {
  report_utilization -pblocks [get_pblocks pb_user]
}

puts "\nreports written to $outd/"
