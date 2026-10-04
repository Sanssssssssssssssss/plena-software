# Project root directory
root := justfile_directory()

# Synopsys tools directory
synopsys_dir := root / "tools" / "synopsys"

# Build directory for synthesis outputs
build_dir := root / "build" / "synth"

# Source Synopsys environment
synopsys_env := "source /mnt/applications/synopsys/2024-25/scripts/SYN_2024.09-SP2_RHELx86.sh"

# Timestamp format for logs
timestamp := `date +%Y%m%d_%H%M%S`

alias ts := test-sw
alias th := test-hw
alias syn := synth

# =============================================================================
# Docker Commands
# =============================================================================
# Containerized dev environment (Ubuntu, no Nix). Covers RTL sim / lint / tests;
# Synopsys synthesis is host-only and not available in Docker.

docker_compose := "docker/docker-compose.yml"

# Build the dev image
docker-build:
    docker compose -f {{docker_compose}} build dev

# Build (if needed) and drop into an interactive shell
docker-dev:
    docker compose -f {{docker_compose}} run --rm dev bash

# Run an arbitrary command in the dev image, e.g. `just docker-run python3 --version`
docker-run *args:
    docker compose -f {{docker_compose}} run --rm dev {{args}}

# Run a just recipe in the dev image, e.g. `just docker-test rtl-sim linear`
docker-test *args:
    docker compose -f {{docker_compose}} run --rm dev just {{args}}

# Remove containers and persisted volumes (venv/ccache caches)
docker-clean:
    docker compose -f {{docker_compose}} down -v 2>/dev/null || true
    docker volume rm plena-rtl-venv plena-rtl-ccache 2>/dev/null || true

# =============================================================================
# Synthesis Commands
# =============================================================================

# Synthesize a module with Design Compiler
# Usage: just synth <module> [clk_period_ps] [compile_mode]
# Examples:
#   just synth fp_adder
#   just synth fp_adder 500
#   just synth fp_adder 500 ultra
#   just synth plena 1000 area
synth module clk_period="1000" mode="normal":
    #!/usr/bin/env bash
    set -euo pipefail

    # Clear Python environment to avoid conflicts with DC's internal Python
    unset PYTHONPATH
    unset PYTHONHOME
    unset VIRTUAL_ENV
    unset _PYTHON_SYSCONFIGDATA_NAME
    unset _PYTHON_HOST_PLATFORM
    unset PYTHONNOUSERSITE
    unset PYTHONHASHSEED

    # Remove Nix Python from PATH
    export PATH=$(echo "$PATH" | tr ':' '\n' | grep -v '/nix/store.*python' | tr '\n' ':' | sed 's/:$//')

    {{synopsys_env}}

    # Setup build directory structure
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BUILD_DIR="{{build_dir}}/{{module}}/${TIMESTAMP}"
    LATEST_LINK="{{build_dir}}/{{module}}/latest"

    mkdir -p "${BUILD_DIR}"/{logs,reports,netlist,out}

    # Create/update latest symlink
    rm -f "${LATEST_LINK}"
    ln -sf "${TIMESTAMP}" "${LATEST_LINK}"

    # Start logging
    MAIN_LOG="${BUILD_DIR}/logs/synth.log"
    exec > >(tee -a "${MAIN_LOG}") 2>&1

    echo "========================================"
    echo "SYNTHESIS LOG"
    echo "========================================"
    echo "Module:       {{module}}"
    echo "Clock Period: {{clk_period}} ps"
    echo "Compile Mode: {{mode}}"
    echo "Start Time:   $(date)"
    echo "Build Dir:    ${BUILD_DIR}"
    echo "========================================"
    echo ""

    # Export environment for TCL script
    export SYNTH_MODULE="{{module}}"
    export SYNTH_CLK_PERIOD="{{clk_period}}"
    export SYNTH_COMPILE_MODE="{{mode}}"
    export SYNTH_BUILD_DIR="${BUILD_DIR}"
    DEFAULT_SYNTH_MAX_CORES=$(nproc)
    if [ "${DEFAULT_SYNTH_MAX_CORES}" -gt 16 ]; then
        DEFAULT_SYNTH_MAX_CORES=16
    fi
    export SYNTH_MAX_CORES="${SYNTH_MAX_CORES:-${DEFAULT_SYNTH_MAX_CORES}}"

    cd "{{synopsys_dir}}"

    # Run DC synthesis
    dc_shell -f synth.tcl
    DC_EXIT=$?

    echo ""
    echo "========================================"
    echo "End Time: $(date)"

    if [ ${DC_EXIT} -eq 0 ]; then
        echo "Status: SUCCESS"
        echo "========================================"
        echo ""

        # Extract and summarize key metrics
        SUMMARY_LOG="${BUILD_DIR}/logs/summary.log"
        AREA_LOG="${BUILD_DIR}/logs/area.log"
        POWER_LOG="${BUILD_DIR}/logs/power.log"
        TIMING_LOG="${BUILD_DIR}/logs/timing.log"

        echo "=== SYNTHESIS SUMMARY ===" > "${SUMMARY_LOG}"
        echo "Module: {{module}}" >> "${SUMMARY_LOG}"
        echo "Clock Period: {{clk_period}} ps" >> "${SUMMARY_LOG}"
        echo "Compile Mode: {{mode}}" >> "${SUMMARY_LOG}"
        echo "Timestamp: ${TIMESTAMP}" >> "${SUMMARY_LOG}"
        echo "" >> "${SUMMARY_LOG}"

        # Extract area
        if [ -f "${BUILD_DIR}/reports/{{module}}_area.rpt" ]; then
            cp "${BUILD_DIR}/reports/{{module}}_area.rpt" "${AREA_LOG}"
            echo "=== AREA ===" >> "${SUMMARY_LOG}"
            grep -A5 "Total cell area" "${AREA_LOG}" >> "${SUMMARY_LOG}" 2>/dev/null || true
            echo "" >> "${SUMMARY_LOG}"
        fi

        # Extract power
        if [ -f "${BUILD_DIR}/reports/{{module}}_power.rpt" ]; then
            cp "${BUILD_DIR}/reports/{{module}}_power.rpt" "${POWER_LOG}"
            echo "=== POWER ===" >> "${SUMMARY_LOG}"
            grep -A10 "Total Dynamic Power" "${POWER_LOG}" >> "${SUMMARY_LOG}" 2>/dev/null || true
            grep "Total Power" "${POWER_LOG}" >> "${SUMMARY_LOG}" 2>/dev/null || true
            echo "" >> "${SUMMARY_LOG}"
        fi

        # Extract timing
        if [ "{{mode}}" != "area" ] && [ -f "${BUILD_DIR}/reports/{{module}}_timing.rpt" ]; then
            cp "${BUILD_DIR}/reports/{{module}}_timing.rpt" "${TIMING_LOG}"
            echo "=== TIMING ===" >> "${SUMMARY_LOG}"
            grep -A5 "slack" "${TIMING_LOG}" | head -10 >> "${SUMMARY_LOG}" 2>/dev/null || true
            echo "" >> "${SUMMARY_LOG}"
        fi

        echo ""
        echo "Build outputs:"
        echo "  Main log:    ${BUILD_DIR}/logs/synth.log"
        echo "  Summary:     ${BUILD_DIR}/logs/summary.log"
        echo "  Area log:    ${BUILD_DIR}/logs/area.log"
        echo "  Power log:   ${BUILD_DIR}/logs/power.log"
        if [ "{{mode}}" != "area" ]; then
            echo "  Timing log:  ${BUILD_DIR}/logs/timing.log"
        fi
        echo "  Reports:     ${BUILD_DIR}/reports/"
        echo "  Netlist:     ${BUILD_DIR}/netlist/"
        echo "  Latest:      ${LATEST_LINK}/"
        echo ""

        # Print summary
        if [ -f "${SUMMARY_LOG}" ]; then
            echo "--- Quick Summary ---"
            cat "${SUMMARY_LOG}"
        fi
    else
        echo "Status: FAILED"
        echo "========================================"
        echo "Check log: ${MAIN_LOG}"
        exit 1
    fi


# Elaborate a module with Design Compiler without technology compile
# Usage: just elaborate [module]
# Example: just elaborate plena
elaborate module="plena":
    #!/usr/bin/env bash
    set -euo pipefail

    unset PYTHONPATH
    unset PYTHONHOME
    unset VIRTUAL_ENV
    unset _PYTHON_SYSCONFIGDATA_NAME
    unset _PYTHON_HOST_PLATFORM
    unset PYTHONNOUSERSITE
    unset PYTHONHASHSEED
    export PATH=$(echo "$PATH" | tr ':' '\n' | grep -v '/nix/store.*python' | tr '\n' ':' | sed 's/:$//')

    {{synopsys_env}}

    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BUILD_DIR="{{root}}/build/elab/{{module}}/${TIMESTAMP}"
    LATEST_LINK="{{root}}/build/elab/{{module}}/latest"
    mkdir -p "${BUILD_DIR}"/{logs,reports,netlist,out}
    rm -f "${LATEST_LINK}"
    ln -sf "${TIMESTAMP}" "${LATEST_LINK}"

    MAIN_LOG="${BUILD_DIR}/logs/elaborate.log"
    START_SEC=$(date +%s)
    exec > >(tee -a "${MAIN_LOG}") 2>&1

    echo "========================================"
    echo "ELABORATE LOG"
    echo "========================================"
    echo "Module:     {{module}}"
    echo "Start Time: $(date)"
    echo "Build Dir:  ${BUILD_DIR}"
    echo "========================================"
    echo ""

    export SYNTH_MODULE="{{module}}"
    export SYNTH_BUILD_DIR="${BUILD_DIR}"
    DEFAULT_SYNTH_MAX_CORES=$(nproc)
    if [ "${DEFAULT_SYNTH_MAX_CORES}" -gt 16 ]; then
        DEFAULT_SYNTH_MAX_CORES=16
    fi
    export SYNTH_MAX_CORES="${SYNTH_MAX_CORES:-${DEFAULT_SYNTH_MAX_CORES}}"

    cd "{{synopsys_dir}}"
    dc_shell -f elaborate.tcl
    DC_EXIT=$?

    END_SEC=$(date +%s)
    ELAPSED_SEC=$((END_SEC - START_SEC))
    SUMMARY_LOG="${BUILD_DIR}/logs/summary.log"
    {
        echo "=== ELABORATE SUMMARY ==="
        echo "Module: {{module}}"
        echo "Timestamp: ${TIMESTAMP}"
        echo "Elapsed seconds: ${ELAPSED_SEC}"
        echo "Build Dir: ${BUILD_DIR}"
        echo ""
        if [ -f "${BUILD_DIR}/reports/{{module}}_generic_area.rpt" ]; then
            echo "=== GENERIC AREA ==="
            grep -A5 "Total cell area" "${BUILD_DIR}/reports/{{module}}_generic_area.rpt" 2>/dev/null || true
        fi
    } > "${SUMMARY_LOG}"

    echo ""
    echo "========================================"
    echo "End Time: $(date)"
    echo "Elapsed seconds: ${ELAPSED_SEC}"
    echo "Status: SUCCESS"
    echo "========================================"
    echo "Reports: ${BUILD_DIR}/reports/"
    echo "Latest:  ${LATEST_LINK}/"
    cat "${SUMMARY_LOG}"


# Show synthesis reports for a module (latest build)
synth-report module:
    #!/usr/bin/env bash
    LATEST="{{build_dir}}/{{module}}/latest"
    if [ -L "${LATEST}" ] && [ -d "${LATEST}" ]; then
        echo "=== Summary for {{module}} ($(readlink ${LATEST})) ==="
        if [ -f "${LATEST}/logs/summary.log" ]; then
            cat "${LATEST}/logs/summary.log"
        else
            echo "No summary found."
        fi
        echo ""
        echo "=== Full Reports ==="
        ls -la "${LATEST}/reports/" 2>/dev/null || echo "No reports found."
    else
        echo "No builds found for {{module}}. Run 'just synth {{module}}' first."
    fi

# Show all synthesis builds
synth-builds:
    @echo "=== Synthesis Builds ==="
    @if [ -d "{{build_dir}}" ]; then \
        for module_dir in {{build_dir}}/*/; do \
            module=$(basename "$module_dir"); \
            echo ""; \
            echo "$module:"; \
            ls -1 "$module_dir" 2>/dev/null | grep -v latest | sort -r | head -5 | while read ts; do \
                if [ -L "$module_dir/latest" ] && [ "$(readlink $module_dir/latest)" = "$ts" ]; then \
                    echo "  $ts (latest)"; \
                else \
                    echo "  $ts"; \
                fi; \
            done; \
        done; \
    else \
        echo "No builds found."; \
    fi

# Clean synthesis outputs
synth-clean module="" all="false":
    #!/usr/bin/env bash
    if [ "{{all}}" = "true" ]; then
        echo "Cleaning ALL synthesis builds..."
        rm -rf "{{build_dir}}"
        echo "Done."
    elif [ -n "{{module}}" ]; then
        echo "Cleaning builds for {{module}}..."
        rm -rf "{{build_dir}}/{{module}}"
        echo "Done."
    else
        echo "Usage:"
        echo "  just synth-clean <module>       # Clean specific module builds"
        echo "  just synth-clean '' true        # Clean ALL builds"
    fi

# Clean only old builds, keep latest N for each module
synth-clean-old keep="3":
    #!/usr/bin/env bash
    echo "Keeping last {{keep}} builds per module..."
    if [ -d "{{build_dir}}" ]; then
        for module_dir in {{build_dir}}/*/; do
            module=$(basename "$module_dir")
            echo "Processing $module..."
            ls -1 "$module_dir" 2>/dev/null | grep -v latest | sort -r | tail -n +$(({{keep}}+1)) | while read ts; do
                echo "  Removing $ts"
                rm -rf "$module_dir/$ts"
            done
        done
    fi
    echo "Done."

# =============================================================================
# Hardware Tests
# =============================================================================

test-hw:
    python3 src/basic_components/fp_operation/test/fp_ieee_partition_tb.py
    python3 src/basic_components/fp_operation/test/fp_ieee_normalize_tb.py
    # python3 src/basic_components/fp_operation/test/fp_ieee_casting_tb.py
    python3 src/basic_components/fp_operation/test/fp_cp_adder_tb.py
    python3 src/basic_components/fp_operation/test/fp_cp_mult_tb.py
    # python3 src/basic_components/fp_operation/test/fp_cp_asym_mult_tb.py

    # python3 src/basic_components/fp_operation/test/fp_reciprocal_tb.py
    # python3 src/basic_components/fp_operation/test/fp_exp_tb.py
    # python3 src/basic_components/fp_operation/test/fp_cp_reciprocal_tb.py
    # python3 src/basic_components/fp_operation/test/fp_cp_exp_tb.py

    python3 src/basic_components/fp_operation/test/fp_fix_reciprocal_tb.py
    python3 src/basic_components/fp_operation/test/fp_fix_exp_tb.py
    python3 src/basic_components/fp_operation/test/fp_fix_adder_tb.py
    python3 src/basic_components/fp_operation/test/fp_fix_mult_tb.py

test-sw:
    python3 tools/quant/quant_operations/sqrt.py
    python3 tools/quant/quant_operations/reciprocal.py

# =============================================================================
# RTL Simulation Tests
# =============================================================================

# Default test build directory
test_build_dir := root / "build" / "test"

# RTL simulation: generate workload + run simulation + verify results
#
# Usage: just rtl-sim <workload> [rebuild=true|false] [args...]
#
# Positional arguments:
#   <workload>   (required) Workload generator module under tools/testworkloads/.
#                Available: linear, bmm, rms_norm, loop, prefetch
#
#   [rebuild]    (optional, default "true") Controls TWO things at once:
#                  - true / 1 / yes : wipe the build dir (rm -rf) AND rebuild the
#                                     Verilator model (SKIP_BUILD=0)
#                  - false / 0 / no : keep the build dir AND reuse the cached
#                                     Verilator build (SKIP_BUILD=1)
#                NOTE: rebuild does NOT skip workload generation (Step 1); the
#                workload + machine code are regenerated on every run unless you
#                also pass --skip-asm-gen (see below).
#
#   [args...]    (optional) Flags passed straight through to the workload
#                generator (after --build-dir). Common ones (see linear.py /
#                rms_norm.py):
#                  --batch N            batch size               (default 8)
#                  --in-features N      input features           (default 128)
#                  --out-features N     output features          (default 256)
#                  --seed N             RNG seed                 (default 42)
#                  --mx-format FMT      mxfp | mxint             (default none)
#                  --use-aten-compiler  use the ATen PlenaCompiler path
#                  --skip-asm-gen       DO NOT regenerate generated_asm_code.asm;
#                                       reuse the existing (e.g. hand-edited) asm
#                                       in the build dir and only re-assemble it
#                                       into generated_machine_code.mem, then run.
#                                       (currently supported by: rms_norm)
#                (Other workloads accept their own flags — check the module.)
#
# Pipeline: Step 1 generate workload -> Step 2 run sim (SimTop_tb.py)
#           -> Step 3 verify (if verification_params.json/comparison_params.json exist)
#
# Manual asm testing workflow:
#   1. Run once normally to produce build/test/<workload>/generated_asm_code.asm
#        just rtl-sim rms_norm
#   2. Edit build/test/rms_norm/generated_asm_code.asm by hand.
#   3. Re-run with --skip-asm-gen to assemble + simulate your edited asm.
#        just rtl-sim rms_norm false --skip-asm-gen
#      (--skip-asm-gen auto-protects the build dir from being wiped, so it is
#       safe even with rebuild=true.)
#
# Examples:
#   just rtl-sim linear                              # Default: batch=8, in=128, out=256 (rebuild RTL)
#   just rtl-sim linear false                        # Skip RTL rebuild (use cached Verilator build)
#   just rtl-sim linear true --batch 16              # Force rebuild with custom args
#   just rtl-sim bmm false --batch 8                 # BMM without RTL rebuild
#   just rtl-sim rms_norm false --skip-asm-gen       # Reuse hand-edited asm, assemble + simulate
rtl-sim workload rebuild="true" +args="":
    #!/usr/bin/env bash
    set -euo pipefail

    BUILD_DIR="{{test_build_dir}}/{{workload}}"
    REBUILD="{{rebuild}}"
    PASS_ARGS="{{args}}"

    # Detect --skip-asm-gen in the passed-through args. When set, the existing
    # (possibly hand-edited) generated_asm_code.asm is reused, so the build dir
    # MUST NOT be wiped even if rebuild=true.
    SKIP_ASM=0
    case " ${PASS_ARGS} " in
        *" --skip-asm-gen "*) SKIP_ASM=1 ;;
    esac

    if [ "${SKIP_ASM}" = "1" ] && [ ! -f "${BUILD_DIR}/generated_asm_code.asm" ]; then
        echo "ERROR: --skip-asm-gen was requested but ${BUILD_DIR}/generated_asm_code.asm"
        echo "       does not exist. Run once without --skip-asm-gen to generate it,"
        echo "       then edit it manually and re-run with --skip-asm-gen."
        exit 1
    fi

    # Only clean build directory when rebuilding AND not reusing an existing asm
    if { [ "${REBUILD}" = "true" ] || [ "${REBUILD}" = "1" ] || [ "${REBUILD}" = "yes" ]; } && [ "${SKIP_ASM}" = "0" ]; then
        rm -rf "${BUILD_DIR}"
    fi
    mkdir -p "${BUILD_DIR}"

    echo "========================================"
    echo "PLENA RTL Simulation: {{workload}}"
    echo "========================================"
    echo "Build:   ${BUILD_DIR}"
    echo "Time:    $(date)"
    echo "Rebuild: ${REBUILD}"
    if [ "${SKIP_ASM}" = "1" ]; then
        echo "ASM gen: SKIPPED (reusing ${BUILD_DIR}/generated_asm_code.asm)"
    else
        echo "ASM gen: ENABLED"
    fi
    echo "Args:    {{args}}"
    echo "========================================"
    echo ""

    # Step 1: Generate workload
    echo "=== Step 1: Generate Workload ==="
    cd "{{root}}"
    python -m tools.testworkloads.{{workload}} \
        --build-dir "${BUILD_DIR}" \
        {{args}}

    echo ""
    echo "=== Step 2: Run RTL Simulation ==="

    # Set PYTHONPATH
    export PYTHONPATH="{{root}}/src/system/test:{{root}}/tools:{{root}}/PLENA_Tools:{{root}}/PLENA_Compiler:${PYTHONPATH:-}"

    # Set environment variables
    export WORKLOAD_DIR="${BUILD_DIR}"
    export FAKE_HBM_INIT_FILE="${BUILD_DIR}/hbm.mem"
    export INSTR_FILE="${BUILD_DIR}/generated_machine_code.mem"
    export FP_MEM_INIT_FILE="${BUILD_DIR}/fp_sram.mem"
    export INT_MEM_INIT_FILE="${BUILD_DIR}/int_sram.mem"
    export VECTOR_MEM_RESULT_FILE="${BUILD_DIR}/vector_result.mem"
    export FP_REG_RESULT_FILE="${BUILD_DIR}/fp_reg_result.mem"  # FP scalar register-file dump for debug
    export HBM_RESULT_FILE="${BUILD_DIR}/hbm_result.mem"  # HBM dump for verification
    export WAVES=1  # Enable waveform dumping
    export SIMTOP_TRACE=1  # Enable VCD generation

    # Control RTL rebuild
    if [ "${REBUILD}" = "false" ] || [ "${REBUILD}" = "0" ] || [ "${REBUILD}" = "no" ]; then
        export SKIP_BUILD=1
        echo "RTL rebuild: SKIPPED (using cached Verilator build)"
    else
        export SKIP_BUILD=0
        echo "RTL rebuild: ENABLED"
    fi

    # Run simulation (call directly, not through pytest, to avoid cocotb nested pytest issue)
    python src/system/test/SimTop_tb.py --workload-dir "${BUILD_DIR}" 2>&1 | tee "${BUILD_DIR}/sim.log"
    SIM_EXIT=${PIPESTATUS[0]}

    echo ""
    echo "========================================"
    echo "Simulation Complete"
    echo "========================================"
    echo "Build dir:  ${BUILD_DIR}"
    echo "Sim log:    ${BUILD_DIR}/sim.log"
    echo "Golden:     ${BUILD_DIR}/golden_result.pt"
    echo "HBM dump:   ${BUILD_DIR}/hbm_result.mem"
    echo "Waveform:   ${BUILD_DIR}/dump.vcd"
    echo ""

    if [ ${SIM_EXIT} -ne 0 ]; then
        echo "Simulation Status: FAILED"
        exit 1
    fi

    echo "Simulation Status: PASSED"
    echo ""

    # Step 3: Run verification (if verification params exist)
    echo "=== Step 3: Verify Results ==="
    if [ -f "${BUILD_DIR}/verification_params.json" ] || [ -f "${BUILD_DIR}/comparison_params.json" ]; then
        python -m verification.verify_rtl_sim --workload-dir "${BUILD_DIR}" --verbose
        VERIFY_EXIT=$?

        echo ""
        echo "========================================"
        echo "Test Complete"
        echo "========================================"

        if [ ${VERIFY_EXIT} -eq 0 ]; then
            echo "Status: PASSED (simulation + verification)"
        else
            echo "Status: FAILED (verification failed)"
            exit 1
        fi
    else
        echo "No verification params found, skipping verification"
        echo ""
        echo "========================================"
        echo "Test Complete"
        echo "========================================"
        echo "Status: PASSED (simulation only)"
    fi


# Clean test workloads
rtl-sim-clean workload="" all="false":
    #!/usr/bin/env bash
    if [ "{{all}}" = "true" ]; then
        echo "Cleaning ALL test workloads..."
        rm -rf "{{test_build_dir}}"
        echo "Done."
    elif [ -n "{{workload}}" ]; then
        echo "Cleaning {{workload}} workloads..."
        rm -rf "{{test_build_dir}}/{{workload}}"
        echo "Done."
    else
        echo "Usage:"
        echo "  just rtl-sim-clean linear      # Clean linear workloads"
        echo "  just rtl-sim-clean bmm         # Clean BMM workloads"
        echo "  just rtl-sim-clean '' true     # Clean ALL workloads"
    fi

# Aliases
alias sim := rtl-sim

# =============================================================================
# RTL Compilation Check (Verilator only, no simulation)
# =============================================================================

# RTL compilation check: only run Verilator to check for syntax/lint errors
# Usage: just rtl-check [module] [--trace] [-j N]
# Examples:
#   just rtl-check              # Check SimTop (default, no trace, auto-detect jobs)
#   just rtl-check SimTop       # Check SimTop explicitly
#   just rtl-check --trace      # Check with trace enabled (slower)
#   just rtl-check -j 32        # Use 32 parallel compilation jobs
rtl-check *args="SimTop":
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{root}}"
    export PYTHONPATH="{{root}}/tools:${PYTHONPATH:-}"
    python3 "{{root}}/tools/rtl_check.py" {{args}}

# RTL lint check (Verilator --lint-only with targeted warnings)
#   just rtl-lint              # Standard lint (PINMISSING, LATCH, etc.)
#   just rtl-lint --strict     # All warnings including style
rtl-lint *args="":
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{root}}"
    export PYTHONPATH="{{root}}/tools:${PYTHONPATH:-}"
    python3 "{{root}}/tools/rtl_lint.py" {{args}}

# Clean RTL check build
rtl-check-clean module="SimTop":
    rm -rf "{{root}}/src/system/test/build/{{module}}/check"
    echo "Cleaned {{module}} check build"

# FP arithmetic unit tests (custom RTL path, no DesignWare)
test-fp:
    #!/usr/bin/env bash
    set -euo pipefail
    RTL="{{root}}"
    cd "${RTL}"
    export PYTHONPATH=${RTL}/tools:${PYTHONPATH}
    TESTS=(
        src/basic_components/fp_operation/test/fp_cp_adder_tb.py
        src/basic_components/fp_operation/test/fp_cp_asym_mult_tb.py
        src/basic_components/fp_operation/test/fp_adder_tb.py
        src/basic_components/fp_operation/test/fp_mult_tb.py
        src/basic_components/fp_operation/test/fp_ieee_partition_tb.py
        src/basic_components/fp_operation/test/fp_ieee_casting_tb.py
        src/basic_components/fp_operation/test/fp_cp_exp_tb.py
    )
    PASS=0; FAIL=0
    for t in "${TESTS[@]}"; do
        echo "=== $(basename $t) ==="
        OUTPUT=$(python3 "$t" 2>&1)
        echo "${OUTPUT}" | tail -20
        if grep -q -- "- Failed: 0" <<<"${OUTPUT}"; then
            PASS=$((PASS+1))
        else
            FAIL=$((FAIL+1))
            echo "FAILED: $t"
        fi
    done
    echo "=== FP test summary: $PASS passed, $FAIL failed ==="
    [ $FAIL -eq 0 ] || exit 1

# Full-system RTL correctness test via PLENAProgram → Verilator
test-correctness:
    #!/usr/bin/env bash
    set -euo pipefail
    RTL="{{root}}"
    cd "${RTL}"
    PYTHONPATH=${RTL}/tools:${RTL}/PLENA_Tools:${RTL}/PLENA_Compiler \
      python3 src/system/test/SimTop_correctness_tb.py

# Unit test for data_flow_control.sv: verifies m_load_in_process timing
test-dfc:
    #!/usr/bin/env bash
    set -euo pipefail
    RTL="{{root}}"
    cd "${RTL}"
    PYTHONPATH=${RTL}/tools:${RTL}/PLENA_Tools:${RTL}/PLENA_Compiler \
      python3 ${RTL}/src/control/test/data_flow_control_tb.py
