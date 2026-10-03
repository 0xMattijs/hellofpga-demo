# Build the Hello FPGA video reference design with this repo's fabric block
# (hdl/src/game_top.v, added by game_top.tcl) and export programming files.
#
# Usage (after sourcing ~/Microchip/setup-microchip-tools.sh):
#   libero SCRIPT:libero/build.tcl "SCRIPT_ARGS:<ref_project_dir> [<firmware_hex> [<build_dir>]]"
#
# <ref_project_dir>  Unpacked HF10_OV7725_LCD_FF project (Libero v12.7). It is
#                    copied, never modified.
# <firmware_hex>     Cortex-M3 image for eNVM, such as firmware/build/demo.hex.
#                    Default, or "-": keep the eNVM data stored in the project.
# <build_dir>        Where the converted project goes. Default: libero/build,
#                    which Git ignores. Wiped and recreated on every run.
#
# Output: <build_dir>/export/demo.dat (DirectC, for hellofpga-prog)
# and demo.stp (STAPL, for FlashPro). Both program fabric and eNVM.

set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file dirname $script_dir]

if {$argc < 1} {
    error "usage: libero SCRIPT:build.tcl \"SCRIPT_ARGS:<ref_project_dir> \[<firmware_hex> \[<build_dir>\]\]\""
}
set ref_dir [file normalize [lindex $argv 0]]
set firmware_hex -
if {$argc >= 2 && [lindex $argv 1] ne "-"} {
    set firmware_hex [file normalize [lindex $argv 1]]
    if {![file exists $firmware_hex]} {
        error "no firmware image at $firmware_hex"
    }
}
if {$argc >= 3} {
    set build_dir [file normalize [lindex $argv 2]]
} else {
    set build_dir [file join $script_dir build]
}

set prjx_name HF10_OV7725_LCD_FF.prjx
if {![file exists [file join $ref_dir $prjx_name]]} {
    error "no $prjx_name in $ref_dir"
}

# Only wipe a directory this script created, marked by .demo-build.
set marker [file join $build_dir .demo-build]
if {[file exists $build_dir]} {
    if {![file exists $marker]} {
        error "$build_dir exists but was not made by build.tcl; remove it yourself"
    }
    file delete -force $build_dir
}
file mkdir [file dirname $build_dir]
file copy $ref_dir $build_dir
close [open $marker w]

set export_dir [file join $build_dir export]
file mkdir $export_dir

# Opening a v12.7 project in a newer Libero converts it in place.
open_project -file [file join $build_dir $prjx_name] \
    -do_backup_on_convert 1 \
    -backup_file [file join $build_dir convert_backup.zip]

source [file join $script_dir game_top.tcl]

run_tool -name {SYNTHESIZE}
run_tool -name {PLACEROUTE}
run_tool -name {VERIFYTIMING}
run_tool -name {GENERATEPROGRAMMINGDATA}

# The project's eNVM client "hex" points at a Windows path
# (SC\hellofpga_lcd_cam_ff\Release\hellofpga_lcd_cam_ff.hex), so without a
# firmware image Libero keeps the eNVM data stored in the project.
if {$firmware_hex ne "-"} {
    # The client size is in bytes (8-bit words) and must cover the image's
    # whole address span, gaps included: find the end of the last data record.
    set n_bytes 0
    set upper 0
    set f [open $firmware_hex r]
    while {[gets $f line] >= 0} {
        set type [string range $line 7 8]
        if {$type eq "04"} {
            set upper [expr {[scan [string range $line 9 12] %x] << 16}]
        } elseif {$type eq "00"} {
            set end [expr {$upper + [scan [string range $line 3 6] %x] \
                           + [scan [string range $line 1 2] %x]}]
            if {$end > $n_bytes} { set n_bytes $end }
        }
    }
    close $f
    set cfg [file join $build_dir update_envm.cfg]
    set f [open $cfg w]
    puts $f "nvm_update_storage_client -client_name {hex} -number_of_words $n_bytes \\"
    puts $f "    -content_type {MEMORY_FILE} -memory_file_format {INTELHEX} \\"
    puts $f "    -memory_file {$firmware_hex} -base_address 0 -reprogram 1 -use_as_rom 0"
    close $f
    run_tool -name {UPDATE_ENVM} -script $cfg
    puts "build.tcl: eNVM client hex <- $firmware_hex ($n_bytes bytes)"
}

configure_tool -name {GENERATEPROGRAMMINGFILE} \
    -params {program_fabric:true} \
    -params {program_security:false} \
    -params {program_envm:true}
run_tool -name {GENERATEPROGRAMMINGFILE}

export_bitstream_file -file_name {demo} -export_dir $export_dir \
    -format {DAT STP} \
    -trusted_facility_file 1 \
    -trusted_facility_file_components {FABRIC ENVM}

save_project
close_project
puts "build.tcl: programming files in $export_dir"
