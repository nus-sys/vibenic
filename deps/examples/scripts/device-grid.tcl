# =============================================================================
# VibeNIC DEPs — regenerate the clock-region resource census in
# docs/05-floorplan-au50.md § "What a clock region actually holds" and
# docs/06-board-deltas.md § "Clock-region maps".
#
# No design and no checkpoint needed — this queries the device database only:
#
#   vivado -mode batch -source device-grid.tcl -tclargs xcu50-fsvh2104-2-e
#   vivado -mode batch -source device-grid.tcl -tclargs xcu55c-fsvh2892-2L-e
#   vivado -mode batch -source device-grid.tcl -tclargs xcu280-fsvh2892-2L-e
#
# Use Vivado 2024.2 for au50/au55c and 2023.2 for au280 — xcu280 is absent from
# the 2024.2 install (docs/06-board-deltas.md).
#
# `link_design -part` is required: get_clock_regions / get_slrs / get_sites all
# need an open design, and create_project -in_memory alone does not open one.
#
# Site-type names that trip people up on UltraScale+:
#   * a BRAM tile is ONE `RAMBFIFO36` site plus `RAMB181` + `RAMBFIFO18`. Count
#     RAMBFIFO36 for "BRAM36", not the RAMB18s, or you double it.
#   * SLICE = SLICEL + SLICEM. LUTs = 8/slice, FFs = 16/slice.
#   * a LAGUNA site is 6 TX + 6 RX registers.
# =============================================================================
set part [lindex $argv 0]
create_project -in_memory -part $part
link_design -part $part

puts "### $part"
foreach s [get_slrs] {
    puts "SLR [get_property SLR_INDEX $s]: [llength [get_clock_regions -of_objects $s]] CRs"
}

foreach cr [lsort [get_clock_regions]] {
    set n [get_property NAME $cr]
    array set c {SLICEL 0 SLICEM 0 RAMBFIFO36 0 URAM288 0 DSP48E2 0 LAGUNA 0 MMCM 0 PLL 0 BUFGCE 0}
    set hard {}
    foreach s [get_sites -quiet -of_objects $cr] {
        set t [get_property SITE_TYPE $s]
        if {[info exists c($t)]} {
            incr c($t)
        } elseif {[lsearch -exact {CMACE4 PCIE4CE4 PCIE40E4 ILKNE4 GTYE4_COMMON
                                   BLI_HBM_AXI_INTF SYSMONE4 CONFIG_SITE} $t] >= 0} {
            lappend hard $t
        }
    }
    # SLICE extent of this CR, in the SLICE_XnYn form pblocks and
    # HD.PARTPIN_RANGE use.
    set xs {} ; set ys {}
    foreach nm [get_property NAME [get_sites -quiet -of_objects $cr \
                                       -filter {SITE_TYPE =~ SLICE*}]] {
        regexp {SLICE_X(\d+)Y(\d+)} $nm -> x y
        lappend xs $x ; lappend ys $y
    }
    set xs [lsort -integer $xs] ; set ys [lsort -integer $ys]
    set slice [expr {$c(SLICEL) + $c(SLICEM)}]

    puts [format "%-6s SLR%s  SLICE %5d  LUT %6d  FF %7d  BRAM36 %3d  URAM %3d  DSP %4d  LAGUNA %4d  %s  %s" \
        $n [get_property SLR_INDEX [get_slrs -of_objects $cr]] \
        $slice [expr {$slice * 8}] [expr {$slice * 16}] \
        $c(RAMBFIFO36) $c(URAM288) $c(DSP48E2) $c(LAGUNA) \
        "SLICE_X[lindex $xs 0]Y[lindex $ys 0]:SLICE_X[lindex $xs end]Y[lindex $ys end]" \
        [concat [expr {$c(MMCM) ? "MMCM+PLLx$c(PLL)+BUFGCEx$c(BUFGCE)" : ""}] \
                [lsort -unique $hard]]]
    array unset c
}
