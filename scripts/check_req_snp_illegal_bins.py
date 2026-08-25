#!/usr/bin/env python3
################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
################################################################################
#
# cg_req_snp_pairing declares two illegal_bins classes over (request opcode x
# snoop opcode). A covergroup cannot call a function, so those classes are an
# enumeration by hand of pairings IHI 0050 E Table 4-5 (D Table 4-3) forbids --
# while the rule that judges the same pairing, catalogue D8, reads the table
# through vip_chi_snoop_permitted_for_req.
#
# Two statements of one table, and the dangerous direction is specific: an
# illegal bin that claims a pairing the table PERMITS ends the simulation the
# first time conformant traffic produces it, and it ends it in the worst
# available way -- VCS treats the hit as a verification error and stops before
# the UVM report summary a regression script greps for, so the run reads as a
# simulator problem rather than as a wrong bin. The reverse direction is
# harmless: a forbidden pairing with no bin is simply not covered, and D8 still
# reports it.
#
# So this gate answers one question, in the direction that can break a run: is
# every pairing the illegal bins claim also one the table rejects?
#
# Exit 0 when the bins are a subset of what the table forbids; 1 otherwise.
#
################################################################################

from __future__ import annotations

import os
import re
import sys

_HERE_C = os.path.dirname(os.path.abspath(__file__))
_ROOT_C = os.path.dirname(_HERE_C)
_CHECKER_C = os.path.join(_ROOT_C, "sv", "vip_chi_coherency_checker.sv")

sys.path.insert(0, os.path.join(_ROOT_C, "py"))
from vip_chi_types_pkg import (  # noqa: E402
  ReqOpcode, SnpOpcode, snoop_permitted_for_req, req_generates_snoop)

_BIN_RE_C = re.compile(r"bins\s+(\w+)\s*=\s*\{([A-Z0-9_]+)\}")


def _covergroup_body(text: str, name: str) -> str:
  start = text.find(f"covergroup {name}")
  if start < 0:
    return ""
  end = text.find("endgroup", start)
  return text[start:end] if end > start else ""


def _coverpoint_bins(text: str, cp: str) -> dict:
  """{bin name: the SV constant it holds}, parsed from the coverpoint itself so
  a renamed bin is a parse miss rather than a wrong answer."""
  m = re.search(rf"{cp}\s*:\s*coverpoint[^{{]*\{{(.*?)\n    \}}", text, re.S)
  if not m:
    return {}
  return {name: const for name, const in _BIN_RE_C.findall(m.group(1))}


def _enum_value(const: str, prefix: str, enum) -> int:
  """VIP_CHI_REQ_READ_SHARED_C -> ReqOpcode.READ_SHARED. The two ports name the
  same opcode the same way either side of the prefix, which is what makes the
  translation mechanical rather than a second table to maintain."""
  name = const[len(prefix):]
  if name.endswith("_C"):
    name = name[:-2]
  return int(getattr(enum, name))


def main() -> int:
  text = open(_CHECKER_C).read()
  cg = _covergroup_body(text, "cg_req_snp_pairing")
  if not cg:
    print("cg_req_snp_pairing not found in the coherency checker")
    return 1

  req_bins = _coverpoint_bins(cg, "cp_req")
  snp_bins = _coverpoint_bins(cg, "cp_snp")
  if not req_bins or not snp_bins:
    print("cp_req or cp_snp bins did not parse")
    return 1

  classes = {}
  for m in re.finditer(r"illegal_bins\s+(\w+)\s*=\s*(.*?);", cg, re.S):
    name, body = m.group(1), m.group(2)
    reqs = [b for b in re.findall(r"binsof\(cp_req\.(\w+)\)", body) if b in req_bins]
    snps = [b for b in re.findall(r"binsof\(cp_snp\.(\w+)\)", body) if b in snp_bins]
    classes[name] = (reqs, snps)

  if not classes:
    print("no illegal_bins parsed from cg_req_snp_pairing")
    return 1

  print(f"cp_req bins: {len(req_bins)}   cp_snp bins: {len(snp_bins)}")
  print(f"illegal_bins classes: {len(classes)}")
  print()

  rc = 0
  for name, (reqs, snps) in sorted(classes.items()):
    pairs = 0
    bad = []
    for rb in reqs:
      rv = _enum_value(req_bins[rb], "VIP_CHI_REQ_", ReqOpcode)
      for sb in snps:
        sv = _enum_value(snp_bins[sb], "VIP_CHI_SNP_", SnpOpcode)
        pairs += 1
        # A request that generates no snoop at all cannot reach this cross: D8
        # reports it on the earlier arm and returns before sampling.
        if req_generates_snoop(rv) and snoop_permitted_for_req(rv, sv):
          bad.append(f"{rb} x {sb}")
    if bad:
      rc = 1
      print(f"  FAIL {name}: {len(bad)} pairing(s) the table PERMITS")
      for pair in bad:
        print(f"         {pair}")
    else:
      print(f"  ok   {name}: {pairs} pairing(s), every one rejected by the table")

  print()
  if rc == 0:
    print("every illegal bin names a pairing Table 4-5 forbids")
  else:
    print("an illegal bin claims a permitted pairing -- conformant traffic "
          "would end the run with no UVM error in the log")
  return rc


if __name__ == "__main__":
  sys.exit(main())
