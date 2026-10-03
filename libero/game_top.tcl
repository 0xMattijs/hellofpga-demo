# Add hdl/src/game_top.v to the reference design. Sourced by build.tcl with
# the converted project open; expects $repo_dir and $build_dir.
#
#   camera pins ──► GAME_0 ──► line_write_read_0     (re-timed, game drawn in)
#   FIC_0 APB   ──► GAME_0 at 0x30001000; apb3_if_0 keeps the rest
#   GAME_0 UART ──► TX pin (to the PIC32, then USB); CoreUART never sends
#   RX pin      ──► GAME_0 too: to tell when the PC listens
#   SW1-SW3     ──► GAME_0 (new pins K1, J2, L1; the reference leaves them unused)
#
# No interrupt line: the MSS fabric interrupts and GPIO_0 are inside the
# FlashFreeze_SB System Builder block, and regenerating it needs FCCC
# 2.0.201, which Libero 2026.1's vault lacks. Firmware polls instead.

# Libero's errors don't say which pin a SmartDesign command choked on.
proc checked {args} {
    if {[catch {uplevel 1 $args} msg]} {
        error "game_top.tcl: failed: $args\n$msg"
    }
}

set hdl_dir [file join $repo_dir hdl src]
foreach f {cam_bus.v color_track.v game_overlay.v uart_tx.v uart_rx.v game_top.v} {
    import_files -hdl_source [file join $hdl_dir $f]
}
build_design_hierarchy

set sd TOP
open_smartdesign -sd_name $sd
checked sd_instantiate_hdl_module -sd_name $sd -hdl_module_name {game_top} \
    -hdl_file {hdl/game_top.v} -instance_name {GAME_0}

checked sd_connect_pins -sd_name $sd -pin_names {FlashFreeze_SB_0:GL0 GAME_0:clk}
checked sd_connect_pins -sd_name $sd -pin_names {MX2_0:Y GAME_0:rst_n}

# Camera: pins -> GAME_0 -> line_write_read_0
foreach {port game_in game_out lwr_pin} {
    PCLK_I   cam_pclk_i  lcd_pclk_o  PCLK_I
    H_REF_I  cam_href_i  lcd_href_o  H_REF_I
    V_SYNC_I cam_vsync_i lcd_vsync_o V_SYNC_I
    DATA_I   cam_data_i  lcd_data_o  DATA_I
} {
    checked sd_disconnect_pins -sd_name $sd -pin_names "line_write_read_0:$lwr_pin"
    checked sd_connect_pins -sd_name $sd -pin_names "$port GAME_0:$game_in"
    checked sd_connect_pins -sd_name $sd -pin_names "GAME_0:$game_out line_write_read_0:$lwr_pin"
}

# APB: GAME_0 listens to the whole bus and gates apb3_if_0's PSEL. The
# reference joins master and apb3_if_0 with one bus-interface (BIF) net, which
# can't be split, so replace it with plain nets. apb3_if_0's BIF has no
# PRDATA, which is why the master's PRDATA was tied to 0.
checked sd_delete_nets -sd_name $sd -net_names {FlashFreeze_SB_0_FIC_0_APB_MASTER}
set m FlashFreeze_SB_0:FIC_0_APB_M_
foreach sig {PSEL PENABLE PWRITE PADDR PWDATA PRDATA PREADY PSLVERR} {
    checked sd_show_bif_pins -sd_name $sd -bif_pin_name {FlashFreeze_SB_0:FIC_0_APB_MASTER} \
        -pin_names "$m$sig"
}
foreach pin {psel_i penable_i pwrite_i paddr_i pwdata_i pready_o pslverr_o} {
    checked sd_show_bif_pins -sd_name $sd -bif_pin_name {apb3_if_0:BIF_1} \
        -pin_names "apb3_if_0:$pin"
}
checked sd_connect_pins -sd_name $sd -pin_names "${m}PSEL GAME_0:psel_i"
checked sd_connect_pins -sd_name $sd -pin_names {GAME_0:lcd_psel_o apb3_if_0:psel_i}
foreach {sig pin} {PENABLE penable_i PWRITE pwrite_i PADDR paddr_i PWDATA pwdata_i} {
    checked sd_connect_pins -sd_name $sd -pin_names "$m$sig apb3_if_0:$pin GAME_0:$pin"
}
# Both targets are always ready and never fail, so apb3_if_0 answers for both.
checked sd_connect_pins -sd_name $sd -pin_names "${m}PREADY apb3_if_0:pready_o"
checked sd_connect_pins -sd_name $sd -pin_names "${m}PSLVERR apb3_if_0:pslverr_o"
catch {sd_clear_pin_attributes -sd_name $sd -pin_names "${m}PRDATA"}
checked sd_connect_pins -sd_name $sd -pin_names "GAME_0:prdata_o ${m}PRDATA"

# UART TX pin
checked sd_disconnect_pins -sd_name $sd -pin_names {UART_interface_0:TX}
checked sd_mark_pins_unused -sd_name $sd -pin_names {UART_interface_0:TX}
checked sd_connect_pins -sd_name $sd -pin_names {GAME_0:uart_tx_o TX}
checked sd_connect_pins -sd_name $sd -pin_names {RX GAME_0:uart_rx_i}

# Color constants: from GAME_0's COLOR_GAIN register instead of the
# reference GUI's UART receiver, whose values came up wrong after power-up
# (red gain low: white showed as cyan).
foreach {lwr game} {R_CONST_I red_const_o G_CONST_I green_const_o
                    B_CONST_I blue_const_o COMMON_CONST_I common_const_o} {
    checked sd_disconnect_pins -sd_name $sd -pin_names "line_write_read_0:$lwr"
    checked sd_connect_pins -sd_name $sd -pin_names "GAME_0:$game line_write_read_0:$lwr"
}
foreach pin {red_const_o green_const_o blue_const_o common_const_o} {
    checked sd_mark_pins_unused -sd_name $sd -pin_names "UART_interface_0:$pin"
}

# Push buttons: active low, pulled up to the 1.5 V bank 5 supply (kit
# schematic, sheet 6).
foreach {port pin pkg} {SW1_N sw1_n_i K1 SW2_N sw2_n_i J2 SW3_N sw3_n_i L1} {
    checked sd_create_scalar_port -sd_name $sd -port_name $port -port_direction {IN}
    checked sd_connect_pins -sd_name $sd -pin_names "$port GAME_0:$pin"
}

save_smartdesign -sd_name $sd
generate_component -component_name $sd
build_design_hierarchy
set_root -module {TOP::work}

# Pin constraints for the buttons, appended to the project's copy of the
# reference I/O constraints.
set pdc [open [file join $build_dir constraint io user.pdc] a]
foreach {port pkg} {SW1_N K1 SW2_N J2 SW3_N L1} {
    puts $pdc "\nset_io $port -pinname $pkg -fixed yes -iostd LVCMOS15 -DIRECTION INPUT"
}
close $pdc
