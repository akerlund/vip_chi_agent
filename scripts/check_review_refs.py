#!/usr/bin/env python3
################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
################################################################################
#
# Source comments must not point at the review scaffolding.
#
# Finding IDs (F-CORR-013), trace rows (TR-APPB-001) and box numbers (box 0.3)
# live in review documents that are deleted when a review closes. A comment that
# cites one is unreadable the moment that happens, and unreadable in the
# meantime to anyone who does not have the document open.
#
# The rule is not "say less". It is "say the durable half": keep the
# specification citation -- the section, table or clause -- and drop the finding
# ID and the before/after story that goes with it. A reader needs to know what
# the code does and which clause requires it, not which review noticed that it
# did not.
#
# Two related habits this also catches, for the same reason:
#
#   * a maintained COUNT in a comment ("every one of the 209 regression
#     testcases"), which rots the next time a testcase is added;
#   * narrating a fixed defect ("that was invisible until X existed; now it
#     reports"), which describes a past the reader cannot see from the code.
#
# The count and archaeology checks are heuristic and report as WARN. The
# reference check is exact and fails.
#
# Exit 0 when no source file cites review scaffolding; 1 otherwise.
#
################################################################################

from __future__ import annotations

import pathlib
import re
import sys

_ROOT_C = pathlib.Path(__file__).resolve().parent.parent

_SEARCH_C = ("sv", "py", "scripts", "testbench/sv/tc", "testbench/sv/tb",
             "testbench/py/tc", "testbench/py/tb")
_ALSO_C = ("README.md", "docs/CHI_PRIMER.md", "testbench/TEST_CASES.md")
_SUFFIXES_C = (".sv", ".svh", ".py", ".md", ".sh", ".core")

# Build outputs and vendored copies carry stale extracted sources.
# This file necessarily contains the patterns it hunts for, in the comments
# explaining them and in the regexes themselves.
_SKIP_C = ("rundir", "__pycache__", "/build/", "check_review_refs.py")

# The review scaffolding, exactly. These fail.
#
# The bare-bracket form -- [F1], [fix F2] -- is an OLDER numbering than the
# F-CORR-nnn scheme above, from a review whose document is already gone. It reads
# as a typo rather than as a citation, which is why it survived the sweep that
# removed the rest.
_REF_RE_C = re.compile(
  r"\bF-(?:CORR|CHK|INTOP|COV|DOC)-\d+"
  r"|\bTR-[A-Z]+-\d+"
  r"|\bbox \d+\.\d+"
  r"|\[(?:fix )?F\d+\]")

# What removing one of the above by hand leaves behind: a citation deleted out of
# the middle of a sentence, leaving the punctuation that framed it. Cheap to
# spot mechanically and nearly invisible in review, because the sentence around
# it still scans.
#
# Whole-line comments only, and an EMPTY pair of parentheses is not one of the
# patterns: `reset()` and `is_valid()` are how the comments here name a function,
# and a rule that reports those is turned off the same day it lands. What is
# left is a paren against a comma, a paren with nothing but space inside, or a
# paren with a space before its first word -- none of which anyone types on
# purpose, all of which are what a deleted citation leaves.
_ORPHAN_RE_C = re.compile(r"\(\s*,|,\s*\)|\(\s+\)|\(\s+\w")


def _comment_text(line: str) -> str:
  """The comment on a whole-line comment, or empty for anything else."""
  stripped = line.strip()
  for marker in ("//", "#"):
    if stripped.startswith(marker):
      return stripped[len(marker):]
  return ""

# A count of the whole regression, written where it has to be maintained.
_COUNT_RE_C = re.compile(
  r"\b(?:all|every one of the|each of the)\s+\d{2,4}\s+"
  r"(?:regression\s+)?(?:testcases|tests)\b", re.I)

# Narrating a defect's history rather than describing the code.
_HISTORY_RE_C = re.compile(
  r"\b(?:was|were)\s+invisible\s+until\b"
  r"|\bnow\s+it\s+reports\b"
  r"|\bthis\s+(?:used\s+to|previously)\s+(?:be\s+)?a\s+bug\b", re.I)


def _files():
  for rel in _SEARCH_C:
    base = _ROOT_C / rel
    if not base.is_dir():
      continue
    for p in sorted(base.rglob("*")):
      if p.suffix in _SUFFIXES_C and not any(s in str(p) for s in _SKIP_C):
        yield p
  for rel in _ALSO_C:
    p = _ROOT_C / rel
    if p.is_file():
      yield p


def main() -> int:
  refs, counts, history, orphans = [], [], [], []

  for p in _files():
    try:
      text = p.read_text()
    except (OSError, UnicodeDecodeError):
      continue
    rel = p.relative_to(_ROOT_C).as_posix()
    for n, line in enumerate(text.split("\n"), 1):
      m = _REF_RE_C.search(line)
      if m:
        refs.append((rel, n, m.group(0), line.strip()[:88]))
      if _COUNT_RE_C.search(line):
        counts.append((rel, n, line.strip()[:88]))
      if _HISTORY_RE_C.search(line):
        history.append((rel, n, line.strip()[:88]))
      if _ORPHAN_RE_C.search(_comment_text(line)):
        orphans.append((rel, n, line.strip()[:88]))

  if counts:
    print(f"WARN -- a maintained count in a comment ({len(counts)}):")
    for rel, n, line in counts[:10]:
      print(f"  {rel}:{n}  {line}")
    print("  A number written here has to be updated by hand and will not be.")
    print()

  if history:
    print(f"WARN -- a comment narrating a defect's history ({len(history)}):")
    for rel, n, line in history[:10]:
      print(f"  {rel}:{n}  {line}")
    print("  Describe what the code does, not what it used to do wrong.")
    print()

  if orphans:
    print(f"FAIL -- punctuation left where a citation was removed "
          f"({len(orphans)}):")
    for rel, n, line in orphans[:25]:
      print(f"  {rel}:{n}  {line}")
    print()
    print("  Repair the sentence rather than the punctuation: what is left")
    print("  reads as written prose and nobody re-reads it.")
    print()

  if refs:
    print(f"FAIL -- source comments cite review scaffolding ({len(refs)}):")
    for rel, n, tok, line in refs[:25]:
      print(f"  {rel}:{n}  [{tok}]  {line}")
    if len(refs) > 25:
      print(f"  ... and {len(refs) - 25} more")
    print()
    print("  These IDs live in documents that are deleted when the review")
    print("  closes. Keep the specification citation and drop the ID.")
    return 1

  if orphans:
    return 1

  print("no source comment cites a finding ID, trace row or box number")
  return 0


if __name__ == "__main__":
  sys.exit(main())
