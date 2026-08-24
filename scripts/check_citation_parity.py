#!/usr/bin/env python3
"""Every rule in the check registry cites a clause, and cites the same one in
both ports.

The gate this closes: the two ports carried their specification pointers in
different places and nothing compared them. At the baseline the pyUVM checkers
carried a citation at every `_chk` call site -- thirteen of which named the
wrong section, one of them for eight different rules -- and the SystemVerilog
checkers carried none at all. Both states pass every other check in `scripts/`,
because none of them reads a string that only ever appears in a report.

WHAT IS COMPARED

  * Registry coverage. Every `vip_chi_check_id_t` entry has an entry in
    `vip_chi_check_spec()`, and every rule the pyUVM table names is a real
    registry entry. A rule added to the enum without a citation fails here, at
    author time, instead of shipping a report that points nowhere.

  * Agreement. Where a rule exists in both ports it must cite the SAME string.
    Not "an equivalent section" -- the same string, because the citation is now
    generated into one and hand-checked in the other, and a divergence is
    exactly the drift this exists to catch.

  * No inline citations. `_chk`/`_err` take no `where` argument any more. A call
    site that passes a spec string is rejected: it would be a second, unchecked
    copy of the pointer, which is what the baseline had.

Rules that are SV-only are declared here rather than inferred. Being absent from
the pyUVM table is a legitimate state -- Verilator is 2-state, so the X/Z rules
cannot be ported -- but it must be a recorded decision, or a rule silently
dropped from one port would read as "SV-only" and pass.

An EMPTY citation is legal and means the rule claims no clause. It is not the
default: it must be written into both tables, so that "no clause behind this
rule" is a statement someone made rather than an omission.

Usage:
  check_citation_parity.py [repo_root]

Exit 1 on any missing, extra, or divergent citation.
"""
from __future__ import annotations

import os
import re
import sys

# Rules that exist in the SystemVerilog registry and deliberately have no pyUVM
# twin. Each names why. Anything else missing from the pyUVM table is a gap.
SV_ONLY_C: dict[str, str] = {
    "CHI_REQ_KNOWN_WHEN_VALID": "X/Z rule; Verilator is 2-state",
    "CHI_RSP_KNOWN_WHEN_VALID": "X/Z rule; Verilator is 2-state",
    "CHI_DAT_KNOWN_WHEN_VALID": "X/Z rule; Verilator is 2-state",
    "CHI_SNP_KNOWN_WHEN_VALID": "X/Z rule; Verilator is 2-state",
}

# Where a citation may legitimately appear in a checker: inside a message, as
# prose. What is rejected is a bare citation passed as an argument.
_INLINE_C = re.compile(r',\s*\n?\s*"(?:[ED] )?(?:section|Table)\s')


def _registry(root: str) -> list[str]:
  """Canonical rule names, in enum order, from the SystemVerilog registry."""
  src = open(os.path.join(root, "sv", "vip_chi_types_pkg.sv")).read()
  end = src.index("vip_chi_check_id_t;")
  body = src[src[:end].rindex("typedef enum"):end]
  names = re.findall(r"(VIP_CHI_CHK_\w+_E)\s*(?:=\s*\d+\s*)?,", body)
  return ["CHI_" + n[len("VIP_CHI_CHK_"):-len("_E")]
          for n in names if n != "VIP_CHI_CHK_NUM_E"]


def _sv_spec(root: str) -> dict[str, str]:
  """The SystemVerilog citation table, read out of the case statement."""
  src = open(os.path.join(root, "sv", "vip_chi_types_pkg.sv")).read()
  i = src.index("function automatic string vip_chi_check_spec")
  body = src[i:src.index("endfunction", i)]
  out = {}
  for enum, cite in re.findall(r"(VIP_CHI_CHK_\w+_E):\s*return\s*\"([^\"]*)\";",
                               body):
    out["CHI_" + enum[len("VIP_CHI_CHK_"):-len("_E")]] = cite
  return out


def _py_spec(root: str) -> dict[str, str]:
  """The pyUVM citation table. Parsed, not imported: this script must run with
  no cocotb on the path, and importing the checker would drag it in."""
  src = open(os.path.join(root, "py", "sva", "check_spec.py")).read()
  i = src.index("CHECK_SPEC_C = {")
  body = src[i:src.index("\n}", i)]
  return dict(re.findall(r"\"(CHI_\w+)\":\s*\"([^\"]*)\"", body))


def main(argv: list[str]) -> int:
  root = argv[1] if len(argv) > 1 else os.path.join(
      os.path.dirname(os.path.abspath(__file__)), "..")
  bad: list[str] = []

  registry = _registry(root)
  sv = _sv_spec(root)
  py = _py_spec(root)

  for rule in registry:
    if rule not in sv:
      bad.append(f"{rule}: in the registry, absent from vip_chi_check_spec()")
  for rule in sv:
    if rule not in registry:
      bad.append(f"{rule}: cited by vip_chi_check_spec(), not in the registry")
  for rule in py:
    if rule not in registry:
      bad.append(f"{rule}: in CHECK_SPEC_C, not in the registry")

  for rule in registry:
    if rule in py:
      # An SV-only rule may still carry its (empty) entry in the pyUVM table,
      # and does: the table is the shared statement of what each rule cites,
      # not a list of what the pyUVM checker evaluates. SV_ONLY_C only makes
      # ABSENCE legitimate.
      if sv.get(rule) != py[rule]:
        bad.append(f"{rule}: ports disagree\n"
                   f"      sv: {sv.get(rule)!r}\n"
                   f"      py: {py[rule]!r}")
    elif rule not in SV_ONLY_C:
      bad.append(f"{rule}: no citation in CHECK_SPEC_C, and not declared "
                 f"SV-only in this script")

  for rel in ("py/sva/bind_chi.py", "py/sva/bind_chi_snp.py"):
    src = open(os.path.join(root, rel)).read()
    for m in _INLINE_C.finditer(src):
      line = src[:m.start()].count("\n") + 2
      bad.append(f"{rel}:{line}: citation passed at the call site; it belongs "
                 f"in py/sva/check_spec.py, keyed by the rule")

  if bad:
    print("CITATION PARITY: FAIL")
    for b in bad:
      print(f"  {b}")
    return 1

  cited = sum(1 for r in registry if sv[r])
  print(f"CITATION PARITY: OK -- {len(registry)} rules, {cited} cited, "
        f"{len(registry) - cited} claiming no clause, "
        f"{len(SV_ONLY_C)} SV-only")
  return 0


if __name__ == "__main__":
  sys.exit(main(sys.argv))
