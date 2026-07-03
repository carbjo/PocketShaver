#!/bin/zsh
# PocketShaver arm64 JIT backend (C) 2026 Sierra Burkhart
#
# Disassembly gate for the kpx_cpu hot memory paths.
#
# Compiles the two translation-critical TUs (ppc-execute.cpp for the
# interpreter handlers, arm64-helpers.cpp for the JIT memory helpers) with
# app-matching flags (-O3, macabi, no harness instrumentation), extracts the
# hot symbols, and normalizes the disassembly. "capture" records a baseline;
# "compare" diffs the current tree against it and fails on ANY change.
#
# Static instruction counting misses codegen regressions like a leaf handler
# gaining a stack frame; a byte-level shape diff does not. Baselines are
# machine+toolchain-local by design (never commit them): capture from a
# pristine checkout, compare from the working tree.
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

# App-UI bridge headers pulled in by ppc-execute.cpp under TARGET_OS_IPHONE
# (same stubs the lockstep harness uses)
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

# Hot-path symbols: JIT memory/FP helpers plus the interpreter load/store
# handler template instantiations
PATTERN='kpx_vm_|kpx_op_|kpx_fp_|execute_loadstore|execute_fp_loadstore'

normalize() {
	# symbol blocks in sorted order for layout stability; strip addresses and
	# raw branch-target offsets, keep <sym+off> anchors and #imm operands.
	# adrp annotations are normalized wholesale (greedy, to end of line —
	# demangled template names contain '>'): in an unlinked .o the page
	# anchor resolves against arbitrary neighboring symbols, pure layout noise
	xcrun llvm-objdump -d --demangle --no-show-raw-insn "$1" |
	sed -E 's/^[[:space:]]*[0-9a-f]+:[[:space:]]*/  /; s/[[:space:]]0x[0-9a-f]+[[:space:]]</ </; s/(adrp[[:space:]]+x[0-9]+,) <.*$/\1 <PAGE>/' |
	awk -v pat="$PATTERN" '
		/^[0-9a-f]+ </ { name = $0; sub(/^[0-9a-f]+ /, "", name)
		                 keep = (name ~ pat); ln = 0; next }
		keep && NF   { printf "%s\x01%06d\x01%s\n", name, ++ln, $0 }' |
	LC_ALL=C sort -t $'\x01' -k1,1 -k2,2n |
	awk -F $'\x01' '{ if ($1 != prev) { print $1; prev = $1 } print $3 }'
}

# Disassembly of unlinked objects is relocation-blind (external call targets
# and GOT references all print as zeros), so a change that only repoints a
# symbol reference would slip past the shape diff. Capture the relocation
# multiset (type + symbol, counted) alongside it to pin symbol identity.
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
