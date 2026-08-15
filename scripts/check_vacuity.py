#!/usr/bin/env python3
"""Aggregate per-check tallies across a whole regression.

A clean regression is only meaningful if the checks actually ran, and no single
run can tell you which ones did not: a rule that does not apply to one testcase
is unexercised there for a perfectly good reason. The question worth asking is
which rules are unexercised across EVERY run, because those are the ones
indistinguishable from checks that were deleted.

Reads the CSV the checkers append to:

  SV     ./simv +UVM_TESTNAME=<tc> +vip_chi_check_csv=<path>
  Python VIP_CHI_CHECK_CSV=<path> python3 testbench/py/scripts/run.py --all

covering BOTH registries -- the SVA binds' rules and the scoreboard's -- and
reports, in order of how alarming it is:

  NEVER   zero passes and zero fails in every run that evaluated it
  THIN    exercised by only one or two runs -- alive, but one deleted testcase
          away from silently becoming NEVER, which is the state this whole
          mechanism exists to prevent recurring
  FAILING any run recorded a failure

Exits non-zero when anything is NEVER exercised, so a regression can gate on it.
"""

from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path
from collections import defaultdict


THIN_RUN_THRESHOLD_C = 2


def main() -> int:
  ap = argparse.ArgumentParser(description=__doc__,
                               formatter_class=argparse.RawDescriptionHelpFormatter)
  ap.add_argument("csv", nargs="+", help="check-tally CSV file(s) to aggregate")
  ap.add_argument("--thin", type=int, default=THIN_RUN_THRESHOLD_C,
                  help=f"flag rules exercised by <= N runs (default {THIN_RUN_THRESHOLD_C})")
  ap.add_argument("--allow-never", action="store_true",
                  help="report but do not fail when a rule is never exercised")
  args = ap.parse_args()

  passes = defaultdict(int)
  fails = defaultdict(int)
  deliberate = defaultdict(int)
  runs_exercising = defaultdict(set)
  disabled_everywhere = defaultdict(lambda: True)
  known = []

  for path in args.csv:
    try:
      with open(path, newline="", encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
          rule = row["check"]
          if rule not in passes and rule not in fails:
            known.append(rule)
          p, f = int(row["passes"]), int(row["fails"])
          passes[rule] += p
          # A failure recorded at severity OFF or WARNING was provoked on
          # purpose -- that is how a negative control proves its rule fires --
          # so it counts as EXERCISED but not as a regression failure. Counting
          # it as one would make every negative control look like a bug.
          if row["severity"] == "ERROR":
            fails[rule] += f
          else:
            deliberate[rule] += f
          if row["enabled"] == "1":
            disabled_everywhere[rule] = False
          if p or f:
            runs_exercising[rule].add(row["run"])
    except FileNotFoundError:
      print(f"error: no such file: {path}", file=sys.stderr)
      return 2

  if not known:
    print("error: no rows found -- was the CSV export enabled?", file=sys.stderr)
    return 2

  # Preserve first-seen order, which is registry order in both ports.
  seen = set()
  rules = [r for r in known if not (r in seen or seen.add(r))]

  # Rules the CANONICAL registry knows about that no row mentioned at all.
  #
  # This is not the same thing as NEVER EXERCISED, and conflating the two is how
  # the report lied for as long as it existed. A never-exercised rule has rows
  # saying zero; an unexported one has no rows, so a summary built from the rows
  # cannot see it and prints a total that reads as the whole registry. Until the
  # coherent env exported, the seven SNP rules were in this state -- a report
  # covering two of fourteen binds presented as a report on all of them.
  #
  # Read from the Python registry rather than a copy, so a rule added to the
  # types package cannot go missing here.
  #
  # An absence is split in two, because only one of them is a problem. A rule the
  # Python port cannot own -- the X/Z rules, which Verilator's 2-state model can
  # never evaluate -- is absent BY DESIGN and is recorded as such in
  # CHECK_IDS_SV_ONLY. Gating on those would fail every Python sweep forever and
  # teach the reader to pass --allow-never, which would hide the real holes too.
  #
  # BOTH registries are read: the SVA binds' rules and the scoreboard's. They are
  # separate enums -- the SVA IDs size per-interface arrays, while a scoreboard
  # rule is judged once per component -- but they share this CSV schema, which is
  # what lets one aggregation read them and gate on them alike. Scoreboard checks
  # were outside this mechanism entirely until they were given names, so one
  # could stop evaluating and nothing anywhere would say so.
  unexported, by_design = [], []
  try:
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "py"))
    from vip_chi_types_pkg import CHECK_IDS, CHECK_IDS_SV_ONLY, CHECK_IDS_SB
    for rule in tuple(CHECK_IDS) + tuple(CHECK_IDS_SB):
      if rule in seen:
        continue
      if rule in CHECK_IDS_SV_ONLY:
        by_design.append((rule, CHECK_IDS_SV_ONLY[rule]))
      else:
        unexported.append(rule)
  except Exception as exc:                                # pragma: no cover
    print(f"warning: could not read the canonical registry ({exc}); "
          f"cannot tell an unexported rule from a missing one", file=sys.stderr)

  never, thin, failing = [], [], []
  for rule in rules:
    n_runs = len(runs_exercising[rule])
    if fails[rule]:
      failing.append((rule, fails[rule]))
    if n_runs == 0:
      never.append((rule, disabled_everywhere[rule]))
    elif n_runs <= args.thin:
      thin.append((rule, n_runs, sorted(runs_exercising[rule])))

  print(f"checks: {len(rules)}   runs: "
        f"{len({r for s in runs_exercising.values() for r in s})}")

  if failing:
    print(f"\nFAILING ({len(failing)}):")
    for rule, n in failing:
      print(f"  {rule:<44s} {n} failure(s)")

  provoked = [(r, deliberate[r]) for r in rules if deliberate[r]]
  if provoked:
    print(f"\nPROVOKED -- failures a negative control asked for ({len(provoked)}):")
    for rule, n in provoked:
      print(f"  {rule:<44s} {n}")

  if unexported:
    print(f"\nNOT EXPORTED -- no bind wrote a row, so nothing is known about "
          f"them ({len(unexported)}):")
    for rule in unexported:
      print(f"  {rule}")

  if by_design:
    print(f"\nabsent by design ({len(by_design)}): "
          + ", ".join(r for r, _ in by_design))
    print(f"  reason: {by_design[0][1]}")

  if never:
    print(f"\nNEVER EXERCISED ({len(never)}):")
    for rule, was_disabled in never:
      why = "  (disabled in every run)" if was_disabled else ""
      print(f"  {rule}{why}")

  if thin:
    print(f"\nTHIN -- exercised by <= {args.thin} run(s) ({len(thin)}):")
    for rule, n, where in thin:
      print(f"  {rule:<44s} {n}: {', '.join(where)}")

  if not never and not thin and not failing and not unexported:
    print("\nevery check in both registries was exported, exercised by more "
          f"than {args.thin} run(s), and none failed")

  # A rule disabled in every run was not exercised BY REQUEST, so it is reported
  # but does not gate: failing on it would punish the user for using the feature.
  gating = [r for r, was_disabled in never if not was_disabled]
  if (gating or unexported) and not args.allow_never:
    return 1
  return 0


if __name__ == "__main__":
  sys.exit(main())
