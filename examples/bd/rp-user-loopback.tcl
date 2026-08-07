# Proc to create BD rp_user  --  au50_lb_guard example app
#
# Derived from boards/au50/rp_user.tcl (the proven single-CMAC loopback RP). The
# only functional change is a full ring of RP-side register slices on EVERY partpin
# interface, so that floorplan.xdc can pin just these slices into EXCLUDE_PLACEMENT
# guard pblocks hugging the partpin columns and push the rest of the RP logic off
# the congested boundary. Loopback datapath is unchanged.
#
# Boundary guard slices (8; au50 has 1 CMAC -> 2 input streams):
#   AXI-MM : axi_regsl_dma (s_axi_dma), axi_regsl_pcie (s_axi_pcie),
#            axi_regsl_pcibr (m_axibr), axil_regsl (s_axil)
#   AXIS   : axis_regsl_rph2c, axis_regsl_ethrx0 (in),
#            axis_regsl_rpout0, axis_regsl_rpout1 (out)

proc cr_bd_rp_user { parentCell } {

  set design_name rp_user

  common::send_gid_msg -ssname BD::TCL -id 2010 -severity "INFO" "Currently there is no design <$design_name> in project, so creating one..."

  create_bd_design $design_name

  set bCheckIPsPassed 1
  ##################################################################
  # CHECK IPs
  ##################################################################
  set bCheckIPs 1
  if { $bCheckIPs == 1 } {
     set list_check_ips "\
  xilinx.com:ip:axi_register_slice:2.1\
  xilinx.com:ip:axis_register_slice:1.1\
  xilinx.com:ip:axi_bram_ctrl:4.1\
  xilinx.com:ip:smartconnect:1.0\
  xilinx.com:ip:axi_gpio:2.0\
  xilinx.com:ip:blk_mem_gen:8.4\
  xilinx.com:ip:axis_data_fifo:2.0\
  xilinx.com:ip:axis_switch:1.1\
  xilinx.com:ip:vio:3.0\
  nus.edu.sg:bsv:AxisPacketRouterDual:1.0\
  "

   set list_ips_missing ""
   common::send_gid_msg -ssname BD::TCL -id 2011 -severity "INFO" "Checking if the following IPs exist in the project's IP catalog: $list_check_ips ."

   foreach ip_vlnv $list_check_ips {
      set ip_obj [get_ipdefs -all $ip_vlnv]
      if { $ip_obj eq "" } {
         lappend list_ips_missing $ip_vlnv
      }
   }

   if { $list_ips_missing ne "" } {
      catch {common::send_gid_msg -ssname BD::TCL -id 2012 -severity "ERROR" "The following IPs are not found in the IP Catalog:\n  $list_ips_missing\n\nResolution: Please add the repository containing the IP(s) to the project." }
      set bCheckIPsPassed 0
   }

  }

  if { $bCheckIPsPassed != 1 } {
    common::send_gid_msg -ssname BD::TCL -id 2023 -severity "WARNING" "Will not continue with creation of design due to the error(s) above."
    return 3
  }

  variable script_folder

  if { $parentCell eq "" } {
     set parentCell [get_bd_cells /]
  }

  set parentObj [get_bd_cells $parentCell]
  if { $parentObj == "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2090 -severity "ERROR" "Unable to find parent cell <$parentCell>!"}
     return
  }

  set parentType [get_property TYPE $parentObj]
  if { $parentType ne "hier" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2091 -severity "ERROR" "Parent <$parentObj> has TYPE = <$parentType>. Expected to be <hier>."}
     return
  }

  set oldCurInst [current_bd_instance .]
  current_bd_instance $parentObj


  # Create interface ports
  set m_axibr [ create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 m_axibr ]
  set_property -dict [ list \
   CONFIG.ADDR_WIDTH {64} \
   CONFIG.DATA_WIDTH {512} \
   CONFIG.FREQ_HZ {200000000} \
   CONFIG.HAS_CACHE {0} \
   CONFIG.HAS_LOCK {0} \
   CONFIG.HAS_PROT {0} \
   CONFIG.HAS_QOS {0} \
   CONFIG.NUM_READ_OUTSTANDING {32} \
   CONFIG.NUM_WRITE_OUTSTANDING {32} \
   CONFIG.PROTOCOL {AXI4} \
   ] $m_axibr

  set s_axi_dma [ create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 s_axi_dma ]
  set_property -dict [ list \
   CONFIG.ADDR_WIDTH {64} \
   CONFIG.ARUSER_WIDTH {0} \
   CONFIG.AWUSER_WIDTH {0} \
   CONFIG.BUSER_WIDTH {0} \
   CONFIG.DATA_WIDTH {512} \
   CONFIG.FREQ_HZ {200000000} \
   CONFIG.HAS_BRESP {1} \
   CONFIG.HAS_BURST {1} \
   CONFIG.HAS_CACHE {1} \
   CONFIG.HAS_LOCK {1} \
   CONFIG.HAS_PROT {1} \
   CONFIG.HAS_QOS {1} \
   CONFIG.HAS_REGION {1} \
   CONFIG.HAS_RRESP {1} \
   CONFIG.HAS_WSTRB {1} \
   CONFIG.ID_WIDTH {2} \
   CONFIG.MAX_BURST_LENGTH {1} \
   CONFIG.NUM_READ_OUTSTANDING {1} \
   CONFIG.NUM_READ_THREADS {1} \
   CONFIG.NUM_WRITE_OUTSTANDING {1} \
   CONFIG.NUM_WRITE_THREADS {1} \
   CONFIG.PROTOCOL {AXI4} \
   CONFIG.READ_WRITE_MODE {READ_WRITE} \
   CONFIG.RUSER_BITS_PER_BYTE {0} \
   CONFIG.RUSER_WIDTH {0} \
   CONFIG.SUPPORTS_NARROW_BURST {0} \
   CONFIG.WUSER_BITS_PER_BYTE {0} \
   CONFIG.WUSER_WIDTH {0} \
   ] $s_axi_dma

  set s_axi_pcie [ create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 s_axi_pcie ]
  set_property -dict [ list \
   CONFIG.ADDR_WIDTH {64} \
   CONFIG.ARUSER_WIDTH {0} \
   CONFIG.AWUSER_WIDTH {0} \
   CONFIG.BUSER_WIDTH {0} \
   CONFIG.DATA_WIDTH {512} \
   CONFIG.FREQ_HZ {200000000} \
   CONFIG.HAS_BRESP {1} \
   CONFIG.HAS_BURST {1} \
   CONFIG.HAS_CACHE {1} \
   CONFIG.HAS_LOCK {1} \
   CONFIG.HAS_PROT {1} \
   CONFIG.HAS_QOS {1} \
   CONFIG.HAS_REGION {1} \
   CONFIG.HAS_RRESP {1} \
   CONFIG.HAS_WSTRB {1} \
   CONFIG.ID_WIDTH {2} \
   CONFIG.MAX_BURST_LENGTH {1} \
   CONFIG.NUM_READ_OUTSTANDING {1} \
   CONFIG.NUM_READ_THREADS {1} \
   CONFIG.NUM_WRITE_OUTSTANDING {1} \
   CONFIG.NUM_WRITE_THREADS {1} \
   CONFIG.PROTOCOL {AXI4} \
   CONFIG.READ_WRITE_MODE {READ_WRITE} \
   CONFIG.RUSER_BITS_PER_BYTE {0} \
   CONFIG.RUSER_WIDTH {0} \
   CONFIG.SUPPORTS_NARROW_BURST {0} \
   CONFIG.WUSER_BITS_PER_BYTE {0} \
   CONFIG.WUSER_WIDTH {0} \
   ] $s_axi_pcie

  # RP-boundary streams (single-CMAC): 2 slaves in (rph2c, ethrx0) + 2 masters out (rpout0, rpout1)
  foreach rp_m {m_axis_rpout0 m_axis_rpout1} {
    set p [ create_bd_intf_port -mode Master -vlnv xilinx.com:interface:axis_rtl:1.0 $rp_m ]
    set_property -dict [ list CONFIG.FREQ_HZ {200000000} ] $p
  }
  foreach rp_s {s_axis_rph2c s_axis_ethrx0} {
    set p [ create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:axis_rtl:1.0 $rp_s ]
    set_property -dict [ list \
     CONFIG.FREQ_HZ {200000000} \
     CONFIG.HAS_TKEEP {1} \
     CONFIG.HAS_TLAST {1} \
     CONFIG.HAS_TREADY {1} \
     CONFIG.HAS_TSTRB {1} \
     CONFIG.LAYERED_METADATA {undef} \
     CONFIG.TDATA_NUM_BYTES {64} \
     CONFIG.TDEST_WIDTH {16} \
     CONFIG.TID_WIDTH {16} \
     CONFIG.TUSER_WIDTH {32} \
     ] $p
  }

  set s_axil [ create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 s_axil ]
  set_property -dict [ list \
   CONFIG.ADDR_WIDTH {32} \
   CONFIG.ARUSER_WIDTH {0} \
   CONFIG.AWUSER_WIDTH {0} \
   CONFIG.BUSER_WIDTH {0} \
   CONFIG.DATA_WIDTH {32} \
   CONFIG.FREQ_HZ {200000000} \
   CONFIG.HAS_BRESP {1} \
   CONFIG.HAS_BURST {0} \
   CONFIG.HAS_CACHE {0} \
   CONFIG.HAS_LOCK {0} \
   CONFIG.HAS_PROT {1} \
   CONFIG.HAS_QOS {0} \
   CONFIG.HAS_REGION {0} \
   CONFIG.HAS_RRESP {1} \
   CONFIG.HAS_WSTRB {1} \
   CONFIG.ID_WIDTH {0} \
   CONFIG.MAX_BURST_LENGTH {1} \
   CONFIG.NUM_READ_OUTSTANDING {1} \
   CONFIG.NUM_READ_THREADS {1} \
   CONFIG.NUM_WRITE_OUTSTANDING {1} \
   CONFIG.NUM_WRITE_THREADS {1} \
   CONFIG.PROTOCOL {AXI4LITE} \
   CONFIG.READ_WRITE_MODE {READ_WRITE} \
   CONFIG.RUSER_BITS_PER_BYTE {0} \
   CONFIG.RUSER_WIDTH {0} \
   CONFIG.SUPPORTS_NARROW_BURST {0} \
   CONFIG.WUSER_BITS_PER_BYTE {0} \
   CONFIG.WUSER_WIDTH {0} \
   ] $s_axil

  set S_BSCAN [ create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:bscan_rtl:1.0 S_BSCAN ]


  # Create ports
  set CLK [ create_bd_port -dir I -type clk -freq_hz 200000000 CLK ]
  set_property -dict [ list \
   CONFIG.ASSOCIATED_BUSIF {s_axil:s_axi_dma:m_axibr:s_axi_pcie:m_axis_rpout0:m_axis_rpout1:s_axis_rph2c:s_axis_ethrx0} \
   CONFIG.ASSOCIATED_RESET {RST_N} \
 ] $CLK
  set RST_N [ create_bd_port -dir I -type rst RST_N ]
  set free_100m_clk [ create_bd_port -dir I -type clk -freq_hz 100000000 free_100m_clk ]

  # ---- Boundary guard register slices (the cells floorplan.xdc pins) ----

  # AXI-MM slave guards on s_axi_dma / s_axi_pcie. The boundary signal set MUST
  # match rp_blk.v exactly (it is the fixed RP contract): SIZE present, REGION
  # absent -- same as the reference design's direct-to-smartconnect connection.
  # Hence SUPPORTS_NARROW_BURST 1 (keep ar/awsize) and HAS_REGION 0 (no ar/awregion).
  foreach mm_rs {axi_regsl_dma axi_regsl_pcie} {
    set rs [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_register_slice:2.1 $mm_rs ]
    set_property -dict [list \
      CONFIG.ADDR_WIDTH {64} \
      CONFIG.DATA_WIDTH {512} \
      CONFIG.HAS_BRESP {1} \
      CONFIG.HAS_BURST {1} \
      CONFIG.HAS_CACHE {1} \
      CONFIG.HAS_LOCK {1} \
      CONFIG.HAS_PROT {1} \
      CONFIG.HAS_QOS {1} \
      CONFIG.HAS_REGION {0} \
      CONFIG.HAS_RRESP {1} \
      CONFIG.HAS_WSTRB {1} \
      CONFIG.ID_WIDTH {2} \
      CONFIG.MAX_BURST_LENGTH {256} \
      CONFIG.PROTOCOL {AXI4} \
      CONFIG.READ_WRITE_MODE {READ_WRITE} \
      CONFIG.SUPPORTS_NARROW_BURST {1} \
    ] $rs
  }

  # Create instance: axi_regsl_pcibr (m_axibr boundary guard), and set properties
  set axi_regsl_pcibr [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_register_slice:2.1 axi_regsl_pcibr ]
  set_property -dict [list \
    CONFIG.ADDR_WIDTH {64} \
    CONFIG.ARUSER_WIDTH {0} \
    CONFIG.AWUSER_WIDTH {0} \
    CONFIG.BUSER_WIDTH {0} \
    CONFIG.DATA_WIDTH {512} \
    CONFIG.HAS_BRESP {1} \
    CONFIG.HAS_BURST {1} \
    CONFIG.HAS_CACHE {0} \
    CONFIG.HAS_LOCK {0} \
    CONFIG.HAS_PROT {0} \
    CONFIG.HAS_QOS {0} \
    CONFIG.HAS_REGION {0} \
    CONFIG.HAS_RRESP {1} \
    CONFIG.HAS_WSTRB {1} \
    CONFIG.ID_WIDTH {4} \
    CONFIG.MAX_BURST_LENGTH {256} \
    CONFIG.NUM_READ_OUTSTANDING {64} \
    CONFIG.NUM_READ_THREADS {3} \
    CONFIG.NUM_WRITE_OUTSTANDING {64} \
    CONFIG.NUM_WRITE_THREADS {3} \
    CONFIG.PROTOCOL {AXI4} \
    CONFIG.READ_WRITE_MODE {READ_WRITE} \
    CONFIG.RUSER_BITS_PER_BYTE {0} \
    CONFIG.RUSER_WIDTH {0} \
    CONFIG.SUPPORTS_NARROW_BURST {1} \
    CONFIG.WUSER_BITS_PER_BYTE {0} \
    CONFIG.WUSER_WIDTH {0} \
  ] $axi_regsl_pcibr


  # Create instance: axil_regsl (s_axil boundary guard), and set properties
  set axil_regsl [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_register_slice:2.1 axil_regsl ]
  set_property -dict [list \
    CONFIG.ADDR_WIDTH {32} \
    CONFIG.DATA_WIDTH {32} \
    CONFIG.HAS_BRESP {1} \
    CONFIG.HAS_BURST {0} \
    CONFIG.HAS_CACHE {0} \
    CONFIG.HAS_LOCK {0} \
    CONFIG.HAS_PROT {0} \
    CONFIG.HAS_QOS {0} \
    CONFIG.HAS_REGION {0} \
    CONFIG.HAS_RRESP {1} \
    CONFIG.HAS_WSTRB {0} \
    CONFIG.MAX_BURST_LENGTH {1} \
    CONFIG.NUM_READ_OUTSTANDING {0} \
    CONFIG.NUM_READ_THREADS {1} \
    CONFIG.NUM_WRITE_OUTSTANDING {0} \
    CONFIG.NUM_WRITE_THREADS {1} \
    CONFIG.PROTOCOL {AXI4LITE} \
    CONFIG.READ_WRITE_MODE {READ_WRITE} \
    CONFIG.RUSER_BITS_PER_BYTE {0} \
    CONFIG.SUPPORTS_NARROW_BURST {0} \
    CONFIG.WUSER_BITS_PER_BYTE {0} \
  ] $axil_regsl

  # AXIS boundary guards (full reg, REG_CONFIG 8) -- 2 in (rph2c, ethrx0) + 2 out.
  foreach rp_rs {axis_regsl_rph2c axis_regsl_ethrx0 axis_regsl_rpout0 axis_regsl_rpout1} {
    set rs [ create_bd_cell -type ip -vlnv xilinx.com:ip:axis_register_slice:1.1 $rp_rs ]
    set_property -dict [list \
      CONFIG.HAS_TKEEP {1} \
      CONFIG.HAS_TLAST {1} \
      CONFIG.HAS_TREADY {1} \
      CONFIG.HAS_TSTRB {1} \
      CONFIG.REG_CONFIG {8} \
      CONFIG.TDATA_NUM_BYTES {64} \
      CONFIG.TDEST_WIDTH {16} \
      CONFIG.TID_WIDTH {16} \
      CONFIG.TUSER_WIDTH {32} \
    ] $rs
  }

  # AXI-Lite pipeline on the packet-router config path (smartconnect M02 ->
  # AxisPacketRouterDual/s_axil). au50 is single-SLR, so a LIGHT register (default
  # REG, like axil_regsl) is enough -- no multi-SLR (REG=15) mode. The pktrouter is
  # also floorplanned near the AXI region (see floorplan.xdc) to keep this short.
  set pktrte_regsl_axil [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_register_slice:2.1 pktrte_regsl_axil ]
  set_property -dict [list \
    CONFIG.ADDR_WIDTH {32} \
    CONFIG.DATA_WIDTH {32} \
    CONFIG.PROTOCOL {AXI4LITE} \
    CONFIG.READ_WRITE_MODE {READ_WRITE} \
  ] $pktrte_regsl_axil


  # ---- Loopback datapath cells (unchanged from the board reference) ----

  # Create instance: axi_bram_ctrl_0, and set properties
  set axi_bram_ctrl_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 axi_bram_ctrl_0 ]
  set_property -dict [list \
    CONFIG.DATA_WIDTH {512} \
    CONFIG.READ_LATENCY {2} \
    CONFIG.SINGLE_PORT_BRAM {1} \
  ] $axi_bram_ctrl_0


  # Create instance: aximm_sc_i, and set properties
  set aximm_sc_i [ create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 aximm_sc_i ]
  set_property -dict [list \
    CONFIG.NUM_MI {3} \
    CONFIG.NUM_SI {2} \
  ] $aximm_sc_i


  # Create instance: axi_gpio_0, and set properties
  set axi_gpio_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_0 ]
  set_property CONFIG.C_ALL_OUTPUTS {1} $axi_gpio_0


  # Create instance: blk_mem_gen_0, and set properties
  set blk_mem_gen_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:blk_mem_gen:8.4 blk_mem_gen_0 ]
  set_property -dict [list \
    CONFIG.PRIM_type_to_Implement {URAM} \
    CONFIG.READ_LATENCY_A {2} \
  ] $blk_mem_gen_0


  # Create instance: axis_fifo_user_lb, and set properties
  set axis_fifo_user_lb [ create_bd_cell -type ip -vlnv xilinx.com:ip:axis_data_fifo:2.0 axis_fifo_user_lb ]
  set_property -dict [list \
    CONFIG.FIFO_DEPTH {1024} \
    CONFIG.FIFO_MODE {2} \
  ] $axis_fifo_user_lb


  # Create instance: vio_0, and set properties
  set vio_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:vio:3.0 vio_0 ]
  set_property CONFIG.C_NUM_PROBE_IN {2} $vio_0


  # Create instance: AxisPacketRouterDual_0, and set properties
  set AxisPacketRouterDual_0 [ create_bd_cell -type ip -vlnv nus.edu.sg:bsv:AxisPacketRouterDual:1.0 AxisPacketRouterDual_0 ]

  # Create instance: rp_in_sw, 2->1 merge of the RP input streams (rph2c, ethrx0)
  set rp_in_sw [ create_bd_cell -type ip -vlnv xilinx.com:ip:axis_switch:1.1 rp_in_sw ]
  set_property -dict [list \
    CONFIG.ARB_ON_MAX_XFERS {0} \
    CONFIG.ARB_ON_TLAST {1} \
    CONFIG.HAS_TKEEP {1} \
    CONFIG.HAS_TLAST {1} \
    CONFIG.HAS_TSTRB {1} \
    CONFIG.M00_AXIS_BASETDEST {0x00000000} \
    CONFIG.M00_AXIS_HIGHTDEST {0x0000ffff} \
    CONFIG.NUM_MI {1} \
    CONFIG.NUM_SI {2} \
    CONFIG.TDATA_NUM_BYTES {64} \
    CONFIG.TDEST_WIDTH {16} \
    CONFIG.TID_WIDTH {16} \
    CONFIG.TUSER_WIDTH {32} \
  ] $rp_in_sw

  # Create interface connections
  # RP inputs: ports -> axis_regsl_* (boundary guard) -> rp_in_sw -> fifo -> dual router -> rpout guards -> ports
  connect_bd_intf_net -intf_net s_axis_rph2c_1  [get_bd_intf_ports s_axis_rph2c]  [get_bd_intf_pins axis_regsl_rph2c/S_AXIS]
  connect_bd_intf_net -intf_net s_axis_ethrx0_1 [get_bd_intf_ports s_axis_ethrx0] [get_bd_intf_pins axis_regsl_ethrx0/S_AXIS]
  connect_bd_intf_net -intf_net axis_regsl_rph2c_M  [get_bd_intf_pins axis_regsl_rph2c/M_AXIS]  [get_bd_intf_pins rp_in_sw/S00_AXIS]
  connect_bd_intf_net -intf_net axis_regsl_ethrx0_M [get_bd_intf_pins axis_regsl_ethrx0/M_AXIS] [get_bd_intf_pins rp_in_sw/S01_AXIS]
  connect_bd_intf_net -intf_net rp_in_sw_M00_AXIS [get_bd_intf_pins rp_in_sw/M00_AXIS] [get_bd_intf_pins axis_fifo_user_lb/S_AXIS]
  connect_bd_intf_net -intf_net axis_fifo_user_lb_M_AXIS [get_bd_intf_pins axis_fifo_user_lb/M_AXIS] [get_bd_intf_pins AxisPacketRouterDual_0/s_axis]
  connect_bd_intf_net -intf_net AxisPacketRouterDual_0_m_axis_0 [get_bd_intf_pins AxisPacketRouterDual_0/m_axis_0] [get_bd_intf_pins axis_regsl_rpout0/S_AXIS]
  connect_bd_intf_net -intf_net AxisPacketRouterDual_0_m_axis_1 [get_bd_intf_pins AxisPacketRouterDual_0/m_axis_1] [get_bd_intf_pins axis_regsl_rpout1/S_AXIS]
  connect_bd_intf_net -intf_net axis_regsl_rpout0_M [get_bd_intf_ports m_axis_rpout0] [get_bd_intf_pins axis_regsl_rpout0/M_AXIS]
  connect_bd_intf_net -intf_net axis_regsl_rpout1_M [get_bd_intf_ports m_axis_rpout1] [get_bd_intf_pins axis_regsl_rpout1/M_AXIS]
  # AXI-MM: s_axi_dma/s_axi_pcie -> boundary guard -> smartconnect
  connect_bd_intf_net -intf_net s_axi_dma_1  [get_bd_intf_ports s_axi_dma]  [get_bd_intf_pins axi_regsl_dma/S_AXI]
  connect_bd_intf_net -intf_net s_axi_pcie_1 [get_bd_intf_ports s_axi_pcie] [get_bd_intf_pins axi_regsl_pcie/S_AXI]
  connect_bd_intf_net -intf_net axi_regsl_dma_M  [get_bd_intf_pins axi_regsl_dma/M_AXI]  [get_bd_intf_pins aximm_sc_i/S00_AXI]
  connect_bd_intf_net -intf_net axi_regsl_pcie_M [get_bd_intf_pins axi_regsl_pcie/M_AXI] [get_bd_intf_pins aximm_sc_i/S01_AXI]
  connect_bd_intf_net -intf_net aximm_sc_i_M02_AXI [get_bd_intf_pins aximm_sc_i/M02_AXI] [get_bd_intf_pins pktrte_regsl_axil/S_AXI]
  connect_bd_intf_net -intf_net pktrte_regsl_axil_M_AXI [get_bd_intf_pins pktrte_regsl_axil/M_AXI] [get_bd_intf_pins AxisPacketRouterDual_0/s_axil]
  connect_bd_intf_net -intf_net axi_bram_ctrl_0_BRAM_PORTA [get_bd_intf_pins axi_bram_ctrl_0/BRAM_PORTA] [get_bd_intf_pins blk_mem_gen_0/BRAM_PORTA]
  connect_bd_intf_net -intf_net axi_regsl_pcibr_M_AXI [get_bd_intf_ports m_axibr] [get_bd_intf_pins axi_regsl_pcibr/M_AXI]
  connect_bd_intf_net -intf_net axil_regsl_M_AXI [get_bd_intf_pins axil_regsl/M_AXI] [get_bd_intf_pins axi_gpio_0/S_AXI]
  connect_bd_intf_net -intf_net s_axil_1 [get_bd_intf_ports s_axil] [get_bd_intf_pins axil_regsl/S_AXI]
  connect_bd_intf_net -intf_net smartconnect_0_M00_AXI [get_bd_intf_pins aximm_sc_i/M00_AXI] [get_bd_intf_pins axi_bram_ctrl_0/S_AXI]
  connect_bd_intf_net -intf_net user_blk_m_axibr [get_bd_intf_pins aximm_sc_i/M01_AXI] [get_bd_intf_pins axi_regsl_pcibr/S_AXI]

  # Create port connections (clk/rst fan-out incl. all boundary guard slices)
  connect_bd_net -net CLK_1 [get_bd_ports CLK] \
    [get_bd_pins axi_regsl_dma/aclk] [get_bd_pins axi_regsl_pcie/aclk] \
    [get_bd_pins axi_regsl_pcibr/aclk] [get_bd_pins axil_regsl/aclk] \
    [get_bd_pins axis_regsl_rph2c/aclk] [get_bd_pins axis_regsl_ethrx0/aclk] \
    [get_bd_pins axis_regsl_rpout0/aclk] [get_bd_pins axis_regsl_rpout1/aclk] \
    [get_bd_pins pktrte_regsl_axil/aclk] \
    [get_bd_pins axis_fifo_user_lb/s_axis_aclk] [get_bd_pins axi_gpio_0/s_axi_aclk] \
    [get_bd_pins aximm_sc_i/aclk] [get_bd_pins axi_bram_ctrl_0/s_axi_aclk] \
    [get_bd_pins vio_0/clk] [get_bd_pins rp_in_sw/aclk] [get_bd_pins AxisPacketRouterDual_0/CLK]
  connect_bd_net -net RST_N_1 [get_bd_ports RST_N] \
    [get_bd_pins axi_regsl_dma/aresetn] [get_bd_pins axi_regsl_pcie/aresetn] \
    [get_bd_pins axi_regsl_pcibr/aresetn] [get_bd_pins axil_regsl/aresetn] \
    [get_bd_pins axis_regsl_rph2c/aresetn] [get_bd_pins axis_regsl_ethrx0/aresetn] \
    [get_bd_pins axis_regsl_rpout0/aresetn] [get_bd_pins axis_regsl_rpout1/aresetn] \
    [get_bd_pins pktrte_regsl_axil/aresetn] \
    [get_bd_pins axis_fifo_user_lb/s_axis_aresetn] [get_bd_pins axi_gpio_0/s_axi_aresetn] \
    [get_bd_pins aximm_sc_i/aresetn] [get_bd_pins axi_bram_ctrl_0/s_axi_aresetn] \
    [get_bd_pins rp_in_sw/aresetn] [get_bd_pins AxisPacketRouterDual_0/RST_N]
  connect_bd_net -net axi_gpio_0_gpio_io_o [get_bd_pins axi_gpio_0/gpio_io_o] [get_bd_pins vio_0/probe_in0]
  connect_bd_net -net vio_0_probe_out0 [get_bd_pins vio_0/probe_out0] [get_bd_pins vio_0/probe_in1]

  # Create address segments
  assign_bd_address -offset 0x08200000 -range 0x00001000 -target_address_space [get_bd_addr_spaces s_axi_dma] [get_bd_addr_segs AxisPacketRouterDual_0/s_axil/reg0] -force
  assign_bd_address -offset 0x08000000 -range 0x00200000 -target_address_space [get_bd_addr_spaces s_axi_dma] [get_bd_addr_segs axi_bram_ctrl_0/S_AXI/Mem0] -force
  assign_bd_address -offset 0x00000000 -range 0x08000000 -target_address_space [get_bd_addr_spaces s_axi_dma] [get_bd_addr_segs m_axibr/Reg] -force
  assign_bd_address -offset 0x08200000 -range 0x00001000 -target_address_space [get_bd_addr_spaces s_axi_pcie] [get_bd_addr_segs AxisPacketRouterDual_0/s_axil/reg0] -force
  assign_bd_address -offset 0x08000000 -range 0x00200000 -target_address_space [get_bd_addr_spaces s_axi_pcie] [get_bd_addr_segs axi_bram_ctrl_0/S_AXI/Mem0] -force
  assign_bd_address -offset 0x00000000 -range 0x08000000 -target_address_space [get_bd_addr_spaces s_axi_pcie] [get_bd_addr_segs m_axibr/Reg] -force
  assign_bd_address -offset 0x00000000 -range 0x00080000 -target_address_space [get_bd_addr_spaces s_axil] [get_bd_addr_segs axi_gpio_0/S_AXI/Reg] -force


  # Restore current instance
  current_bd_instance $oldCurInst

  validate_bd_design
  save_bd_design
  close_bd_design $design_name
}
# End of cr_bd_rp_user()

cr_bd_rp_user ""
