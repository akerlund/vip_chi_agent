#!/usr/bin/env python3
"""Check that the regression sizes quoted in prose match the tree.

`docs/FUTURE_WORK.md` opens by asserting the charter is complete and evidencing
it with a regression size. A number in prose has no way to notice that testcases
were added, so it decays silently -- and a stale one makes the green verdict it
supports unattributable to any state the reader can check. It went stale by
twenty-odd testcases before anyone noticed.

This compares the numbers written in the documents against the testcases that
actually exist, and reports the difference between the two flows so the "same
list on both flows" claim stays honest about its one documented exception.

Fails closed: a document whose count sentence no longer parses is reported as a
broken check, not as agreement.

Usage:
  python3 scripts/check_test_counts.py
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]

SV_TC_DIR = ROOT / "testbench" / "sv" / "tc"
PY_TC_DIR = ROOT / "testbench" / "py" / "tc"
SV_PKG = SV_TC_DIR / "chi_tc_pkg.sv"

# Each entry: path, and a pattern whose two groups are the SV and PY counts.
CLAIMS = (
  (ROOT / "docs" / "FUTURE_WORK.md",
   re.compile(r"\*\*(\d+)\s+SV\s*\+\s*(\d+)\s+PY\*\*")),
  # TEST_CASES.md states the same pair in prose, and states that it is
  # maintained by hand as part of adding a testcase. It was stale too, by one,
  # and the first version of this check did not look at it -- a checker that
  # covers some of the copies of a number leaves the rest free to rot.
  (ROOT / "testbench" / "TEST_CASES.md",
   re.compile(r"\*\*(\d+)\s+SystemVerilog\*\*\s+testcases.*?\*\*(\d+)\s+pyUVM",
              re.S)),
  # The README's feature snapshot quotes the same pair. It is the first thing a
  # reader sees and the last thing anyone thinks to update, which is the worst
  # combination a hand-maintained number can have.
  (ROOT / "README.md",
   re.compile(r"\*\*(\d+)\s+SystemVerilog\*\*\s+testcases.*?\*\*(\d+)\s+pyUVM",
              re.S)),
)

# Documents that quote a single bare count of the whole regression.
#
# Empty on purpose. A count written into a source comment has to be maintained
# by hand and rots the next time a testcase is added, so the comments say "the
# whole regression" instead and there is nothing here to check. The tuple stays
# because the prose documents below still quote counts, and those are the right
# place for a number: they are about the regression, not about the code they sit
# in.
SINGLE_COUNT_CLAIMS = ()


def _tc_names(directory: pathlib.Path, suffix: str) -> set[str]:
  return {p.stem for p in directory.glob(f"tc_*{suffix}")}


def main() -> int:
  sv = _tc_names(SV_TC_DIR, ".sv")
  py = _tc_names(PY_TC_DIR, ".py")

  if not sv or not py:
    print(f"INCONCLUSIVE: found SV={len(sv)} PY={len(py)} testcases -- the "
          "testcase directories moved or the glob no longer matches",
          file=sys.stderr)
    return 2

  # A testcase file the package never includes is not in the regression: the
  # simulator image has no such test, so counting the file would overstate it.
  pkg_text = SV_PKG.read_text()
  unregistered = sorted(n for n in sv if f'"{n}.sv"' not in pkg_text)
  if unregistered:
    print(f"{len(unregistered)} SV testcase file(s) not included by "
          f"{SV_PKG.relative_to(ROOT)}:")
    for name in unregistered:
      print(f"  {name}")
    return 1

  print(f"testcases on disk: SV {len(sv)}, Python {len(py)}")

  sv_only = sorted(sv - py)
  py_only = sorted(py - sv)
  for name in sv_only:
    print(f"  SV only: {name}")
  for name in py_only:
    print(f"  Python only: {name}")

  problems: list[str] = []

  for path, pattern in CLAIMS:
    match = pattern.search(path.read_text())
    if match is None:
      problems.append(
        f"{path.relative_to(ROOT)}: no 'N SV + N PY' count sentence found -- "
        "either it was reworded or this check needs updating")
      continue
    claimed_sv, claimed_py = int(match.group(1)), int(match.group(2))
    if (claimed_sv, claimed_py) != (len(sv), len(py)):
      problems.append(
        f"{path.relative_to(ROOT)}: claims {claimed_sv} SV + {claimed_py} PY, "
        f"tree has {len(sv)} SV + {len(py)} PY")

  for path, pattern in SINGLE_COUNT_CLAIMS:
    match = pattern.search(path.read_text())
    if match is None:
      problems.append(
        f"{path.relative_to(ROOT)}: no regression-count sentence found -- "
        "either it was reworded or this check needs updating")
      continue
    claimed = int(match.group(1))
    # This one is a Python-flow statement, so it is the Python count.
    if claimed != len(py):
      problems.append(
        f"{path.relative_to(ROOT)}: claims {claimed} regression testcases, "
        f"the Python flow has {len(py)}")

  if problems:
    print()
    for line in problems:
      print(line)
    print(f"\n{len(problems)} stale regression count(s)")
    return 1

  print("\nevery documented regression count matches the tree")
  return 0


if __name__ == "__main__":
  sys.exit(main())
