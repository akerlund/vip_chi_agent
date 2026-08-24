#!/usr/bin/env python3
"""Compare the SV and Python checker opcode CLASSIFIERS, opcode by opcode.

Checks gated on an opcode classifier are silently switched off for any opcode
the classifier forgets. `check_vacuity.py` cannot see that: it aggregates on
check NAME, so a rule with hits from opcode set A reports as exercised even when
it is structurally impossible for set B. F-CHK-007.

Two questions, both mechanical:

  1. Do the SV and Python twins classify the same opcodes? A twin that disagrees
     means one port's check is applying where the other's is not.
  2. Which modeled REQ opcodes does NO classifier claim? Those are the opcodes
     that fall through every gate, so every gated rule stands down for them.

SV is parsed (function bodies -> constant names -> localparam values, with call
closure). Python is executed. Exit 1 on any mismatch.
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

# CHI_ROOT lets the check run against an extracted older tree, which is how it
# was validated: pointed at 829aa09 it must fail on the Combined Write + CMO
# omission that 4795775 fixed by hand.
ROOT = Path(os.environ.get("CHI_ROOT", Path(__file__).resolve().parents[1]))

# SV classifier -> Python twin. The Python port expresses some as frozensets
# rather than functions; the comparison is on the resulting opcode SET, which is
# what the checks actually consume.
PAIRS = [
    ("req_opcode_is_coherent_read", "_req_opcode_is_coherent_read"),
    ("req_opcode_is_coherent_write_data", "_COHERENT_WRITE_DATA_OPCODES_C"),
    ("req_opcode_is_coherent_rsp_only", "_COHERENT_RSP_ONLY_OPCODES_C"),
    ("req_has_modeled_completion", "_req_has_modeled_completion"),
    ("req_completion_uses_dat", "_req_completion_uses_dat"),
    # is_write_req_opcode / _is_write_req_opcode were removed with box 3.5. The
    # pair existed to gate the ExpCompAck bookkeeping onto write opcodes, and
    # that gate is gone: Table 2-9 makes the bit a property of the opcode, not
    # of the direction, so every request is now recorded and the classifier had
    # no remaining caller in either port.
]

# REQ opcodes deliberately claimed by no classifier, each with the reason.
# Anything unclaimed and NOT listed here fails the run: that is the whole point,
# since the failure mode being guarded against is an opcode family silently
# defaulting to "no" in every gate. Removing an entry is how you re-open the
# question; adding one is a recorded decision, not a way to quiet the check.
UNCLAIMED_BY_DESIGN = {
    0x00: "ReqLCrdReturn - a link-layer credit return, not a transaction",
    0x05: "PCrdReturn - no response by spec (E line 4215)",
    0x08: "CleanShared - unimplemented: no con_opcode_legal, sequence or driver",
    0x3a: "PrefetchTgt - no response associated with this request (E line 4215)",
}

# Entries above whose reason is "unimplemented" are the only ones that can stop
# being true without anybody touching this file. The other three are permanent
# properties of the opcode -- a credit return will never carry a transaction,
# and PrefetchTgt's exemption is the specification's own. "Unimplemented" is a
# statement about THIS TREE, and implementing the opcode silently makes it
# false while every gate keeps passing.
#
# So the claim is verified rather than trusted: the opcode must have no
# reference anywhere outside the two type packages. Implement CleanShared and
# this check fails, which is the point -- it forces the question of which
# classifiers should now claim it, including _req_has_modeled_completion, which
# is what arms the section 2.5 TxnID-reuse rules.
UNIMPLEMENTED_MARKER_C = "unimplemented"

# Where an opcode constant is ALLOWED to appear while unimplemented: its own
# definition and enum entry.
_TYPE_PACKAGES_C = ("sv/vip_chi_types_pkg.sv", "py/vip_chi_types_pkg.py")

# Directories searched for uses. Build outputs and vendored copies are excluded
# -- a stale extracted tree under testbench/*/rundir would report references
# that no longer exist in the source.
_SEARCH_DIRS_C = ("sv", "py", "scripts",
                  "testbench/sv/tc", "testbench/sv/tb",
                  "testbench/py/tc", "testbench/py/tb")


def unimplemented_references(root: Path, name: str) -> list[str]:
    """Every reference to an opcode outside the type packages, as file:line.

    Matched on the WHOLE identifier: VIP_CHI_REQ_CLEAN_SHARED_C is a prefix of
    VIP_CHI_REQ_CLEAN_SHARED_PERSIST_C, and the SNP channel has a CleanShared of
    its own, so a substring search would report the wrong opcode as implemented
    and quietly excuse this check.
    """
    sv_re = re.compile(rf"\bVIP_CHI_REQ_{name}_C\b")
    py_re = re.compile(rf"\bReqOpcode\.{name}\b")
    hits = []
    for d in _SEARCH_DIRS_C:
        base = root / d
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*")):
            if path.suffix not in (".sv", ".svh", ".py"):
                continue
            rel = path.relative_to(root).as_posix()
            if rel in _TYPE_PACKAGES_C or rel == "scripts/check_classifier_coverage.py":
                continue
            try:
                text = path.read_text()
            except (OSError, UnicodeDecodeError):
                continue
            for n, line in enumerate(text.split("\n"), 1):
                if sv_re.search(line) or py_re.search(line):
                    hits.append(f"{rel}:{n}")
    return hits

# Classifiers in vip_chi_types_pkg rather than the checker, reached by call.
PKG_FNS = {
    "vip_chi_req_opcode_is_atomic": "req_opcode_is_atomic",
    "vip_chi_req_opcode_is_atomic_returning_data": "req_opcode_is_atomic_returning_data",
    "vip_chi_req_opcode_is_combined_write_cmo": "req_opcode_is_combined_write_cmo",
}


def sv_localparams(text: str) -> dict[str, int]:
    out = {}
    for m in re.finditer(r"\b(VIP_CHI_REQ_[A-Z0-9_]+_C)\s*=\s*(\d+)'h([0-9A-Fa-f]+)", text):
        out[m.group(1)] = int(m.group(3), 16)
    return out


def sv_function_bodies(text: str) -> dict[str, str]:
    out = {}
    for m in re.finditer(r"function automatic bit (\w+)\s*\(([^;]*?)\);(.*?)endfunction",
                         text, re.S):
        out[m.group(1)] = m.group(3)
    return out


def sv_classifier_set(name, bodies, consts, all_ops, pkg_sets, seen=None) -> set[int]:
    """Opcodes for which the SV classifier returns true, resolving calls."""
    seen = seen or set()
    if name in seen:
        return set()
    seen = seen | {name}
    body = bodies[name]
    ops = {consts[c] for c in re.findall(r"\bVIP_CHI_REQ_[A-Z0-9_]+_C\b", body)
           if c in consts}
    for callee in re.findall(r"\b(\w+)\s*\(", body):
        if callee in PKG_FNS:
            ops |= pkg_sets[PKG_FNS[callee]]
        elif callee in bodies and callee != name:
            ops |= sv_classifier_set(callee, bodies, consts, all_ops, pkg_sets, seen)
    return ops & all_ops


def main() -> int:
    sys.path.insert(0, str(ROOT / "py"))
    sys.path.insert(0, str(ROOT / "py" / "sva"))
    import vip_chi_types_pkg as pyt
    import bind_chi as pyb

    all_ops = {int(o) for o in pyt.ReqOpcode}

    # A twin that does not exist is a mismatch, not a crash: the Combined Write
    # + CMO classifier lived only in the SV package before 4795775, which is
    # exactly the asymmetry this check is for.
    pkg_sets = {}
    missing_twins = []
    for sv_fn, py_fn in PKG_FNS.items():
        fn = getattr(pyt, py_fn, None)
        if fn is None:
            missing_twins.append((sv_fn, py_fn))
            pkg_sets[py_fn] = set()
        else:
            pkg_sets[py_fn] = {o for o in all_ops if fn(o)}

    sva = (ROOT / "sv" / "vip_chi_sva.sv").read_text()
    consts = sv_localparams((ROOT / "sv" / "vip_chi_types_pkg.sv").read_text())
    bodies = sv_function_bodies(sva)

    names = {int(o): o.name for o in pyt.ReqOpcode}
    rc = 0
    claimed: set[int] = set()

    print(f"{len(all_ops)} modeled REQ opcodes; {len(PAIRS)} classifier pairs\n")

    for sv_fn, py_fn in missing_twins:
        rc = 1
        print(f"  MISSING   {sv_fn} has no Python twin ({py_fn}) — every SV "
              f"classifier that calls it is wider than its Python counterpart")

    for sv_name, py_name in PAIRS:
        sv_set = sv_classifier_set(sv_name, bodies, consts, all_ops, pkg_sets)
        py_obj = getattr(pyb, py_name)
        py_set = ({o for o in all_ops if py_obj(o)} if callable(py_obj)
                  else {int(o) for o in py_obj} & all_ops)
        claimed |= sv_set | py_set
        if sv_set == py_set:
            print(f"  OK        {sv_name:<34} {len(sv_set):>2} opcodes")
        else:
            rc = 1
            print(f"  MISMATCH  {sv_name} vs {py_name}")
            for o in sorted(sv_set - py_set):
                print(f"              SV only: {names[o]} (0x{o:02x})")
            for o in sorted(py_set - sv_set):
                print(f"              py only: {names[o]} (0x{o:02x})")

    unclaimed = sorted(all_ops - claimed)
    print(f"\n{len(unclaimed)} opcode(s) claimed by NO classifier — every gated "
          f"rule stands down for these:")
    for o in unclaimed:
        if o in UNCLAIMED_BY_DESIGN:
            reason = UNCLAIMED_BY_DESIGN[o]
            if UNIMPLEMENTED_MARKER_C in reason:
                refs = unimplemented_references(ROOT, names[o])
                if refs:
                    rc = 1
                    print(f"  FAIL {names[o]:<34} 0x{o:02x}  claimed "
                          f"unimplemented here, but referenced in "
                          f"{len(refs)} place(s):")
                    for r in refs[:8]:
                        print(f"         {r}")
                    print(f"         Decide which classifiers now claim it -- "
                          f"_req_has_modeled_completion arms the section 2.5 "
                          f"TxnID-reuse rules -- then remove this entry.")
                    continue
                print(f"  ok   {names[o]:<34} 0x{o:02x}  {reason} [verified: "
                      f"no references outside the type packages]")
                continue
            print(f"  ok   {names[o]:<34} 0x{o:02x}  {reason}")
        else:
            rc = 1
            print(f"  FAIL {names[o]:<34} 0x{o:02x}  claimed by no classifier and "
                  f"not in UNCLAIMED_BY_DESIGN")

    stale = sorted(set(UNCLAIMED_BY_DESIGN) & claimed)
    for o in stale:
        rc = 1
        print(f"  FAIL {names.get(o, '?'):<34} 0x{o:02x}  is now claimed by a "
              f"classifier; drop it from UNCLAIMED_BY_DESIGN")

    return rc


if __name__ == "__main__":
    sys.exit(main())
