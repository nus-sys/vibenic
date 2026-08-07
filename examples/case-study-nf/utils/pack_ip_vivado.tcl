# =============================================================================
# Package the BSV UDP Vector-Averaging NF (mkVectorAvgNF) as a Vivado IP.
# Adapted from mds-fpga/kvs_cuckoo/utils/pack_ip_vivado.tcl.
#
#   in : ./verilog/*.v   (bsc output)   ./lib/*.{v,sv}  (BVI + bsc primitives)
#   out: ./build/vivado_ip/component.xml  (VLNV nus.edu.sg:bsv:mkVectorAvgNF:1.0)
#
# setBusParams tags each interface so the block design auto-recognises them as
# AXI bus interfaces (not raw wires).  Interface leaf names follow the bsc
# convention <ifc>_<sig>; Phase 4 reconciles against the actual emitted names.
# =============================================================================
set vprj    ippack_prj
set ex_part xcu50-fsvh2104-2-e

set ip_name mkVectorAvgNF
set ip_vend nus.edu.sg
set ip_lib  bsv
set ip_ver  1.0
set ip_path ./build/vivado_ip
set syn_top mkVectorAvgNF

create_project -force $vprj ./build/$vprj -part $ex_part

# bsc module Verilog (top + submodules); exclude Sim* testbench tops.
set rtl_v [list]
foreach f [glob ./verilog/*.v] {
  if { [string match "*mkSim*" $f] } { continue }
  lappend rtl_v $f
}
add_files -norecurse $rtl_v
# CachedCuckoo BVI + cuckoo SV closure + bsc primitive Verilog (FIFO/BRAM/...).
add_files -norecurse [glob ./lib/*.v]
add_files -norecurse [glob ./lib/*.sv]

update_compile_order -fileset sources_1
set_property source_mgmt_mode None [current_project]
set_property top $syn_top [current_fileset]
set_property source_mgmt_mode All [current_project]
update_compile_order -fileset sources_1

# Trial synthesis (catches inference / black-box issues before packaging).
launch_runs synth_1 -jobs 16
wait_on_run synth_1

ipx::package_project -root_dir $ip_path \
    -vendor $ip_vend -library $ip_lib -taxonomy /UserIP -version $ip_ver \
    -name $ip_name -force -import_files -set_current true
set ip_vlnv $ip_vend:$ip_lib:$ip_name:$ip_ver
set ip_core [ipx::find_open_core $ip_vlnv]

set_property display_name $ip_name $ip_core
set_property core_revision 1 $ip_core
set_property auto_family_support_level level_1 $ip_core

proc setBusParams {bus_name params_dict} {
    global ip_core
    set bus [ipx::get_bus_interfaces $bus_name -of_objects $ip_core]
    foreach {k v} $params_dict {
        ipx::add_bus_parameter $k $bus
        set_property value $v [ipx::get_bus_parameters $k -of_objects $bus]
    }
}

# --- 3 HBM read masters: 512 b @ user clk, 33-bit channel-local address ---
foreach hb {hbm_axi_0 hbm_axi_1 hbm_axi_2} {
    setBusParams $hb {
        PROTOCOL                AXI4
        DATA_WIDTH              512
        ADDR_WIDTH              33
        MAX_BURST_LENGTH        8
        NUM_READ_THREADS        1
        NUM_WRITE_THREADS       1
        SUPPORTS_NARROW_BURST   0
        NUM_READ_OUTSTANDING    32
        NUM_WRITE_OUTSTANDING   1
    }
}

# --- Notification master: AXI4-MM to host PCIe (64-bit address) ---
setBusParams m_axibr {
    PROTOCOL                AXI4
    DATA_WIDTH              512
    ADDR_WIDTH              64
    MAX_BURST_LENGTH        1
    NUM_READ_THREADS        1
    NUM_WRITE_THREADS       1
    SUPPORTS_NARROW_BURST   0
    NUM_READ_OUTSTANDING    1
    NUM_WRITE_OUTSTANDING   4
}

# --- Host MMIO: AXI4-Lite slave ---
setBusParams s_axil {
    PROTOCOL                AXI4LITE
    DATA_WIDTH              32
    ADDR_WIDTH              32
    NUM_READ_OUTSTANDING    1
    NUM_WRITE_OUTSTANDING   1
}

ipx::create_xgui_files $ip_core
ipx::update_checksums $ip_core
ipx::check_integrity $ip_core
ipx::save_core $ip_core
ipx::unload_core $ip_path/component.xml

exit
