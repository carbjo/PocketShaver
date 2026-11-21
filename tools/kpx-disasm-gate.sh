#!/bin/zsh
# PocketShaver arm64 JIT backend (C) 2026 Sierra Burkhart
#
# Disassembly gate for the kpx_cpu hot memory paths.
#
# Compiles ppc-execute.cpp (interpreter handlers) and arm64-helpers.cpp (JIT
# memory helpers) with app flags, and normalizes the hot symbols' disassembly.
# "capture" records a baseline; "compare" fails on any change, catching
# regressions like a leaf handler gaining a stack frame. Baselines are
# machine- and toolchain-local; don't commit them.
#
# Usage:
#   tools/kpx-disasm-gate.sh capture [baseline-file]
#   tools/kpx-disasm-gate.sh compare [baseline-file]
set -e
MODE=${1:?usage: kpx-disasm-gate.sh capture|compare [baseline-file]}
BASE=${2:-/tmp/kpx-disasm-baseline.txt}
HERE=${0:A:h}                        # .../tools
SRC=${HERE:h}/SheepShaver/src
K=$SRC/kpx_cpu/src
OUT=$(mktemp -d /tmp/kpx-disasm-gate.XXXXXX)
trap "rm -rf $OUT" EXIT
SDK=$(xcrun --sdk macosx --show-sdk-path)

# Stub app-UI bridge headers needed by ppc-execute.cpp (same as the lockstep harness)
mkdir -p "$OUT/stubs"
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
FLAGS=(-target arm64-apple-ios15.2-macabi -isysroot "$SDK" -O3 -std=gnu++14
       -Wno-deprecated-declarations -Wno-shorten-64-to-32 -fno-strict-aliasing
       -DHAVE_CONFIG_H -DEMU_KHEPERIX)

clang++ $FLAGS $INCS -c "$K/cpu/ppc/ppc-execute.cpp"     -o "$OUT/ppc-execute.o"
clang++ $FLAGS $INCS -c "$K/cpu/jit/arm64/arm64-helpers.cpp" -o "$OUT/arm64-helpers.o"

# JIT memory/FP helpers plus interpreter load/store handler instantiations
PATTERN='kpx_vm_|kpx_op_|kpx_fp_|execute_loadstore|execute_fp_loadstore'

normalize() {
	# Sort symbol blocks for layout stability; strip addresses and raw branch
	# offsets, keep <sym+off> anchors and #imm operands. adrp annotations are
	# replaced to end of line (template names contain '>'); in an unlinked .o
	# they name arbitrary neighbors.
	xcrun llvm-objdump -d --demangle --no-show-raw-insn "$1" |
	sed -E 's/^[[:space:]]*[0-9a-f]+:[[:space:]]*/  /; s/[[:space:]]0x[0-9a-f]+[[:space:]]</ </; s/(adrp[[:space:]]+x[0-9]+,) <.*$/\1 <PAGE>/' |
	awk -v pat="$PATTERN" '
		/^[0-9a-f]+ </ { name = $0; sub(/^[0-9a-f]+ /, "", name)
		                 keep = (name ~ pat); ln = 0; next }
		keep && NF   { printf "%s\x01%06d\x01%s\n", name, ++ln, $0 }' |
	LC_ALL=C sort -t $'\x01' -k1,1 -k2,2n |
	awk -F $'\x01' '{ if ($1 != prev) { print $1; prev = $1 } print $3 }'
}

# Unlinked disassembly prints external targets as zeros, so also capture the
# relocation multiset (type + symbol, counted) to catch repointed references.
relocs() {
	xcrun llvm-objdump -r "$1" |
	awk '/^[0-9a-f]+/ { print $2, $3 }' | LC_ALL=C sort | uniq -c | sed -E 's/^[[:space:]]+//'
}

{
	normalize "$OUT/ppc-execute.o"
	normalize "$OUT/arm64-helpers.o"
	echo "== relocations: ppc-execute.o =="
	relocs "$OUT/ppc-execute.o"
	echo "== relocations: arm64-helpers.o =="
	relocs "$OUT/arm64-helpers.o"
} > "$OUT/current.txt"

case $MODE in
capture)
	nsyms=$(grep -c '^<' "$OUT/current.txt" || true)
	if [[ ${nsyms:-0} -eq 0 ]]; then
		echo "capture FAILED: no symbols matched the hot-path pattern (normalizer/toolchain drift?)"
		exit 2
	fi
	cp "$OUT/current.txt" "$BASE"
	echo "baseline captured: $BASE ($(wc -l < "$BASE" | tr -d ' ') lines, $nsyms symbols)"
	;;
compare)
	if [[ ! -f $BASE ]]; then echo "no baseline at $BASE (run capture first)"; exit 2; fi
	if diff -u "$BASE" "$OUT/current.txt" > "$OUT/diff.txt"; then
		echo "disasm gate: PASS (hot symbols byte-identical to baseline)"
	else
		echo "disasm gate: HOT-PATH CODE CHANGED"
		cat "$OUT/diff.txt"
		exit 1
	fi
	;;
*)
	echo "unknown mode: $MODE"; exit 2 ;;
esac
