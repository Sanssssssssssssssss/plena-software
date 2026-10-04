#------------------------------
# Parameterized Elaborate Script
# Usage: dc_shell -f elaborate.tcl
# Environment variables:
#   SYNTH_MODULE    - Module name to elaborate (required)
#   SYNTH_BUILD_DIR - Output directory (required)
#------------------------------

set WORK_DIR "./"

if {[info exists env(SYNTH_MODULE)]} {
    set MODULE $env(SYNTH_MODULE)
} else {
    puts "ERROR: SYNTH_MODULE not defined"
    exit 1
}

if {[info exists env(SYNTH_BUILD_DIR)]} {
    set BUILD_DIR $env(SYNTH_BUILD_DIR)
} else {
    puts "ERROR: SYNTH_BUILD_DIR not defined"
    exit 1
}

if {[info exists env(SYNTH_MAX_CORES)]} {
    set MAX_CORES $env(SYNTH_MAX_CORES)
} else {
    set MAX_CORES 1
}
if {$MAX_CORES > 16} {
    puts "SYNTH_MAX_CORES=$MAX_CORES exceeds DC limit; clamping to 16"
    set MAX_CORES 16
}
if {$MAX_CORES < 1} {
    puts "SYNTH_MAX_CORES=$MAX_CORES is invalid; clamping to 1"
    set MAX_CORES 1
}
puts "  Max Cores:    $MAX_CORES"
set_host_options -max_cores $MAX_CORES

set top_design $MODULE
set src ${WORK_DIR}/../../src
set log_dir ${BUILD_DIR}/logs
set rpt_dir ${BUILD_DIR}/reports
set net_dir ${BUILD_DIR}/netlist
set out_dir ${BUILD_DIR}/out

file mkdir ${log_dir}
file mkdir ${rpt_dir}
file mkdir ${net_dir}
file mkdir ${out_dir}

set_message_info -id ELAB-405 -limit 10
lappend search_path ${src}

puts "=========================================="
puts "Elaborate Configuration"
puts "  Module:    $MODULE"
puts "  Build Dir: $BUILD_DIR"
puts "=========================================="

puts "\n>>> Reading and elaborating RTL files..."
source ${WORK_DIR}/read_rtl.tcl

puts "\n>>> Pre-link design check..."
check_design > ${log_dir}/${MODULE}_check.log

puts "\n>>> Linking design..."
current_design ${MODULE}
if {![link]} {
    puts "ERROR: link failed for ${MODULE}; unresolved references or port mismatches remain."
    exit 1
}
uniquify

puts "\n>>> Saving elaborated design..."
write_file -f ddc     -hierarchy -output ${out_dir}/${MODULE}_elab.ddc
write_file -f verilog -hierarchy -output ${net_dir}/${MODULE}_elab.v

puts "\n>>> Generating elaborate reports..."
report_units > ${rpt_dir}/${MODULE}_units.rpt
report_reference > ${rpt_dir}/${MODULE}_reference.rpt
report_area > ${rpt_dir}/${MODULE}_generic_area.rpt

set FULL_REPORTS 0
if {[info exists env(ELABORATE_FULL_REPORTS)] && $env(ELABORATE_FULL_REPORTS) == "1"} {
    set FULL_REPORTS 1
}

if {$FULL_REPORTS} {
    report_area -hierarchy > ${rpt_dir}/${MODULE}_generic_area_hier.rpt
    if {[catch {report_resources -hierarchy > ${rpt_dir}/${MODULE}_resources.rpt} err]} {
        set fp [open ${rpt_dir}/${MODULE}_resources.rpt w]
        puts $fp "report_resources unavailable: $err"
        close $fp
    }
    report_design > ${rpt_dir}/${MODULE}_design.rpt
    report_port > ${rpt_dir}/${MODULE}_port.rpt
} else {
    set fp [open ${rpt_dir}/${MODULE}_resources.rpt w]
    puts $fp "Skipped by default; set ELABORATE_FULL_REPORTS=1 for hierarchical resources."
    close $fp
    set fp [open ${rpt_dir}/${MODULE}_design.rpt w]
    puts $fp "Skipped by default; set ELABORATE_FULL_REPORTS=1 for design report."
    close $fp
    set fp [open ${rpt_dir}/${MODULE}_port.rpt w]
    puts $fp "Skipped by default; set ELABORATE_FULL_REPORTS=1 for port report."
    close $fp
}

puts "\n>>> Elaborate complete."
exit 0
