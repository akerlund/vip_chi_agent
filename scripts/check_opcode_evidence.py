#!/usr/bin/env python3
################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
################################################################################
#
# The per-opcode evidence axis: an opcode the regression DRIVES that no
# classifier CLAIMS.
#
# Eight classifier functions gate the REQ-derived checks by opcode, each with a
# twin in the other port. An opcode outside all of them makes every gated rule
# stand down for it -- silently, because the rules keep accumulating passes from
# the opcodes they do claim, and the tally CSV is keyed (run, bind, check) with
# no opcode dimension at all. A check can therefore be enabled, healthy in every
# artifact, and structurally incapable of evaluating for part of its own domain.
# That has happened twice, to the same opcode family, and both times a human
# found it.
#
# WHY IT TAKES TWO HALVES, one static and one from a run:
#
#   * check_classifier_coverage.py answers which opcodes are CLAIMED. The
#     classifiers are pure functions of the opcode, so that answer needs no
#     simulation -- and on its own it is theoretical, because an opcode nothing
#     drives costs nothing however it is classified. Its unclaimed list is four
#     opcodes today and all four are correct.
#   * The sweep answers which opcodes are DRIVEN. On its own that is just a
#     census.
#
# The join is the finding: driven AND unclaimed means every gated rule stood
# down for traffic that really went out. Adding an opcode family stops being a
# silent, distributed edit -- the moment a test drives it, this fails until
# somebody classifies it.
#
# UNCLAIMED_BY_DESIGN in check_classifier_coverage.py is the recorded-decision
# list, reused rather than restated: ReqLCrdReturn and PCrdReturn are driven and
# correctly claimed by nothing, since neither carries a transaction.
#
# Usage:
#   check_opcode_evidence.py <opcode_evidence.csv> [more.csv ...]
#
# Exit 1 when a driven opcode is claimed by no classifier and is not a recorded
# exception.
#
################################################################################

from __future__ import annotations

import collections
import csv
import os
import sys

_HERE_C = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE_C)

from check_classifier_coverage import (  # noqa: E402
  UNCLAIMED_BY_DESIGN, claimed_opcode_set)


def driven(paths: list[str]) -> tuple[dict[int, int], dict[int, set[str]]]:
  """opcode -> flits seen, and opcode -> the binds that saw it.

  Last row wins per (run, bind, opcode): the Python export appends, so a second
  sweep's rows sit on top of the first and summing would double-count. The same
  hazard the tally parity gate documents.
  """
  last: dict[tuple[str, str, int], int] = {}
  for path in paths:
    with open(path, encoding="utf-8") as fh:
      for row in csv.DictReader(fh):
        last[(row["run"], row["bind"], int(row["opcode"], 16))] = int(row["seen"])
  seen: dict[int, int] = collections.defaultdict(int)
  where: dict[int, set[str]] = collections.defaultdict(set)
  for (_run, bind, opcode), n in last.items():
    seen[opcode] += n
    where[opcode].add(bind)
  return seen, where


def main(argv: list[str]) -> int:
  if len(argv) < 2:
    print(__doc__)
    return 2

  paths = [p for p in argv[1:] if os.path.exists(p)]
  if not paths:
    print(f"opcode evidence: no CSV at {', '.join(argv[1:])}; "
          f"run a sweep first")
    return 0

  all_ops, claimed, names = claimed_opcode_set()
  seen, where = driven(paths)

  unclaimed_driven = sorted(o for o in seen if o in all_ops and o not in claimed)
  modeled_undriven = sorted(o for o in all_ops if o not in seen)

  print(f"opcodes driven: {len(seen)}   modeled: {len(all_ops)}   "
        f"claimed by some classifier: {len(claimed)}")

  bad = []
  for o in unclaimed_driven:
    if o in UNCLAIMED_BY_DESIGN:
      print(f"  stated: {names.get(o, '?')} (0x{o:02x}) driven {seen[o]} time(s), "
            f"claimed by nothing -- {UNCLAIMED_BY_DESIGN[o]}")
    else:
      bad.append(o)

  # Not a failure, and deliberately so: an opcode nothing drives is a stimulus
  # gap, which is check_vacuity's question, not this one. Printed because the
  # two lists are read together -- an opcode that moves from here to the list
  # above is exactly the transition this gate exists to catch.
  if modeled_undriven:
    print(f"\n{len(modeled_undriven)} modeled opcode(s) no run drove "
          f"(not a failure here):")
    print("  " + ", ".join(f"{names.get(o, '?')}" for o in modeled_undriven))

  if bad:
    print(f"\n{len(bad)} opcode(s) DRIVEN but claimed by no classifier:")
    for o in bad:
      binds = ", ".join(sorted(where[o])[:4])
      print(f"  {names.get(o, '?')} (0x{o:02x}): {seen[o]} flit(s) on {binds}")
    print("\n  Every REQ-derived rule stands down for these, while still")
    print("  accumulating passes from the opcodes it does claim -- so no")
    print("  existing artifact reports them as anything but healthy. Classify")
    print("  the opcode in both ports, or record the exception with its reason")
    print("  in UNCLAIMED_BY_DESIGN.")
    return 1

  print("\nevery opcode the regression drives is claimed by some classifier")
  return 0


if __name__ == "__main__":
  sys.exit(main(sys.argv))
