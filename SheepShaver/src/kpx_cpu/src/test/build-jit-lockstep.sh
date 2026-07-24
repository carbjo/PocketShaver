#!/bin/zsh
# PocketShaver arm64 JIT backend (C) 2026 Sierra Burkhart
#
# Build the interpreter-vs-JIT lockstep harness (test-jit-lockstep.cpp) as a
# Mac Catalyst arm64 CLI tool. The macabi triple selects the same
# config-ios-aarch64.h the shipping Catalyst app uses (ENABLE_DYNGEN=1,
# MEM_BULK=1), so the harness exercises the exact production JIT
# configuration. Usage:
#   ./build-jit-lockstep.sh [output-dir]     (default: /tmp/kpx-lockstep)
#   KPX_LOCKSTEP_OPT="-O3" KPX_LOCKSTEP_NO_INSTRUMENT=1 ./build-jit-lockstep.sh
#     (bench flavor: -O3 matches the app's GCC_OPTIMIZATION_LEVEL=3, and
#     dropping KPX_JIT_INSTRUMENT removes counter increments from timed code
#     paths — the shipping app never defines it. Correctness runs keep the
#     faster -O1 compile and the fail-if-zero counters.)
#   KPX_LOCKSTEP_ARCH=x86_64 ./build-jit-lockstep.sh
#     (Intel Catalyst slice: exercises the classic dyngen backend via
#     config-ios-x86_64.h; run the binary under Rosetta on arm64 hosts.
#     The arm64-only teeth — trap chaining, native vector/FP, inline
#     fastmem — legitimately read 0 there.)
set -e
HERE=${0:A:h}                       # .../kpx_cpu/src/test
K=${HERE:h}                         # .../kpx_cpu/src
SRC=${K:h:h}                        # .../SheepShaver/src
OUT=${1:-/tmp/kpx-lockstep}
mkdir -p "$OUT/stubs"
SDK=$(xcrun --sdk macosx --show-sdk-path)

# App-UI bridge headers pulled in by ppc-execute.cpp under TARGET_OS_IPHONE;
# the harness provides stub declarations (implementations live in the test)
cat > "$OUT/stubs/FatalErrorAlertViewControllerObjCCppHeader.h" <<'EOF'
#pragma once
void objc_displayRamAllocFailedAlert(void);
void objc_displayEncounteredIllegalInstructionAlert(void);
EOF
cat > "$OUT/stubs/MiscellaneousSettingsObjCCppHeader.h" <<'EOF'
#pragma once
void objc_reportRelativeMouseModeCapability(void);
int objc_getFrameRateSetting(void);
bool objc_getIPadMousePassthroughOn(void);
bool objc_getRelateiveMouseModeSettingIsAlwaysOn(void);
bool objc_getRelateiveMouseModeSettingIsAutomatic(void);
bool objc_getRelativeMouseTapToClick(void);
bool objc_getSoundDisabled(void);
bool objc_getIsLinearGammaEnabled(void);
void cpp_toggle_relative_mouse_on_main(void);
bool objc_getShouldBootInRelativeMouseMode(void);
bool objc_getIgnoreIllegalInstructions(void);
bool objc_getAltivec(void);
int objc_getRamInMb(void);
EOF

INCS=(-I"$OUT/stubs" -I"$SRC/MacOSX/config" -I"$SRC/Unix" -I"$K" -I"$SRC/kpx_cpu/include"
      -I"$SRC/Unix/dyngen_precompiled" -I"$SRC/CrossPlatform" -I"$SRC/include" -I"$SRC")
DEFS=(-DHAVE_CONFIG_H -DEMU_KHEPERIX)
[[ -z ${KPX_LOCKSTEP_NO_INSTRUMENT:-} ]] && DEFS+=(-DKPX_JIT_INSTRUMENT)
OPT=${KPX_LOCKSTEP_OPT:--O1}
ARCH=${KPX_LOCKSTEP_ARCH:-arm64}
FLAGS=(-target $ARCH-apple-ios15.2-macabi -isysroot "$SDK" ${=OPT} -g -std=gnu++14
       -Wno-deprecated-declarations -Wno-shorten-64-to-32 -fno-strict-aliasing)

SRCS=(
  "$K/cpu/ppc/ppc-cpu.cpp"
  "$K/cpu/ppc/ppc-decode.cpp"
  "$K/cpu/ppc/ppc-execute.cpp"
  "$K/cpu/ppc/ppc-translate.cpp"
  "$K/cpu/ppc/ppc-dyngen.cpp"
  "$K/cpu/ppc/ppc-jit.cpp"
  "$K/cpu/jit/basic-dyngen.cpp"
  "$K/cpu/jit/jit-cache.cpp"
  "$K/mathlib/ieeefp.cpp"
  "$K/mathlib/mathlib.cpp"
  "$K/utils/utils-cpuinfo.cpp"
  "$SRC/CrossPlatform/vm_alloc.cpp"
  "$HERE/test-jit-lockstep.cpp"
)

echo "compiling ${#SRCS[@]} sources..."
objs=()
for s in $SRCS; do
  o="$OUT/$(basename ${s%.cpp}).o"
  clang++ $FLAGS $INCS $DEFS -c "$s" -o "$o"
  objs+=("$o")
done
clang++ $FLAGS "${objs[@]}" -o "$OUT/test-jit-lockstep"
codesign -s - -f "$OUT/test-jit-lockstep" 2>/dev/null || true
echo "built: $OUT/test-jit-lockstep"
