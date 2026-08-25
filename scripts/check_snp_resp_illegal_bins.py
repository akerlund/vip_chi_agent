#!/usr/bin/env python3
################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
################################################################################
#
# cg_snp_resp_legality's illegal_bins are entered twice in vip_chi_coherency_-
# checker.sv, and the duplication is forced rather than chosen.
#
# SystemVerilog gives no way to ask a covergroup whether a sample WOULD land in
# an illegal bin, and the hit is unrecoverable -- VCS treats it as a verification
# error and ends the simulation, before the UVM report summary a regression
# script greps for is ever printed. So a negative control that deliberately
# produces an illegal pairing cannot pass unless the sample is skipped, and the
# skip decision has to be made BEFORE sampling. That is what
# snp_resp_hits_illegal_bin() is for: the same three bins, written again as a
# predicate.
#
# Two copies of one rule drift. The failure would be quiet in the worse
# direction: a bin edited in the covergroup and not in the predicate makes a
# negative control unsuppressable again, and it fails as an aborted run with no
# UVM error in the log -- which reads like a simulator problem, not like a stale
# predicate. This compares them.
#
# Exit 0 when the two agree on which (opcode-set, state-set, data) triples are
# illegal; 1 otherwise.
#
################################################################################

from __future__ import annotations

import os
import re
import sys

_HERE_C = os.path.dirname(os.path.abspath(__file__))
_ROOT_C = os.path.dirname(_HERE_C)
_CHECKER_C = os.path.join(_ROOT_C, "sv", "vip_chi_coherency_checker.sv")

# cp_snp / cp_state bin names -> the constant each one holds. Parsed from the
# coverpoints themselves so a renamed bin is a parse miss, not a wrong answer.
_BIN_RE_C = re.compile(r"bins\s+(\w+)\s*=\s*\{([A-Z0-9_]+)\}")


def _coverpoint_bins(text: str, cp: str) -> dict:
  m = re.search(rf"{cp}\s*:\s*coverpoint[^{{]*\{{(.*?)\n    \}}", text, re.S)
  if not m:
    return {}
  return {name: const for name, const in _BIN_RE_C.findall(m.group(1))}


def _covergroup_body(text: str, name: str) -> str:
  """One covergroup's source, so bins from OTHER covergroups are not mixed in.

  The file has more illegal_bins than this one covergroup -- the requester
  transition cross carries its own -- and they are a separate question with the
  same shape: a negative control that hits one of THOSE would abort just as
  unsuppressably. They are out of scope here rather than forgotten; this gate
  answers for the covergroup whose predicate exists.
  """
  start = text.find(f"covergroup {name}")
  if start < 0:
    return ""
  end = text.find("endgroup", start)
  return text[start:end] if end > start else ""


def _illegal_bins(text: str) -> dict:
  """{bin name: (snp constants, state constants, with_data or None)}."""
  snp_bins = _coverpoint_bins(text, "cp_snp")
  state_bins = _coverpoint_bins(text, "cp_state")

  out = {}
  for m in re.finditer(r"illegal_bins\s+(\w+)\s*=\s*(.*?);", text, re.S):
    name, body = m.group(1), m.group(2)
    negated_state = "!binsof(cp_state" in body

    snps = {snp_bins[b] for b in re.findall(r"binsof\(cp_snp\.(\w+)\)", body)
            if b in snp_bins}
    states = {state_bins[b] for b in re.findall(r"binsof\(cp_state\.(\w+)\)", body)
              if b in state_bins}
    data = None
    if re.search(r"binsof\(cp_data\.with_data\)", body):
      data = True
    elif re.search(r"binsof\(cp_data\.no_data\)", body):
      data = False

    out[name] = (snps, states, negated_state, data)
  return out


def _predicate_arms(text: str) -> list:
  """The arms of snp_resp_hits_illegal_bin, in source order."""
  start = text.find("function bit snp_resp_hits_illegal_bin")
  if start < 0:
    return []
  end = text.find("endfunction", start)
  body = text[start:end]

  arms = []
  for m in re.finditer(r"//\s*(\w+)\n(.*?)return 1'b1;", body, re.S):
    name, cond = m.group(1), m.group(2)
    snps = set(re.findall(r"VIP_CHI_SNP_[A-Z0-9_]+_C", cond))
    states = set(re.findall(r"VIP_CHI_RESP_STATE_[A-Z0-9_]+_E", cond))
    negated_state = "state !=" in cond
    data = True if re.search(r"&&\s*with_data", cond) else None
    arms.append((name, snps, states, negated_state, data))
  return arms


def main() -> int:
  text = open(_CHECKER_C).read()
  cg = _covergroup_body(text, "cg_snp_resp_legality")
  if not cg:
    print("cg_snp_resp_legality not found in the coherency checker")
    return 1
  bins = _illegal_bins(cg)
  arms = {a[0]: a[1:] for a in _predicate_arms(text)}

  if not bins:
    print("no illegal_bins parsed from cg_snp_resp_legality")
    return 1
  if not arms:
    print("no arms parsed from snp_resp_hits_illegal_bin")
    return 1

  rc = 0
  print(f"illegal_bins in cg_snp_resp_legality: {len(bins)}")
  print(f"arms in snp_resp_hits_illegal_bin:    {len(arms)}")
  print()

  for name, (snps, states, neg, data) in sorted(bins.items()):
    if name not in arms:
      print(f"  FAIL {name}: no matching arm in the predicate -- a control "
            f"hitting this bin would abort the run unsuppressably")
      rc = 1
      continue
    a_snps, a_states, a_neg, a_data = arms[name]
    why = []
    if snps != a_snps:
      why.append(f"opcodes {sorted(snps)} vs {sorted(a_snps)}")
    if states != a_states:
      why.append(f"states {sorted(states)} vs {sorted(a_states)}")
    if neg != a_neg:
      why.append(f"state sense negated={neg} vs {a_neg}")
    if data != a_data:
      why.append(f"with_data {data} vs {a_data}")
    if why:
      print(f"  FAIL {name}: {'; '.join(why)}")
      rc = 1
    else:
      print(f"  ok   {name}")

  for name in sorted(set(arms) - set(bins)):
    print(f"  FAIL {name}: the predicate suppresses a pairing the covergroup "
          f"does not call illegal -- a real hit would go unrecorded")
    rc = 1

  print()
  print("the covergroup and the predicate agree" if rc == 0
        else "the covergroup and the predicate DISAGREE")
  return rc


if __name__ == "__main__":
  sys.exit(main())
