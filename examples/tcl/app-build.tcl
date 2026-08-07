# App build: flow_reduce (UDP Vector-Averaging NF)
#
# Self-contained RP/app build driven by a packaged shell (support zip). The zip
# is unpacked + validated by script/prep_app_pkg.py into build/<prjname>_pkg/
# (the --shellpkg dir) before this runs. From there this build is
# package-driven: the Vivado part, the RP boundary RTL (rp_blk.v,
# board_config.vh) and the abstract shell DCP all come from the package, not the
# repo's src/ or boards/ trees.
#
# Differs from hbm_loopback's build only in the app dir and in adding the BSV
# NF's packaged-IP repo (app/flow_reduce/build/vivado_ip) to ip_repo_paths.
#
# Prereq: the BSV NF must already be packaged as a Vivado IP at
#   app/flow_reduce/build/vivado_ip/component.xml   (make pack_ip)
#
# Parameters (tclargs):
#   --board     board name (must match the package; au50 only for now)
#   --prjname   Vivado project name (created under build/)
#   --runjobs   synth/impl jobs; 0 = create project only
#   --shellpkg  staged support-package dir (build/<prjname>_pkg)

set board     au50
set prjname   ${board}_flow_reduce
set run_njobs 0
set shellpkg  ""

for {set i 0} {$i < $::argc} {incr i} {
  set option [string trim [lindex $::argv $i]]
  switch -regexp -- $option {
    "--board"    { incr i; set board     [lindex $::argv $i] }
    "--prjname"  { incr i; set prjname   [lindex $::argv $i] }
    "--runjobs"  { incr i; set run_njobs [lindex $::argv $i] }
    "--shellpkg" { incr i; set shellpkg  [lindex $::argv $i] }
    default      { incr i }
  }
}

set app_dir   app/flow_reduce
set bdname_rp rp_user

if { $shellpkg eq "" } {
  puts "ERROR: --shellpkg <dir> is required (run via 'make app')."
  exit 1
}
set shellpkg [file normalize $shellpkg]
if {![file isdirectory $shellpkg]} {
  puts "ERROR: staged package dir not found: $shellpkg"
  exit 1
}

# BSV NF IP repo (from `make pack_ip`).
set nfiprepo ./app/flow_reduce/build/vivado_ip
if {![file exists $nfiprepo/component.xml]} {
  puts "ERROR: NF IP not packaged ($nfiprepo/component.xml missing). Run 'make pack_ip' first."
  exit 1
}

# Vivado part/board from the staged package (self-contained).
source $shellpkg/params.tcl

set iprepo  ./ips
set prjpath ./build/$prjname

# Create project
create_project $prjname $prjpath -part $prjpart -force
set_property board_part $prjboard [current_project]
set_property ip_repo_paths [list [file normalize $iprepo] \
                                 [file normalize $nfiprepo]] [current_project]
update_ip_catalog

# Stage the abstract-shell DCP into the project root so pr_link_post_fr.tcl can
# find it via ../../abs_shell_*.dcp (relative to the impl_1 run dir).
set abs_dcps [glob -nocomplain $shellpkg/shell/abs_shell_*.dcp]
if {[llength $abs_dcps] == 0} {
  puts "ERROR: no abs_shell_*.dcp in $shellpkg/shell"
  exit 1
}
foreach d $abs_dcps { file copy -force $d $prjpath/[file tail $d] }

# RP boundary RTL from the package (not the repo).
import_files -fileset sources_1 -norecurse $shellpkg/src/rp_blk.v
import_files -fileset sources_1 -norecurse $shellpkg/src/board_config.vh

# App reconfigurable-module block design (NF + HBM read subsystem). The HBM
# clock generator is a Clocking Wizard IP cell inside the BD itself
# (rp_user.tcl), not app RTL, so no separate import is needed for it.
source $app_dir/${bdname_rp}.tcl
set_property REGISTERED_WITH_MANAGER "1" [get_files ${bdname_rp}.bd ]
set_property SYNTH_CHECKPOINT_MODE "Hierarchical" [get_files ${bdname_rp}.bd ]
add_files -norecurse [ make_wrapper -files [get_files ${bdname_rp}.bd] -top ]

update_compile_order -fileset sources_1

# App floorplan: HBM MMCM LOC + boundary guard pblocks. Scoped to the RP ref
# (rp_blk) so it is evaluated once, inside the RP only (never matching
# identically-named static-side cells), applied at impl init_design before the
# link hook captures the RP dcp; the abstract-shell link then translates it into
# the full hierarchy.
import_files -fileset constrs_1 -norecurse $app_dir/floorplan.xdc
set_property used_in_synthesis false [get_files floorplan.xdc]
set_property SCOPED_TO_REF rp_blk [get_files floorplan.xdc]

# Implementation strategy.
set_property strategy Performance_Auto_1 [get_runs impl_1]

# Synth OOC (kills boundary IO buffers) + post-init link to the abstract shell.
# App-local pr_link_post_fr.tcl adds the HBM MMCM's CLOCK_DEDICATED_ROUTE
# BACKBONE clocking exception (see that file).
import_files -fileset utils_1 -norecurse $app_dir/pr_link_post_fr.tcl
set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} -value {-mode out_of_context} -objects [get_runs synth_1]
set_property STEPS.INIT_DESIGN.TCL.POST [ get_files pr_link_post_fr.tcl -of [get_fileset utils_1] ] [get_runs impl_1]
set_property STEPS.WRITE_BITSTREAM.ARGS.BIN_FILE true [get_runs impl_1]
set_property -name {STEPS.WRITE_BITSTREAM.ARGS.MORE OPTIONS} -value {-cell user_block_inst/rp_user_inst} -objects [get_runs impl_1]

if { $run_njobs != 0 } {
  launch_runs synth_1 -jobs $run_njobs
  wait_on_run synth_1
  launch_runs impl_1 -jobs $run_njobs -to_step write_bitstream
  wait_on_run impl_1

  set st [get_property STATUS   [get_runs impl_1]]
  set pr [get_property PROGRESS [get_runs impl_1]]
  puts "RUN_DONE STATUS=$st PROGRESS=$pr"
}
