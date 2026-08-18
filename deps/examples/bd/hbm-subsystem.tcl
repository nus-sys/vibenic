# =============================================================================
# VibeNIC DEPs — known-good HBM subsystem for an RP block design (Alveo U50).
#
# The shell exposes NO HBM ports on the RP boundary (libs/shell/rp_blk.v). An
# app that wants HBM instantiates the controller and its converters inside its
# own `rp_user` block design and presents the NF a set of 512-bit @ user_clk
# AXI4 slaves. This file is that subsystem, factored out of the two validated
# designs (`rp-user-flow-reduce.tcl`, and the 4-channel hbm_loopback variant) so
# it can be sourced or pasted into a new app BD.
#
# Reference: ../../docs/07-vendored-ip-catalog.md  (per-IP config + traps)
#            ../../docs/05-floorplan-au50.md       (where these cells must land)
#            ../../prompts/03-vivado-bd-clamp.md   (BD Tcl rules)
#
# Usage from an app's `cr_bd_rp_user` proc, after the BD exists and the
# free_100m_clk / RST_N ports are created:
#
#     source <deps>/examples/bd/hbm-subsystem.tcl
#     vnd_hbm_clocks                          ;# clk_wiz + 2x proc_sys_reset
#     vnd_hbm_controller {00 01 02} {00 02 04}   ;# MCs enabled, SAXI driven
#     vnd_hbm_null_tie   {01 03 05}           ;# the undriven sibling PCs
#     foreach saxi {00 02 04} { vnd_hbm_path [current_bd_instance .] path_$saxi }
#     # then connect your masters to path_NN/S_AXI and path_NN/M_AXI to
#     # hbm_0/SAXI_NN with `-boundary_type upper`.
#
# Required IP (declare in the app's VLNV check list):
#   xilinx.com:ip:hbm:1.0            xilinx.com:ip:clk_wiz:6.0
#   xilinx.com:ip:proc_sys_reset:5.0 xilinx.com:ip:axi_register_slice:2.1
#   xilinx.com:ip:axi_clock_converter:2.1
#   xilinx.com:ip:axi_dwidth_converter:2.1
#   xilinx.com:ip:rama:1.1           xilinx.com:ip:xlconstant:1.1
#   xilinx.com:ip:axi_apb_bridge:3.0 xilinx.com:ip:axi_gpio:2.0
# =============================================================================

# -----------------------------------------------------------------------------
# 1. HBM clock generator.
#
# A Clocking Wizard CELL, not hand-written MMCME4_ADV RTL: rp_blk.v is fixed and
# cannot host app RTL, and catalog IP arrives with its clock pins already typed
# (TYPE=clk + CONFIG.FREQ_HZ). A `create_bd_cell -type module` RTL cell does not
# — its pins default to TYPE=undef, `set_property CONFIG.FREQ_HZ` on them
# SILENTLY no-ops, and the failure surfaces much later as BD 41-237 naming two
# IPs you never touched. See ../../prompts/03-vivado-bd-clamp.md.
#
# The underlying primitive is still reachable for a LOC constraint: clk_wiz
# names it `mmcme4_adv_inst`, matched with `get_cells -hierarchical`.
# See ../xdc/floorplan-flow-reduce-au50.xdc.
# -----------------------------------------------------------------------------
proc vnd_hbm_clocks { {name hbm_mmcm_i0} {clk_port free_100m_clk} {rst_port RST_N} } {
  set mmcm [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 $name]
  set_property -dict [list \
    CONFIG.PRIM_IN_FREQ               {100.000} \
    CONFIG.PRIM_SOURCE                {No_buffer} \
    CONFIG.CLKIN1_JITTER_PS           {100.0} \
    CONFIG.CLK_OUT1_PORT              {hbm_refclk} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {100.000} \
    CONFIG.CLK_OUT2_PORT              {hbm_apbclk} \
    CONFIG.CLKOUT2_USED               {true} \
    CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {100.000} \
    CONFIG.CLK_OUT3_PORT              {hbm_axiclk} \
    CONFIG.CLKOUT3_USED               {true} \
    CONFIG.CLKOUT3_REQUESTED_OUT_FREQ {450.000} \
    CONFIG.NUM_OUT_CLKS               {3} \
    CONFIG.CLKOUT1_DRIVES             {BUFG} \
    CONFIG.CLKOUT2_DRIVES             {BUFG} \
    CONFIG.CLKOUT3_DRIVES             {BUFG} \
    CONFIG.USE_LOCKED                 {true} \
    CONFIG.USE_RESET                  {true} \
    CONFIG.RESET_TYPE                 {ACTIVE_LOW} \
  ] $mmcm
  connect_bd_net [get_bd_ports $clk_port] [get_bd_pins $name/clk_in1]
  connect_bd_net [get_bd_ports $rst_port] [get_bd_pins $name/resetn]

  # Gate the AXI and APB resets on `locked`.
  create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 hbm_proc_rst
  create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 apb_proc_rst
  return $mmcm
}

# -----------------------------------------------------------------------------
# 2. HBM controller.
#
#   mc_list   memory controllers to enable, e.g. {00 01 02}
#   saxi_list the SAXI ports you will actually drive, e.g. {00 02 04}
#
# Lateral switch OFF (USER_SWITCH_ENABLE_00 FALSE): each used *even* SAXI
# commands its whole MC, i.e. one pseudo-channel pair, and SAXI_NN's window is
# fixed at NN*PC bytes. That makes an offset stored in a table value an
# HBM-absolute byte address for both the host preload path and the NF read path
# — the symmetric contract the case study relies on.
#
# PC = 256 MB on 8 GB parts (au50, au280); 512 MB on 16 GB (au55c).
# USER_DIS_REF_CLK_BUFG TRUE because the ref clock is already BUFG'd by clk_wiz.
#
# Lateral switch ON (USER_SWITCH_ENABLE_00 TRUE, a documented refarch
# alternative — not the default this file builds): addressing is qualitatively
# different, not just enabled-wider. Every SAXI can now reach every enabled
# MC, so it exposes *one segment per MC* (four `HBM_MEMnn` segments for four
# MCs) instead of one fixed window. A single BD `-offset/-range` call on the
# SAXI is then ambiguous — assign each segment individually, per MC, or
# `validate_bd_design` fails with a `BD 5-430` address-segment error. Doing
# that correctly still isn't enough on its own: by default every master is
# given every reachable segment, so two SAXIs that can both reach the same
# memory produce a `BD 41-1075` DMA-aperture-collision error at validation.
# Restrict each master's excluded/included segment list to its intended
# aperture (e.g. by `addr-bit` split) rather than leaving the default
# every-master-sees-everything mapping. Both failure modes are cheap to hit
# and cheap to fix at `RUN=0` (BD elaboration only, seconds) — validate the
# address map before committing to a full `RUN=1` build.
# -----------------------------------------------------------------------------
proc vnd_hbm_controller { {mc_list {00 01 02}} {saxi_list {00 02 04}} {name hbm_0} } {
  set hbm [create_bd_cell -type ip -vlnv xilinx.com:ip:hbm:1.0 $name]
  set cfg [list \
    CONFIG.USER_HBM_DENSITY            {4GB} \
    CONFIG.USER_HBM_STACK              {1} \
    CONFIG.USER_SINGLE_STACK_SELECTION {LEFT} \
    CONFIG.USER_MEMORY_DISPLAY         {4096} \
    CONFIG.USER_AUTO_POPULATE          {yes} \
    CONFIG.USER_DIS_REF_CLK_BUFG       {TRUE} \
    CONFIG.USER_DEBUG_EN               {FALSE} \
    CONFIG.USER_XSDB_INTF_EN           {FALSE} \
    CONFIG.USER_APB_EN                 {true} \
    CONFIG.USER_INIT_TIMEOUT_VAL       {0} \
    CONFIG.USER_HBM_REF_CLK_0          {100} \
    CONFIG.USER_AXI_CLK_FREQ           {450} \
    CONFIG.USER_AXI_INPUT_CLK_FREQ     {450} \
    CONFIG.USER_SWITCH_ENABLE_00       {FALSE} \
    CONFIG.USER_CLK_SEL_LIST0          {AXI_15_ACLK} \
    CONFIG.USER_MC_ENABLE_APB_00       {TRUE} \
  ]
  foreach mc {00 01 02 03 04 05 06 07} {
    set on [expr {[lsearch -exact $mc_list $mc] >= 0 ? "TRUE" : "FALSE"}]
    lappend cfg CONFIG.USER_MC_ENABLE_$mc  $on
    lappend cfg CONFIG.USER_PHY_ENABLE_$mc $on
  }
  # The ECC-bypass parameter is named by the MC's *integer* index
  # (USER_MC0_ECC_BYPASS .. USER_MC15_ECC_BYPASS), regardless of stack
  # configuration, while $mc is zero-padded. Use `scan %d`, not
  # `string trimleft $mc 0` -- the latter yields the empty string for MC "00"
  # and asks for a parameter that does not exist. Vivado answers a bad
  # parameter name with CRITICAL WARNING [BD 41-1276], *not* an error, so the
  # setting is silently skipped and the build carries on.
  foreach mc $mc_list {
    lappend cfg CONFIG.USER_MC[scan $mc %d]_ECC_BYPASS {true}
  }
  set_property -dict $cfg $hbm
  return $hbm
}

# -----------------------------------------------------------------------------
# 3. Null-tie the SAXI ports you do NOT drive.
#
# An enabled MC's second pseudo-channel still needs a legally idle AXI3 master
# or the controller stalls. Tie straight to the cell's own *flattened physical*
# pins — note the name is `hbm_0/AXI_01_ARVALID`, NOT `SAXI_01_ARVALID`: the
# interface pin's name is not the physical-pin prefix. Always enumerate with
# `get_bd_pins -of_objects [get_bd_intf_pins hbm_0/SAXI_01]` rather than
# guessing. Emits benign `BD 41-1306` "connection overridden" warnings.
# -----------------------------------------------------------------------------
proc vnd_hbm_null_tie { saxi_list {name hbm_0} } {
  foreach {w v nm} {1 0 toff_zero_1b  1 1 toff_one_1b   2 0 toff_zero_2b \
                    3 0 toff_zero_3b  4 0 toff_zero_4b  6 0 toff_zero_6b \
                    32 0 toff_zero_32b 33 0 toff_zero_33b 256 0 toff_zero_256b} {
    set c [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 $nm]
    set_property -dict [list CONFIG.CONST_WIDTH $w CONFIG.CONST_VAL $v] $c
  }
  foreach saxi $saxi_list {
    foreach {src pin} [list \
        toff_zero_33b  ARADDR   toff_zero_2b  ARBURST  toff_zero_6b  ARID \
        toff_zero_4b   ARLEN    toff_zero_3b  ARSIZE   toff_zero_1b  ARVALID \
        toff_zero_33b  AWADDR   toff_zero_2b  AWBURST  toff_zero_6b  AWID \
        toff_zero_4b   AWLEN    toff_zero_3b  AWSIZE   toff_zero_1b  AWVALID \
        toff_zero_256b WDATA    toff_zero_1b  WLAST    toff_zero_32b WSTRB \
        toff_zero_1b   WVALID   toff_one_1b   BREADY   toff_one_1b   RREADY] {
      connect_bd_net [get_bd_pins $src/dout] [get_bd_pins $name/AXI_${saxi}_${pin}]
    }
  }
}

# -----------------------------------------------------------------------------
# 4. Per-channel conversion path: 512b @ user_clk (200 MHz) -> 256b @ 450 MHz.
#
#   S_AXI -> regsl_entry (REG=10, LAGUNA: this hop crosses the SLR boundary on
#                         au50 — DMA/NF logic sits in SLR1, HBM in SLR0)
#         -> clk_conv    (async user_clk -> hbm_axiclk)
#         -> slice_b     (REG=7 @ 450 MHz; LOAD-BEARING — without it TNS blew
#                         up to ~-880 ns in the hbm_loopback bring-up)
#         -> dwidth_conv (512 -> 256, splits arbitrary AXI4 bursts correctly)
#         -> regsl_rama  (REG=7)
#         -> rama        (reorder buffer, per_memory interleave, depth 512)
#         -> M_AXI  (connect to hbm_0/SAXI_NN with `-boundary_type upper`)
#
# REG=10/15 force LAGUNA primitives. Use them ONLY where an SLR boundary is
# really crossed — elsewhere they add a hop and make timing worse.
# See ../../docs/07-vendored-ip-catalog.md § register slices.
# -----------------------------------------------------------------------------
proc vnd_hbm_path { parentCell nameHier } {

  if { $parentCell eq "" || $nameHier eq "" } {
    catch {common::send_gid_msg -ssname BD::TCL -id 2092 -severity "ERROR" \
        "vnd_hbm_path() - Empty argument(s)!"}
    return
  }
  set parentObj  [get_bd_cells $parentCell]
  set parentType [get_property TYPE $parentObj]
  if { $parentType ne "hier" } {
    catch {common::send_gid_msg -ssname BD::TCL -id 2091 -severity "ERROR" \
        "Parent <$parentObj> has TYPE = <$parentType>. Expected <hier>."}
    return
  }

  set oldCurInst [current_bd_instance .]
  current_bd_instance $parentObj
  set hier_obj [create_bd_cell -type hier $nameHier]
  current_bd_instance $hier_obj

  create_bd_intf_pin -mode Slave  -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI
  create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 M_AXI

  create_bd_pin -dir I -type clk aclk_user
  create_bd_pin -dir I -type rst aresetn_user
  create_bd_pin -dir I -type clk aclk_hbm
  create_bd_pin -dir I -type rst aresetn_hbm

  set regsl_entry [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_register_slice:2.1 regsl_entry]
  set_property -dict [list \
    CONFIG.REG_AR {10} CONFIG.REG_AW {10} CONFIG.REG_B {10} \
    CONFIG.REG_R  {10} CONFIG.REG_W  {10} \
  ] $regsl_entry

  set clk_conv [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_clock_converter:2.1 clk_conv]

  set slice_b [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_register_slice:2.1 slice_b]
  set_property -dict [list \
    CONFIG.REG_AR {7} CONFIG.REG_AW {7} CONFIG.REG_B {7} \
    CONFIG.REG_R  {7} CONFIG.REG_W  {7} \
  ] $slice_b

  set dwidth_conv [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dwidth_converter:2.1 dwidth_conv]
  set_property -dict [list \
    CONFIG.SI_DATA_WIDTH.VALUE_SRC USER \
    CONFIG.MI_DATA_WIDTH.VALUE_SRC USER \
    CONFIG.SI_DATA_WIDTH {512} \
    CONFIG.MI_DATA_WIDTH {256} \
  ] $dwidth_conv

  set regsl_rama [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_register_slice:2.1 regsl_rama]
  set_property -dict [list \
    CONFIG.REG_AR {7} CONFIG.REG_AW {7} CONFIG.REG_B {7} \
    CONFIG.REG_R  {7} CONFIG.REG_W  {7} \
  ] $regsl_rama

  set rama [create_bd_cell -type ip -vlnv xilinx.com:ip:rama:1.1 rama]
  set_property -dict [list \
    CONFIG.G_MEM_INTERLEAVE_TYPE {per_memory} \
    CONFIG.G_MEM_COUNT           {32} \
    CONFIG.G_REORDER_QUEUE_DEPTH {512} \
  ] $rama

  connect_bd_intf_net [get_bd_intf_pins S_AXI]              [get_bd_intf_pins regsl_entry/S_AXI]
  connect_bd_intf_net [get_bd_intf_pins regsl_entry/M_AXI]  [get_bd_intf_pins clk_conv/S_AXI]
  connect_bd_intf_net [get_bd_intf_pins clk_conv/M_AXI]     [get_bd_intf_pins slice_b/S_AXI]
  connect_bd_intf_net [get_bd_intf_pins slice_b/M_AXI]      [get_bd_intf_pins dwidth_conv/S_AXI]
  connect_bd_intf_net [get_bd_intf_pins dwidth_conv/M_AXI]  [get_bd_intf_pins regsl_rama/S_AXI]
  connect_bd_intf_net [get_bd_intf_pins regsl_rama/M_AXI]   [get_bd_intf_pins rama/s_axi]
  connect_bd_intf_net [get_bd_intf_pins rama/m_axi]         [get_bd_intf_pins M_AXI]

  connect_bd_net [get_bd_pins aclk_user] \
    [get_bd_pins regsl_entry/aclk] \
    [get_bd_pins clk_conv/s_axi_aclk]
  connect_bd_net [get_bd_pins aresetn_user] \
    [get_bd_pins regsl_entry/aresetn] \
    [get_bd_pins clk_conv/s_axi_aresetn]
  connect_bd_net [get_bd_pins aclk_hbm] \
    [get_bd_pins clk_conv/m_axi_aclk] \
    [get_bd_pins slice_b/aclk] \
    [get_bd_pins dwidth_conv/s_axi_aclk] \
    [get_bd_pins regsl_rama/aclk] \
    [get_bd_pins rama/axi_aclk]
  connect_bd_net [get_bd_pins aresetn_hbm] \
    [get_bd_pins clk_conv/m_axi_aresetn] \
    [get_bd_pins slice_b/aresetn] \
    [get_bd_pins dwidth_conv/s_axi_aresetn] \
    [get_bd_pins regsl_rama/aresetn] \
    [get_bd_pins rama/axi_aresetn]

  current_bd_instance $oldCurInst
}

# -----------------------------------------------------------------------------
# 5. Status readback: APB bridge onto SAPB_0 + a GPIO exposing
#    { 30'h0, cattrip, init_complete } so the host can poll readiness without
#    touching APB. HBM needs ~100 ms of init/scrub after every partial
#    bitstream load before traffic may flow — the host MUST poll this.
# -----------------------------------------------------------------------------
proc vnd_hbm_status { {name hbm_0} } {
  set gpio [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_0]
  set_property -dict [list \
    CONFIG.C_ALL_INPUTS  {1} \
    CONFIG.C_GPIO_WIDTH  {32} \
  ] $gpio

  set apb [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_apb_bridge:3.0 apb_bridge_hbm]
  set_property -dict [list \
    CONFIG.C_APB_NUM_SLAVES {1} \
    CONFIG.C_M_APB_PROTOCOL {apb3} \
  ] $apb

  set cat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 status_concat]
  set_property -dict [list CONFIG.NUM_PORTS {3} \
    CONFIG.IN0_WIDTH {1} CONFIG.IN1_WIDTH {1} CONFIG.IN2_WIDTH {30}] $cat
  set pad [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 status_pad]
  set_property -dict [list CONFIG.CONST_WIDTH {30} CONFIG.CONST_VAL {0}] $pad

  connect_bd_net [get_bd_pins $name/apb_complete_0]        [get_bd_pins status_concat/In0]
  connect_bd_net [get_bd_pins $name/DRAM_0_STAT_CATTRIP]   [get_bd_pins status_concat/In1]
  connect_bd_net [get_bd_pins status_pad/dout]             [get_bd_pins status_concat/In2]
  connect_bd_net [get_bd_pins status_concat/dout]          [get_bd_pins axi_gpio_0/gpio_io_i]
}
