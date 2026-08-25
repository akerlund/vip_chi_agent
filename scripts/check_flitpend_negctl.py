#!/usr/bin/env python3
################################################################################
#
# Every driver that announces a flit must honour cfg.flit_without_flitpend.
#
# FLITPEND is a one-cycle look-ahead (E section 14.4 / D section 13.4), and
# CHI_*_VALID_REQUIRES_PEND is the rule that a flit never goes out without it.
# cfg.flit_without_flitpend is the only stimulus in the repository that makes
# that rule fail, so a driver the knob does not reach is a driver whose
# announcement path is never proven to be checked at all.
#
# The knob reached the two requesters and nothing else. Both homes announced
# INLINE -- eleven send sites assigning FLITPEND directly rather than calling a
# helper -- and neither SN-F consulted it. check_cfg_parity.py passed throughout,
# because the field exists in both ports spelled the same way; which drivers READ
# it is behaviour, and no gate compared that. See F-CHK-014.
#
# What this checks, per driver file that announces a flit at all:
#
#   1. it references cfg.flit_without_flitpend somewhere, and
#   2. every announcement site is inside the helper that consults it -- counted
#      as "at most one announcement site outside the helper", the helper itself.
#
# Rule 2 is what stops the gate being satisfied by adding the knob to a helper
# nobody calls. A driver that announces in six places and reads the knob in one
# of them passes rule 1 and fails rule 2, which is exactly the state this
# finding found.
#
################################################################################

from __future__ import annotations

import re
import sys
from pathlib import Path

_ROOT_C = Path(__file__).resolve().parent.parent
_KNOB_C = "flit_without_flitpend"

# A driver ANNOUNCES a flit when it drives a FLITPEND high on its own, one cycle
# ahead. The two ports spell that differently and both spellings are matched here
# rather than normalised, because a normaliser is one more thing that can
# silently stop matching.
_SV_ANNOUNCE_C = re.compile(r"tx\w*flitpend\s*<=\s*1'b1")
_PY_ANNOUNCE_C = re.compile(r"tx\{?\w*\}?flitpend[\"']?\s*[:=]\s*1\b")

# The same signal is driven for two other reasons, and neither is an
# announcement. Getting this wrong makes the gate noisy, and a noisy gate is
# worse than no gate -- so each exclusion is a property of the drive itself, not
# a file or a line number that can drift:
#
#   1. WITH the flit. A burst sets FLITPEND alongside FLITV to mean "more beats
#      follow" (E section 14.4), which is a different meaning at a different
#      cycle from the one-cycle lead. Recognised by FLITV on the same statement.
#   2. AS a sideband pattern, by ANOTHER negative control. Three of them drive
#      FLITPEND deliberately and none is announcing a flit:
#      cfg.reset_permitted_high and cfg.reset_idle_violation drive it during
#      reset to provoke CHI_*_IDLE_IN_RESET, and cfg.flitpend_without_valid
#      raises it with no flit behind it at all. Recognised by the enclosing
#      `cfg.<knob>` guard -- these sites exist BECAUSE a knob asked for them, so
#      the guard is the most durable thing about them.
_WITH_FLIT_C = re.compile(r"flitv")
_MULTI_CHANNEL_C = re.compile(r"tx\w*flitpend[^,;)]*[,;].{0,80}?tx\w*flitpend")
_RAW_EXEMPT_C = re.compile(r"raw_flitpend|flitpend.*:\s*flitpend\b")

# How far back to look for the guard. Small on purpose: a knob whose block is
# longer than this is a block doing more than driving a sideband pattern.
_GUARD_LOOKBACK_C = 10
_GUARD_C = re.compile(r"\bcfg\.(\w+)")


def _under_other_control(lines: list[str], start: int) -> bool:
  """TRUE when this site sits inside an `if (cfg.<knob>)` for another control."""
  for k in range(max(0, start - _GUARD_LOOKBACK_C), start):
    line = lines[k]
    if "if" not in line:
      continue
    match = _GUARD_C.search(line)
    if match and match.group(1) != _KNOB_C:
      return True
  return False


def _sites(text: str, pattern: re.Pattern) -> list[int]:
  """Announcement lines, LOGICAL rather than physical.

  A multi-channel sideband drive may be wrapped across lines, so the exclusion
  has to see the whole statement. Lines are joined forward while brackets are
  unbalanced, and the site is reported at the line the drive starts on.
  """
  sites: list[int] = []
  lines = text.splitlines()
  index = 0
  while index < len(lines):
    statement = lines[index]
    start = index
    while (statement.count("(") > statement.count(")")
           and index + 1 < len(lines)):
      index += 1
      statement += " " + lines[index].strip()
    if (pattern.search(statement)
        and not _RAW_EXEMPT_C.search(statement)
        and not _WITH_FLIT_C.search(statement)
        and not _MULTI_CHANNEL_C.search(statement)
        and not _under_other_control(lines, start)):
      sites.append(start + 1)
    index += 1
  return sites


# An announce helper is any `announce_*flit*`, not the one exact name: a driver
# with two link directions legitimately has two (the HN-F announces to its RNs
# and to its SNs on separate buses), and a gate that insisted on one name would
# push those toward a single helper that has to be told which bus it is on --
# worse code to satisfy the checker.
_SV_HELPER_C = re.compile(r"task\s+(announce_\w*flit\w*)\b")
_PY_HELPER_C = re.compile(r"def\s+(announce_\w*flit\w*)\b")


def _helper_spans(text: str, port: str) -> list[tuple[int, int]]:
  """Line ranges of every announce helper in the file."""
  lines = text.splitlines()
  spans: list[tuple[int, int]] = []
  pattern = _SV_HELPER_C if port == "sv" else _PY_HELPER_C
  for i, line in enumerate(lines):
    if not pattern.search(line):
      continue
    if port == "sv":
      for j in range(i, len(lines)):
        if re.match(r"\s*endtask", lines[j]):
          spans.append((i + 1, j + 1))
          break
    else:
      indent = len(lines[i]) - len(lines[i].lstrip())
      end = len(lines)
      for j in range(i + 1, len(lines)):
        stripped = lines[j].strip()
        if stripped and (len(lines[j]) - len(lines[j].lstrip())) <= indent:
          end = j
          break
      spans.append((i + 1, end))
  return spans


def main() -> int:
  problems: list[str] = []
  checked = 0

  for port, glob, pattern in (("sv", "sv/vip_chi_driver_*.sv", _SV_ANNOUNCE_C),
                              ("py", "py/vip_chi_driver_*.py", _PY_ANNOUNCE_C)):
    for path in sorted(_ROOT_C.glob(glob)):
      text = path.read_text()
      sites = _sites(text, pattern)
      if not sites:
        continue
      checked += 1
      rel = path.relative_to(_ROOT_C)

      if _KNOB_C not in text:
        problems.append(
          f"{rel}: announces a flit at {len(sites)} site(s) and never reads "
          f"cfg.{_KNOB_C}, so CHI_*_VALID_REQUIRES_PEND cannot be shown to "
          f"fire on this driver's flits")
        continue

      spans = _helper_spans(text, port)
      if not spans:
        problems.append(
          f"{rel}: reads cfg.{_KNOB_C} but has no announce helper, so there is "
          f"nothing holding its {len(sites)} announcement site(s) together")
        continue

      outside = [n for n in sites
                 if not any(lo <= n <= hi for lo, hi in spans)]
      if outside:
        problems.append(
          f"{rel}: {len(outside)} announcement site(s) bypass the announce "
          f"helper(s) (lines {', '.join(str(n) for n in outside)}), so the "
          f"control reaches only the flits that go through them")

      print(f"  ok   {rel}: {len(sites)} announcement site(s) in "
            f"{len(spans)} helper(s), knob honoured")

  if not checked:
    print("no driver announces a flit -- the pattern has stopped matching")
    return 1

  if problems:
    print()
    for problem in problems:
      print(f"  {problem}")
    print(f"\nFAILED: {len(problems)} driver(s) the FLITPEND control cannot reach")
    return 1

  print(f"\nevery driver that announces a flit ({checked}) routes it through a "
        f"helper honouring cfg.{_KNOB_C}")
  return 0


if __name__ == "__main__":
  sys.exit(main())
