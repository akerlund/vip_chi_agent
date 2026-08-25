#!/usr/bin/env python3
"""Compare, per testcase and per rule, WHICH port reported a failure.

The gate this closes, stated plainly: nothing else in this repository compares
what the two ports DECIDED about the same stimulus.

  * check_cfg_parity, check_type_parity, check_opcodes and
    check_classifier_coverage compare declarations -- what EXISTS in each port.
  * check_counter_parity compares behaviour, but its own header limits it to the
    `COHERENCY ... SUMMARY:` lines.
  * check_vacuity reads per-check tallies, but each port against its own CSV. It
    answers "is this rule exercised somewhere", never "do the two ports agree".

So a rule could fire in one port and be silent in the other, in the same
testcase, with both numbers printed in both sweeps, and every gate would pass.
That is not hypothetical: divergences of exactly that shape have been found by
hand, after the fact, on runs the full gate set had just passed clean.

WHAT IS COMPARED, and why it is not the numbers. Fail COUNTS are not comparable
between the ports, because the two express some rules at different granularity:
CHI_LCRD_QUIESCENT_IN_STOP is two properties in SystemVerilog (one per machine)
and six per-pool checks in Python, so one stranded credit is 1 report there and 3
here. Comparing counts would produce noise on every such rule and the check would
be turned off within a week.

What IS comparable is the BOOLEAN: did this rule fire at all, in this testcase,
in this port. That is the question a divergence hides in, and it is granularity
independent.

Bind names are deliberately NOT part of the key. The two ports do not name every
bind identically and a rule can legitimately land on a different vantage; the
testcase is the unit of stimulus, so (run, check) is the unit of comparison.

Usage:
  check_tally_parity.py <sv_tallies.csv> <py_tallies.csv>

Exit 1 on any unexplained divergence.
"""
from __future__ import annotations

import csv
import os
import sys

# Rules whose firing legitimately differs between the ports, each with the
# reason. An entry here is a RECORDED DECISION, not a silencer -- it must name
# why the two ports cannot agree, and anything not listed is a finding.
#
# An entry that no longer diverges is reported too, and exits 1. A table of
# exceptions nobody prunes is how a gate stops meaning anything: the entry would
# go on excusing a divergence that had been fixed, and would keep excusing the
# next one to appear under the same rule name.
EXPECTED_C: dict[str, str] = {}

# Rules one port does not implement at all. Read from the Python registry so this
# cannot drift from the port itself.
def sv_only_rules() -> set[str]:
    here = os.path.dirname(os.path.abspath(__file__))
    py = os.path.join(here, "..", "py", "vip_chi_types_pkg.py")
    names: set[str] = set()
    try:
        src = open(py, encoding="utf-8").read()
    except OSError:
        return names
    marker = "CHECK_IDS_SV_ONLY"
    if marker not in src:
        return names
    tail = src[src.index(marker):]
    end = tail.index("}") if "}" in tail else len(tail)
    for line in tail[:end].splitlines():
        line = line.strip()
        if line.startswith('"'):
            names.add(line.split('"')[1])
    return names


def fired(path: str) -> tuple[dict[tuple[str, str], int], set[str], set[str]]:
    """(run, check) -> fails, plus the runs and checks the file knows about.

    Last occurrence per (run, bind, check) wins: the Python tally file is opened
    in APPEND mode, so a second sweep's rows sit on top of the first and a naive
    sum double-counts.
    """
    last: dict[tuple[str, str, str], dict] = {}
    with open(path, encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
            last[(row["run"], row["bind"], row["check"])] = row
    out: dict[tuple[str, str], int] = {}
    runs: set[str] = set()
    checks: set[str] = set()
    for (run, _bind, check), row in last.items():
        runs.add(run)
        checks.add(check)
        out[(run, check)] = out.get((run, check), 0) + int(row["fails"])
    return out, runs, checks


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__)
        return 2
    sv, sv_runs, sv_checks = fired(argv[1])
    py, py_runs, py_checks = fired(argv[2])

    # Only testcases and rules BOTH ports ran can be compared. A test that exists
    # in one port only is check_test_counts' business, and a rule one port does
    # not implement is a recorded decision in the registry.
    runs = sv_runs & py_runs
    checks = (sv_checks & py_checks) - sv_only_rules()

    print(f"runs compared: {len(runs)}   rules compared: {len(checks)}")
    only_sv = sorted(sv_runs - py_runs)
    only_py = sorted(py_runs - sv_runs)
    for name in only_sv:
        print(f"  run in SV only, not compared: {name}")
    for name in only_py:
        print(f"  run in Python only, not compared: {name}")

    diffs = []
    used: set[str] = set()
    for run in sorted(runs):
        for check in sorted(checks):
            s = sv.get((run, check), 0) > 0
            p = py.get((run, check), 0) > 0
            if s == p:
                continue
            if check in EXPECTED_C:
                used.add(check)
                print(f"  stated: {check} in {run} -- {EXPECTED_C[check]}")
                continue
            where = "SV only" if s else "Python only"
            diffs.append((run, check, where,
                          sv.get((run, check), 0), py.get((run, check), 0)))

    stale = sorted(set(EXPECTED_C) - used)

    if not diffs and not stale:
        print("\nevery rule that fires in one port fires in the other, "
              "on every shared testcase")
        return 0

    if diffs:
        print(f"\n{len(diffs)} rule(s) fired in one port and not the other:")
        for run, check, where, sn, pn in diffs:
            print(f"  {check}\n      {run}: {where}  "
                  f"(SV {sn} fail(s), Python {pn})")

    if stale:
        print(f"\n{len(stale)} stated exception(s) no longer divergent -- "
              f"delete the entry:")
        for check in stale:
            print(f"  {check}")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
