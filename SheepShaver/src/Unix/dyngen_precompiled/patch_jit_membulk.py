#!/usr/bin/env python3
# Generate MEM_BULK flavors of the precompiled x86_64 macOS dyngen ops.
#
# The stock *_macos.hpp files (produced by patch_jit.pl) wrap every guest
# memory access in a three-way translation stub (TRANS_RAX / TRANS_RDX)
# matching upstream's real-addressing layout: zero page -> gZeroPage[],
# kernel-data window -> gKernelData[], everything else dereferenced raw.
#
# PocketShaver's Catalyst build defines MEM_BULK instead, and the guest
# address model lives in vm_do_get_real_address() (kpx_cpu/src/cpu/vm.hpp):
#
#     host = VMBaseDiff + guest                        // flat bulk arena
#     except the two aliased 16 KB kernel windows:
#     (guest & ~0x3fff) == 0x68ffc000 || == 0x5fffc000
#         -> &gKernelData[guest & 0x3fff]
#
# (No zero-page special case: MEM_BULK maps guest 0 inside the arena.)
#
# This script rewrites each stub with a byte sequence replicating exactly
# that logic, patching VMBaseDiff and &gKernelData as imm64 at emit time:
#
#     push  rcx
#     mov   ecx, e<R>            ; R = rax or rdx (stub flavor)
#     and   ecx, 0xFFFFC000
#     cmp   ecx, 0x68FFC000
#     je    kwin
#     cmp   ecx, 0x5FFFC000
#     je    kwin
#     movabs rcx, imm64          ; <- VMBaseDiff
#     jmp   add
#     kwin: and e<R>, 0x3FFF
#     movabs rcx, imm64          ; <- (uintptr)gKernelData
#     add:  add r<R>, rcx
#     pop   rcx
#
# The replacement is longer than the original stub, so every copy_block()/
# inc_code_ptr() byte count and every emit-time patch offset downstream of a
# stub is rewritten to match.
#
# patch_jit.pl only instrumented ops named load/store — sufficient upstream,
# where mid-range guest addresses are identity-mapped and lmw/stmw/lwarx/
# stwcx/dcbz to the redirected windows never happen in practice.  Under
# MEM_BULK nothing is identity-mapped, so this script first re-runs
# patch_jit.pl (in a temp dir; the checked-in *_macos.hpp stay pristine)
# with the name filter widened to every guest-memory-touching op, then
# applies the stub replacement to that widened output.
#
# Usage: python3 patch_jit_membulk.py   (run from this directory)
# Inputs:  basic-dyngen-ops-x86_64.hpp, ppc-dyngen-ops-x86_64.hpp,
#          patch_jit.pl
# Outputs: basic-dyngen-ops-x86_64_macos_membulk.hpp,
#          ppc-dyngen-ops-x86_64_macos_membulk.hpp

import os
import re
import shutil
import subprocess
import sys
import tempfile

WIDE_FILTER = "load|store|lmw|stmw|lwarx|stwcx|dcbz"

# Original stub geometry (from patch_jit.pl).
OLD = {
    "RAX": {"len": 0x24, "k_off": 0x18},   # gKernelData imm32 slot offset
    "RDX": {"len": 0x29, "k_off": 0x1C},
}

def build_stub(reg):
    mov_ecx = [0x89, 0xC1] if reg == "RAX" else [0x89, 0xD1]
    and_low = [0x25, 0xFF, 0x3F, 0x00, 0x00] if reg == "RAX" \
        else [0x81, 0xE2, 0xFF, 0x3F, 0x00, 0x00]
    add_reg = [0x48, 0x01, 0xC8] if reg == "RAX" else [0x48, 0x01, 0xCA]

    b = []
    b += [0x51]                                          # push rcx
    b += mov_ecx                                         # mov  ecx, e<R>
    b += [0x81, 0xE1, 0x00, 0xC0, 0xFF, 0xFF]            # and  ecx, 0xFFFFC000
    b += [0x81, 0xF9, 0x00, 0xC0, 0xFF, 0x68]            # cmp  ecx, 0x68FFC000
    je1 = len(b); b += [0x74, 0x00]                      # je   kwin
    b += [0x81, 0xF9, 0x00, 0xC0, 0xFF, 0x5F]            # cmp  ecx, 0x5FFFC000
    je2 = len(b); b += [0x74, 0x00]                      # je   kwin
    v_imm = len(b) + 2
    b += [0x48, 0xB9] + [0x00] * 8                       # movabs rcx, VMBaseDiff
    jmp = len(b); b += [0xEB, 0x00]                      # jmp  add
    kwin = len(b)
    b += and_low                                         # and  e<R>, 0x3FFF
    k_imm = len(b) + 2
    b += [0x48, 0xB9] + [0x00] * 8                       # movabs rcx, gKernelData
    add = len(b)
    b += add_reg                                         # add  r<R>, rcx
    b += [0x59]                                          # pop  rcx

    b[je1 + 1] = kwin - (je1 + 2)
    b[je2 + 1] = kwin - (je2 + 2)
    b[jmp + 1] = add - (jmp + 2)
    return b, v_imm, k_imm

NEW = {}
for reg in ("RAX", "RDX"):
    stub, v_imm, k_imm = build_stub(reg)
    NEW[reg] = {"bytes": stub, "len": len(stub), "v_imm": v_imm, "k_imm": k_imm,
                "delta": len(stub) - OLD[reg]["len"]}

def macro_text(name, stub):
    lines = []
    for i in range(0, len(stub), 12):
        chunk = ",".join("0x%02X" % x for x in stub[i:i + 12])
        lines.append("\t" + chunk)
    return "#define " + name + " \\\n" + ",\\\n".join(lines) + "\n"

K_RE = re.compile(
    r"^\s*\*\(uint32_t \*\)\(code_ptr\(\) \+ (\d+)\) = \(uint32_t\)\(uintptr\)gKernelData;\s*$")
Z_RE = re.compile(
    r"^\s*\*\(uint32_t \*\)\(code_ptr\(\) \+ (\d+)\) = \(uint32_t\)\(uintptr\)gZeroPage;\s*$")
COPY_RE = re.compile(r"^(\s*copy_block\()([A-Za-z0-9_]+)(, )(\d+)(\);\s*)$")
INC_RE = re.compile(r"^(\s*inc_code_ptr\()(\d+)(\);\s*)$")

def replace_macro(text, name, replacement):
    pat = re.compile(r"#define " + name + r" \\\n(?:[^\n]*\\\n)*[^\n]*\n")
    new_text, n = pat.subn(replacement, text)
    if n != 1:
        sys.exit(f"error: expected exactly one #define {name}, found {n}")
    return new_text

def transform(src_path, dst_path):
    with open(src_path) as f:
        text = f.read()

    text = replace_macro(text, "TRANS_RAX", macro_text("TRANS_RAX", NEW["RAX"]["bytes"]))
    text = replace_macro(text, "TRANS_RDX", macro_text("TRANS_RDX", NEW["RDX"]["bytes"]))

    text = text.replace(
        "extern uint8 gZeroPage[0x3000], gKernelData[0x2000];",
        "extern uint8 gZeroPage[0x3000], gKernelData[0x2000];\n"
        "extern unsigned long VMBaseDiff;\t// vm_uintptr_t, set by vm_init()",
        1)

    # Rewrite one op block at a time: everything between copy_block(name, n)
    # and inc_code_ptr(n).  A block holds the stub patch-line pairs
    # (gKernelData then gZeroPage, both in stub order) plus dyngen parameter
    # and literal-pool relocations whose code_ptr() offsets must shift when
    # they sit downstream of a resized stub.
    CP_RE = re.compile(r"code_ptr\(\) \+ (\d+)")
    out = []
    copy_line = None        # held-back copy_block match
    block = []              # buffered block body lines
    stubs_total = 0

    def flush_block(inc_line):
        nonlocal copy_line, block, stubs_total
        ks = [int(m.group(1)) for m in (K_RE.match(l) for l in block) if m]
        zs = [int(m.group(1)) for m in (Z_RE.match(l) for l in block) if m]
        if len(ks) != len(zs):
            sys.exit(f"error: unpaired stub patch lines (k={len(ks)} z={len(zs)})")

        # Stub start offsets and types (original numbering), in stub order.
        stubs = []
        for k, z in zip(ks, zs):
            if z - k == 8:
                reg = "RAX"
            elif z - k == 9:
                reg = "RDX"
            else:
                sys.exit(f"error: unrecognized stub pair k={k} z={z}")
            stubs.append((k - OLD[reg]["k_off"], reg))

        def shifted(n):
            # Bytes gained by every stub that starts before original offset n.
            return n + sum(NEW[reg]["delta"] for s, reg in stubs if s < n)

        total_delta = sum(NEW[reg]["delta"] for _, reg in stubs)
        stubs_total += len(stubs)

        m = COPY_RE.match(copy_line)
        out.append(m.group(1) + m.group(2) + m.group(3)
                   + str(int(m.group(4)) + total_delta) + m.group(5))
        pending = list(stubs)
        for line in block:
            if K_RE.match(line):
                s, reg = pending.pop(0)
                s_new = shifted(s)
                out.append(f"    *(uint64_t *)(code_ptr() + {s_new + NEW[reg]['v_imm']})"
                           f" = (uint64_t)VMBaseDiff;\n")
                out.append(f"    *(uint64_t *)(code_ptr() + {s_new + NEW[reg]['k_imm']})"
                           f" = (uint64_t)(uintptr)gKernelData;\n")
                continue
            if Z_RE.match(line):
                continue
            out.append(CP_RE.sub(lambda m: f"code_ptr() + {shifted(int(m.group(1)))}", line))
        m = INC_RE.match(inc_line)
        out.append(m.group(1) + str(int(m.group(2)) + total_delta) + m.group(3))
        copy_line = None
        block = []

    for line in text.splitlines(keepends=True):
        if COPY_RE.match(line):
            if copy_line is not None:
                sys.exit("error: copy_block without matching inc_code_ptr")
            copy_line = line
            continue
        if copy_line is not None:
            if INC_RE.match(line):
                flush_block(line)
            else:
                block.append(line)
            continue
        out.append(line)
    if copy_line is not None:
        sys.exit("error: trailing copy_block without inc_code_ptr")

    header = ("/* Generated by patch_jit_membulk.py from " + src_path + ".\n"
              " * MEM_BULK flavor: guest->host translation mirrors\n"
              " * vm_do_get_real_address() — flat VMBaseDiff add with the two\n"
              " * aliased 16 KB kernel windows redirected into gKernelData[].\n"
              " * Do not edit by hand. */\n")
    with open(dst_path, "w") as f:
        f.write(header + "".join(out))
    print(f"{dst_path}: rewrote {stubs_total} translation stubs "
          f"(TRANS_RAX {OLD['RAX']['len']}->{NEW['RAX']['len']}B, "
          f"TRANS_RDX {OLD['RDX']['len']}->{NEW['RDX']['len']}B)")

def widened_patch_jit(tmpdir):
    with open("patch_jit.pl") as f:
        perl = f.read()
    needle = '$valid = $name =~ /load|store/;'
    if needle not in perl:
        sys.exit("error: patch_jit.pl name filter not found — script needs updating")
    perl = perl.replace(needle, f'$valid = $name =~ /{WIDE_FILTER}/;')
    # lmw's final word loads through rdx (mov eax,(rdx) = 8b 02), a pattern
    # absent from load/store-named ops and hence from the stock key set.  It
    # is always the op's last access, so translating rdx in place is safe.
    for needle, extra in (
            ('"8902", "0fb620", "8820",', '"8902", "8b02", "0fb620", "8820",'),
            ('@keys_trans_rdx = ("890a", "8902", "890411");',
             '@keys_trans_rdx = ("890a", "8902", "8b02", "890411");')):
        if needle not in perl:
            sys.exit(f"error: patch_jit.pl key table not found: {needle!r}")
        perl = perl.replace(needle, extra)
    with open(os.path.join(tmpdir, "patch_jit_wide.pl"), "w") as f:
        f.write(perl)
    for src in ("basic-dyngen-ops-x86_64.hpp", "ppc-dyngen-ops-x86_64.hpp"):
        shutil.copy(src, tmpdir)
    subprocess.run(["perl", "patch_jit_wide.pl"], cwd=tmpdir, check=True)

# dcbz zeroes a 32-byte cache line as four 8-byte stores off one address
# computation; the byte-pattern keys cannot express "translate once, then
# four derefs", so it gets a hand-inserted stub after the address masking
# prologue (mov eax,r12d / and eax,~0x1f / mov r12d,eax / mov eax,eax).
# Emitted in patch_jit.pl's own output format (TRANS_RAX token + imm32
# patch lines + adjusted sizes) so transform() below reshapes it like any
# other stub.
DCBZ_OLD = """    static const uint8 op_dcbz_T0_code[] = {
       0x44, 0x89, 0xe0, 0x83, 0xe0, 0xe0, 0x41, 0x89, 0xc4, 0x89, 0xc0, 0x48,
       0xc7, 0x00, 0x00, 0x00, 0x00, 0x00, 0x48, 0xc7, 0x40, 0x08, 0x00, 0x00,
       0x00, 0x00, 0x48, 0xc7, 0x40, 0x10, 0x00, 0x00, 0x00, 0x00, 0x48, 0xc7,
       0x40, 0x18, 0x00, 0x00, 0x00, 0x00
    };
    copy_block(op_dcbz_T0_code, 42);
    inc_code_ptr(42);
"""
DCBZ_NEW = """    static const uint8 op_dcbz_T0_code[] = {
       0x44, 0x89, 0xe0, 0x83, 0xe0, 0xe0, 0x41, 0x89, 0xc4, 0x89, 0xc0,
       TRANS_RAX,
       0x48,
       0xc7, 0x00, 0x00, 0x00, 0x00, 0x00, 0x48, 0xc7, 0x40, 0x08, 0x00, 0x00,
       0x00, 0x00, 0x48, 0xc7, 0x40, 0x10, 0x00, 0x00, 0x00, 0x00, 0x48, 0xc7,
       0x40, 0x18, 0x00, 0x00, 0x00, 0x00
    };
    copy_block(op_dcbz_T0_code, 78);
    *(uint32_t *)(code_ptr() + 35) = (uint32_t)(uintptr)gKernelData;
    *(uint32_t *)(code_ptr() + 43) = (uint32_t)(uintptr)gZeroPage;
    inc_code_ptr(78);
"""

def patch_dcbz(path):
    with open(path) as f:
        text = f.read()
    if DCBZ_OLD not in text:
        sys.exit(f"error: op_dcbz_T0 body not found in {path} — bytes changed?")
    with open(path, "w") as f:
        f.write(text.replace(DCBZ_OLD, DCBZ_NEW, 1))

# Three ops in the widened set have internal control flow whose rel8
# displacements cross an inserted stub; patch_jit.pl never adjusts branch
# displacements (no load/store-named op has any), so they go stale:
#   - stwcx: the two reservation-check branches (je/jne) jump forward
#     across the guarded store to the epilogue.
#   - lmw_T0_im / stmw_T0_im: the loop forms jump forward over the loop
#     body to the condition check, and loop back across the body.
# Compensate by the FINAL stub size: transform() later grows the
# perl-inserted 36/41-byte stub to NEW[reg]["len"] bytes, and each listed
# branch brackets exactly one stub.  (The stub preserves rcx, so the loop
# ops' guest address register survives each iteration.)
BRANCH_FIXES = {
    "gen_op_stwcx_T0_T1": ("RAX", [(0x74, 0x24, +1), (0x75, 0x0f, +1)]),
    "gen_op_lmw_T0_im":   ("RAX", [(0xeb, 0x11, +1), (0x76, 0xea, -1)]),
    "gen_op_stmw_T0_im":  ("RDX", [(0xeb, 0x12, +1), (0x76, 0xe9, -1)]),
}

def patch_branch_displacements(path):
    with open(path) as f:
        text = f.read()
    for op, (reg, fixes) in BRANCH_FIXES.items():
        delta = NEW[reg]["len"]
        m = re.search(r"DEFINE_GEN\(" + op + r"\b.*?#endif\n", text, re.S)
        if not m:
            sys.exit(f"error: {op} body not found in {path}")
        block = m.group(0)
        if block.count("TRANS_") != 1:
            sys.exit(f"error: {op} expected exactly one stub, "
                     f"found {block.count('TRANS_')}")
        fixed = block
        for opc, disp, direction in fixes:
            signed = disp - 0x100 if disp >= 0x80 else disp
            new_signed = signed + direction * delta
            if not -128 <= new_signed <= 127:
                sys.exit(f"error: {op} displacement {new_signed} exceeds rel8")
            old = f"0x{opc:02x}, 0x{disp:02x}"
            new = f"0x{opc:02x}, 0x{new_signed & 0xff:02x}"
            if fixed.count(old) != 1:
                sys.exit(f"error: {op} branch bytes {old!r} not unique — layout changed?")
            fixed = fixed.replace(old, new, 1)
        text = text.replace(block, fixed, 1)
    with open(path, "w") as f:
        f.write(text)

# The FP ops route results through the FD scratch (powerpc_dyngen::reg_F3,
# see the FD macro in ppc-dyngen-ops.cpp) at a displacement frozen when the
# headers were generated against the upstream-era powerpc_cpu layout
# (0x1008a8).  This fork's layout drifted — that offset now lands on
# codegen.parent_cpu, so every FP instruction corrupted the dyngen object.
# Zero the frozen displacement and patch the real offset at emit time,
# where &reg_F3 and cpu() are both in scope.
FD_OLD_DISP = [0xa8, 0x08, 0x10, 0x00]        # little-endian 0x1008a8
FD_MODRM = {0x85, 0x8d, 0x95, 0x9d, 0xa5, 0xad, 0xb5, 0xbd}   # [rbp]+disp32
FD_PATCH = ("    *(uint32_t *)(code_ptr() + {off}) = "
            "(uint32_t)((uintptr)&reg_F3 - (uintptr)cpu());\n")
TOKEN_LEN = {"TRANS_RAX": None, "TRANS_RDX": None}   # filled from NEW below

def fix_fd_temp(path):
    tok_len = {"TRANS_RAX": NEW["RAX"]["len"], "TRANS_RDX": NEW["RDX"]["len"],
               "ADD_RAX_RCX": 2, "ADD_RDX_RCX": 2, "ADD_RAX_RDX": 2}
    with open(path) as f:
        lines = f.readlines()
    out = []
    i = 0
    total = 0
    while i < len(lines):
        line = lines[i]
        if "static const uint8" not in line or "_code[]" not in line:
            out.append(line)
            i += 1
            continue
        # Collect the array body up to the closing brace.
        blk = [line]
        i += 1
        while "};" not in lines[i - 1]:
            blk.append(lines[i])
            i += 1
        body = "".join(blk)
        # Tokenize: hex bytes plus the stub and ADD macro markers, in order.
        toks = re.findall(
            r"TRANS_RAX|TRANS_RDX|ADD_RAX_RCX|ADD_RDX_RCX|ADD_RAX_RDX|0x[0-9a-fA-F]{2}",
            body)
        vals = [t if t[0] in "TA" else int(t, 16) for t in toks]
        offs = []
        pos = 0
        for v in vals:
            offs.append(pos)
            pos += tok_len[v] if isinstance(v, str) else 1
        patches = []
        j = 0
        while j + 3 < len(vals):
            window = vals[j:j + 4]
            if (window == FD_OLD_DISP and j > 0
                    and isinstance(vals[j - 1], int) and vals[j - 1] in FD_MODRM):
                vals[j:j + 4] = [0, 0, 0, 0]
                patches.append(offs[j])
                total += 1
                j += 4
            else:
                j += 1
        if patches:
            # Re-emit the array body with the zeroed displacement bytes.
            new_body_lines = []
            row = []
            for v in vals:
                if isinstance(v, str):
                    if row:
                        new_body_lines.append("       " + ", ".join(row) + ", \n")
                        row = []
                    new_body_lines.append("       " + v + ",\n")
                else:
                    row.append("0x%02x" % v)
                    if len(row) == 12:
                        new_body_lines.append("       " + ", ".join(row) + ",\n")
                        row = []
            if row:
                new_body_lines.append("       " + ", ".join(row) + "\n")
            out.append(blk[0])
            out.extend(new_body_lines)
            out.append("    };\n")
            # Forward the block tail, inserting patch lines before
            # inc_code_ptr.
            while "inc_code_ptr" not in lines[i]:
                out.append(lines[i])
                i += 1
            for off in patches:
                out.append(FD_PATCH.format(off=off))
            out.append(lines[i])
            i += 1
        else:
            out.extend(blk)
    with open(path, "w") as f:
        f.writelines(out)
    print(f"{path}: repointed {total} FD-temp displacements to reg_F3")

# Two guest stores use byte patterns patch_jit.pl's key table cannot
# express, so they never got stubs (latent upstream: raw mid-range derefs
# were identity-mapped there):
#   - op_store_vect_VD_T0's fourth word stores through rcx (89 01).  A
#     dedicated rcx-flavor stub (scratch rdx; rax holds the store value and
#     must survive) goes in front of it.
#   - op_store_single_F0_T1_T2 stores through rax with the value in ecx
#     (89 08); TRANS_RAX's push/pop rcx keeps the value intact.
# Both are patched on the final generated file, in final numbering.
TRANS_RCX_MACRO = """#define TRANS_RCX \\
\t0x52,\\
\t0x89,0xCA,\\
\t0x81,0xE2,0x00,0xC0,0xFF,0xFF,\\
\t0x81,0xFA,0x00,0xC0,0xFF,0x68,\\
\t0x74,0x14,\\
\t0x81,0xFA,0x00,0xC0,0xFF,0x5F,\\
\t0x74,0x0C,\\
\t0x48,0xBA,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,\\
\t0xEB,0x10,\\
\t0x81,0xE1,0xFF,0x3F,0x00,0x00,\\
\t0x48,0xBA,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,\\
\t0x48,0x01,0xD1,\\
\t0x5A
"""
RCX_LEN, RCX_V_IMM, RCX_K_IMM = 57, 27, 45

TAIL_PATCHES = [
    # (op name, old tail, new tail, old size, stub start, v_imm, k_imm, new size)
    ("gen_op_store_vect_VD_T0",
     "0x41, 0x8b, 0x47, 0x0c, 0x0f, 0xc8, 0x83, 0xc1, 0x0c, 0x89, 0xc9, 0x89,\n       0x01\n",
     "0x41, 0x8b, 0x47, 0x0c, 0x0f, 0xc8, 0x83, 0xc1, 0x0c, 0x89, 0xc9, \n"
     "       TRANS_RCX,\n       0x89, 0x01\n",
     223, 221, RCX_V_IMM, RCX_K_IMM, 223 + RCX_LEN),
    ("gen_op_store_single_F0_T1_T2",
     "0x01, 0xe8, 0x89, 0x08\n",
     "0x01, 0xe8, \n       TRANS_RAX,\n       0x89, 0x08\n",
     88, 86, None, None, 88 + 56),
]

def patch_raw_tails(path):
    with open(path) as f:
        text = f.read()
    text = text.replace("#ifdef DYNGEN_IMPL\nextern uint8 gZeroPage",
                        TRANS_RCX_MACRO + "\n#ifdef DYNGEN_IMPL\nextern uint8 gZeroPage", 1)
    if "TRANS_RCX \\" not in text:
        sys.exit(f"error: failed to install TRANS_RCX macro in {path}")
    for op, old_tail, new_tail, old_n, s, v_imm, k_imm, new_n in TAIL_PATCHES:
        if v_imm is None:
            v_imm, k_imm = NEW["RAX"]["v_imm"], NEW["RAX"]["k_imm"]
        m = re.search(r"DEFINE_GEN\(" + op + r"\b.*?#endif\n", text, re.S)
        if not m:
            sys.exit(f"error: {op} not found in {path}")
        block = m.group(0)
        for needle in (old_tail, f"copy_block(op_{op[7:]}_code, {old_n});",
                       f"inc_code_ptr({old_n});"):
            if block.count(needle) != 1:
                sys.exit(f"error: {op}: expected fragment missing: {needle!r}")
        fixed = block.replace(old_tail, new_tail, 1)
        fixed = fixed.replace(
            f"copy_block(op_{op[7:]}_code, {old_n});",
            f"copy_block(op_{op[7:]}_code, {new_n});", 1)
        fixed = fixed.replace(
            f"inc_code_ptr({old_n});",
            f"    *(uint64_t *)(code_ptr() + {s + v_imm}) = (uint64_t)VMBaseDiff;\n"
            f"    *(uint64_t *)(code_ptr() + {s + k_imm}) = (uint64_t)(uintptr)gKernelData;\n"
            f"    inc_code_ptr({new_n});", 1)
        text = text.replace(block, fixed, 1)
    with open(path, "w") as f:
        f.write(text)
    print(f"{path}: stubbed {len(TAIL_PATCHES)} raw store tails")

with tempfile.TemporaryDirectory() as tmpdir:
    widened_patch_jit(tmpdir)
    patch_dcbz(os.path.join(tmpdir, "ppc-dyngen-ops-x86_64_macos.hpp"))
    patch_branch_displacements(os.path.join(tmpdir, "ppc-dyngen-ops-x86_64_macos.hpp"))
    transform(os.path.join(tmpdir, "basic-dyngen-ops-x86_64_macos.hpp"),
              "basic-dyngen-ops-x86_64_macos_membulk.hpp")
    transform(os.path.join(tmpdir, "ppc-dyngen-ops-x86_64_macos.hpp"),
              "ppc-dyngen-ops-x86_64_macos_membulk.hpp")
    fix_fd_temp("ppc-dyngen-ops-x86_64_macos_membulk.hpp")
    patch_raw_tails("ppc-dyngen-ops-x86_64_macos_membulk.hpp")
