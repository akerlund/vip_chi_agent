#!/usr/bin/env python3
################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
################################################################################
#
# Table 12-2 is entered twice in this tree and the two entries must agree.
#
#   * req_tagop_permitted_mask() / vip_chi_req_tagop_permitted_mask() -- the
#     CLASSIFIER, read by CHI_REQ_TAGOP_LEGAL when it judges a flit on the wire;
#   * con_tagop_legal -- the GENERATOR's constraint, which decides what this VIP
#     is willing to emit in the first place.
#
# They cannot be one expression. A function call inside a SystemVerilog
# constraint makes every rand argument solve-ordered and turns a declarative
# constraint into a post-hoc check that can simply fail to solve, so the
# constraint has to name opcode groups. The Python item derives its groups from
# the classifier at import and cannot drift; the SystemVerilog item cannot, so
# this script compares its groups against the classifier opcode by opcode.
#
# Why it matters more than a tidy-up: a generator and a checker that disagree
# about the same table is the worse of the two failures. Either the VIP emits
# requests its own rule then reports -- a regression full of self-inflicted
# violations -- or, far quieter, the constraint permits something the checker
# also permits because BOTH were edited wrong, and the table stops being the
# authority either of them claims.
#
# Exit 0 when every opcode's permitted set matches; 1 otherwise.
#
################################################################################

from __future__ import annotations

import os
import re
import sys

_HERE_C = os.path.dirname(os.path.abspath(__file__))
_ROOT_C = os.path.dirname(_HERE_C)
sys.path.insert(0, os.path.join(_ROOT_C, "py"))

from vip_chi_types_pkg import ReqOpcode, Issue, req_tagop_permitted_mask  # noqa: E402

_SV_ITEM_C = os.path.join(_ROOT_C, "sv", "vip_chi_item.sv")

# The atomic range is expressed as a bound pair in the constraint rather than as
# an opcode list, exactly as it is everywhere else in the tree.
_ATOMIC_LO_C = 0x28
_ATOMIC_HI_C = 0x39

_TAGOP_BIT_C = {"2'b00": 0, "2'b01": 1, "2'b10": 2, "2'b11": 3}

# Opcodes the generator cannot emit at all, so a constraint group naming them
# would be dead. CleanShared has no con_opcode_legal entry, no sequence and no
# driver, and check_classifier_coverage.py enforces that by failing on any
# reference to it outside the type packages -- so naming it here would make one
# gate pass by making another one lie. The classifier still judges it, which is
# the vantage that matters: this VIP can only ever RECEIVE a CleanShared.
_UNGENERATABLE_C = {"CLEAN_SHARED"}


def _sv_constraint_body(text: str) -> str:
  """The con_tagop_legal block, brace-matched rather than regex-terminated."""
  start = text.find("constraint con_tagop_legal")
  if start < 0:
    return ""
  depth = 0
  i = text.index("{", start)
  for j in range(i, len(text)):
    if text[j] == "{":
      depth += 1
    elif text[j] == "}":
      depth -= 1
      if depth == 0:
        return text[i:j + 1]
  return ""


def _sv_groups(body: str):
  """Parse the constraint into {opcode-name-or-'ATOMIC': permitted mask}."""
  out = {}
  # Each group is `if (<selector>) { tagop inside {<values>}; }`.
  for m in re.finditer(r"if\s*\((.*?)\)\s*\{\s*tagop\s+inside\s*\{(.*?)\}\s*;",
                       body, re.S):
    selector, values = m.group(1), m.group(2)
    mask = 0
    for tok in re.findall(r"2'b\d\d", values):
      mask |= 1 << _TAGOP_BIT_C[tok]

    if "ATOMIC_STORE_0" in selector and "ATOMIC_COMPARE" in selector:
      out["ATOMIC"] = mask
      continue

    for name in re.findall(r"VIP_CHI_REQ_([A-Z0-9_]+)_C", selector):
      if name in out:
        print(f"  opcode {name} appears in two constraint groups")
      out[name] = mask
  return out


def main() -> int:
  text = open(_SV_ITEM_C).read()
  body = _sv_constraint_body(text)
  if not body:
    print("con_tagop_legal not found in sv/vip_chi_item.sv")
    return 1

  sv = _sv_groups(body)
  bad = []
  judged = 0
  unjudged = []

  for op in ReqOpcode:
    if op.name in _UNGENERATABLE_C:
      if sv.get(op.name) is not None:
        bad.append((op.name, None, sv[op.name],
                    "the generator cannot emit this opcode; see _UNGENERATABLE_C"))
      continue
    want = req_tagop_permitted_mask(int(Issue.E), int(op))
    if _ATOMIC_LO_C <= int(op) <= _ATOMIC_HI_C:
      got = sv.get("ATOMIC")
    else:
      got = sv.get(op.name)

    if want == 0b1111:
      # Unjudged by the classifier on purpose. The constraint must not name it
      # either -- a group that pins an opcode the classifier leaves free is the
      # generator being stricter than the rule, which is a disagreement too.
      if got is not None and got != 0b1111:
        bad.append((op.name, want, got, "classifier leaves this opcode free"))
      else:
        unjudged.append(op.name)
      continue

    judged += 1
    if got is None:
      bad.append((op.name, want, None, "not named by any constraint group"))
    elif got != want:
      bad.append((op.name, want, got, "permitted sets differ"))

  # A constraint group naming an opcode the enum does not have would be dead.
  known = {o.name for o in ReqOpcode} | {"ATOMIC"}
  for name in sv:
    if name not in known:
      bad.append((name, None, sv[name], "no such REQ opcode"))

  print(f"Table 12-2 opcodes judged by the classifier: {judged}")
  print(f"left free (no row / Don't Care): {len(unjudged)}")

  if bad:
    print("\nGENERATOR AND CHECKER DISAGREE:")
    for name, want, got, why in bad:
      w = "----" if want is None else format(want, "04b")
      g = "none" if got is None else format(got, "04b")
      print(f"  {name}: classifier={w} constraint={g} -- {why}")
    return 1

  print("\ncon_tagop_legal and req_tagop_permitted_mask agree on every opcode")
  return 0


if __name__ == "__main__":
  sys.exit(main())
