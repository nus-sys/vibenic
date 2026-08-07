# =============================================================================
# VibeNIC DEPs — RP boundary guard register-slice ring (Alveo U50, single CMAC).
#
# WHAT: one RP-side register slice on each of au50's eight partition-pin
# interfaces, so every RP<->static crossing is registered right at the pin.
# Paired with the EXCLUDE_PLACEMENT guard pblocks in ../xdc/guard-pblocks-au50.xdc,
# this is the technique that closes RP boundary timing on this shell
# (au50_lb_guard: clean; hbm_loopback: post-route WNS +0.020 ns).
#
# WHY IT MATTERS: without the ring, the `rpout` egress crossing alone left
# hbm_loopback at -0.026 ns. The slices cost latency and almost no area.
#
# THIS IS AN EXAMPLE, NOT A FIXED SET. It guards all eight because that is the
# conservative starting point and the seven 512-bit crossings are where the
# width makes the pin path expensive. Which interfaces belong in your guard
# region is YOUR decision: drop a slice you do not drive, or one a post-route
# report shows is nowhere near critical. flow_reduce, for instance, drives
# m_axibr straight from the NF and closes its boundary paths without that
# slice. Decide from your own timing report, and say what you decided and why
# — see ../../prompts/05-floorplanning-and-timing.md.
#
# The slice CONFIG must match the fixed rp_blk.v contract EXACTLY or the
# abstract-shell link mismatches — and `RUN=0` will not catch it (no synth).
# Verify against libs/shell/rp_blk.v, never against a sibling app's comments:
#
#   * The AXI-MM slaves (s_axi_dma, s_axi_pcie) carry
#     ar/awsize + qos/cache/lock/prot but NO region  -> HAS_REGION 0,
#     SUPPORTS_NARROW_BURST 1, ID_WIDTH 2, ADDR 64, DATA 512.
#   * m_axibr is NOT the same shape: it has NO cache/lock/prot/qos/region and
#     its IDs are [3:0]                              -> those four HAS_* 0,
#     ID_WIDTH 4. Reusing the slave config here mismatches the link.
#   * s_axil has NO prot and NO wstrb                -> HAS_PROT 0, HAS_WSTRB 0.
#   * AXI-Stream ports are 512b with tkeep+tstrb+tlast and
#     tid[16]/tdest[16]/tuser[32]                    -> TDATA_NUM_BYTES 64,
#     TID_WIDTH 16, TDEST_WIDTH 16, TUSER_WIDTH 32, REG_CONFIG 8 (full reg).
#
# Do NOT use REG_AR/AW/B/R/W = 10 or 15 here: those force LAGUNA primitives and
# belong only on real SLR crossings (the HBM path_NN entry slice). On a
# non-crossing path they add a hop and make timing worse.
#
# Reference: ../../docs/02-rp-boundary-contract.md
#            ../../prompts/05-floorplanning-and-timing.md
#
# Usage inside `cr_bd_rp_user`:
#     source <deps>/examples/bd/boundary-guard-ring.tcl
#     vnd_guard_ring
#     # then splice each slice between its external port and the fabric, e.g.
#     connect_bd_intf_net [get_bd_intf_ports s_axi_dma] \
#                         [get_bd_intf_pins axi_regsl_dma/S_AXI]
#     connect_bd_intf_net [get_bd_intf_pins axi_regsl_dma/M_AXI] \
#                         [get_bd_intf_pins dma_sc/S00_AXI]
#
# The cell NAMES below are load-bearing: the guard pblocks in floorplan.xdc
# select them by `NAME =~ "*rp_user_i*axi_regsl_dma*"` etc. Rename in both
# places or not at all.
# =============================================================================

proc vnd_guard_ring { } {

  # --- AXI4-MM slave guards: s_axi_dma, s_axi_pcie ---------------------------
  foreach mm_rs {axi_regsl_dma axi_regsl_pcie} {
    set rs [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_register_slice:2.1 $mm_rs]
    set_property -dict [list \
      CONFIG.ADDR_WIDTH            {64} \
      CONFIG.DATA_WIDTH            {512} \
      CONFIG.HAS_BRESP             {1} \
      CONFIG.HAS_BURST             {1} \
      CONFIG.HAS_CACHE             {1} \
      CONFIG.HAS_LOCK              {1} \
      CONFIG.HAS_PROT              {1} \
      CONFIG.HAS_QOS               {1} \
      CONFIG.HAS_REGION            {0} \
      CONFIG.HAS_RRESP             {1} \
      CONFIG.HAS_WSTRB             {1} \
      CONFIG.ID_WIDTH              {2} \
      CONFIG.MAX_BURST_LENGTH      {256} \
      CONFIG.PROTOCOL              {AXI4} \
      CONFIG.READ_WRITE_MODE       {READ_WRITE} \
      CONFIG.SUPPORTS_NARROW_BURST {1} \
    ] $rs
  }

  # --- AXI4-MM master guard: m_axibr -----------------------------------------
  # Config is au50_lb_guard's as-built one, and it is NOT the slave config
  # above: no cache/lock/prot/qos, ID_WIDTH 4. See the header.
  set axi_regsl_pcibr [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_register_slice:2.1 axi_regsl_pcibr]
  set_property -dict [list \
    CONFIG.ADDR_WIDTH            {64} \
    CONFIG.ARUSER_WIDTH          {0} \
    CONFIG.AWUSER_WIDTH          {0} \
    CONFIG.BUSER_WIDTH           {0} \
    CONFIG.DATA_WIDTH            {512} \
    CONFIG.HAS_BRESP             {1} \
    CONFIG.HAS_BURST             {1} \
    CONFIG.HAS_CACHE             {0} \
    CONFIG.HAS_LOCK              {0} \
    CONFIG.HAS_PROT              {0} \
    CONFIG.HAS_QOS               {0} \
    CONFIG.HAS_REGION            {0} \
    CONFIG.HAS_RRESP             {1} \
    CONFIG.HAS_WSTRB             {1} \
    CONFIG.ID_WIDTH              {4} \
    CONFIG.MAX_BURST_LENGTH      {256} \
    CONFIG.NUM_READ_OUTSTANDING  {64} \
    CONFIG.NUM_READ_THREADS      {3} \
    CONFIG.NUM_WRITE_OUTSTANDING {64} \
    CONFIG.NUM_WRITE_THREADS     {3} \
    CONFIG.PROTOCOL              {AXI4} \
    CONFIG.READ_WRITE_MODE       {READ_WRITE} \
    CONFIG.RUSER_BITS_PER_BYTE   {0} \
    CONFIG.RUSER_WIDTH           {0} \
    CONFIG.SUPPORTS_NARROW_BURST {1} \
    CONFIG.WUSER_BITS_PER_BYTE   {0} \
    CONFIG.WUSER_WIDTH           {0} \
  ] $axi_regsl_pcibr

  # --- AXI4-Lite guard: s_axil (no prot, no wstrb) ---------------------------
  set axil_regsl [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_register_slice:2.1 axil_regsl]
  set_property -dict [list \
    CONFIG.ADDR_WIDTH            {32} \
    CONFIG.DATA_WIDTH            {32} \
    CONFIG.HAS_BRESP             {1} \
    CONFIG.HAS_BURST             {0} \
    CONFIG.HAS_CACHE             {0} \
    CONFIG.HAS_LOCK              {0} \
    CONFIG.HAS_PROT              {0} \
    CONFIG.HAS_QOS               {0} \
    CONFIG.HAS_REGION            {0} \
    CONFIG.HAS_RRESP             {1} \
    CONFIG.HAS_WSTRB             {0} \
    CONFIG.PROTOCOL              {AXI4LITE} \
    CONFIG.READ_WRITE_MODE       {READ_WRITE} \
    CONFIG.SUPPORTS_NARROW_BURST {0} \
  ] $axil_regsl

  # --- AXI-Stream guards: 2 in (rph2c, ethrx0), 2 out (rpout0, rpout1) -------
  # On a dual-CMAC board add axis_regsl_ethrx1 (9 slices instead of 8).
  # These four plus the three AXI-MM above are the 512-bit crossings; s_axil is
  # the one narrow interface in the ring.
  foreach rp_rs {axis_regsl_rph2c axis_regsl_ethrx0 \
                 axis_regsl_rpout0 axis_regsl_rpout1} {
    set rs [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_register_slice:1.1 $rp_rs]
    set_property -dict [list \
      CONFIG.HAS_TKEEP       {1} \
      CONFIG.HAS_TLAST       {1} \
      CONFIG.HAS_TREADY      {1} \
      CONFIG.HAS_TSTRB       {1} \
      CONFIG.REG_CONFIG      {8} \
      CONFIG.TDATA_NUM_BYTES {64} \
      CONFIG.TDEST_WIDTH     {16} \
      CONFIG.TID_WIDTH       {16} \
      CONFIG.TUSER_WIDTH     {32} \
    ] $rs
  }
}
