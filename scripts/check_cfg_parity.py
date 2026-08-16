#!/usr/bin/env python3
"""Check that the agent-config fields exist under the same name in both ports.

README.md states, above the configuration table: "Every field below exists under
the same name in the Python port unless the row says otherwise." That is a
parity claim about a public API surface, and nothing enforced it. A field present
in SV and absent in Python is a test that configures a knob in one flow and
silently does not in the other -- the run still passes, having exercised a
different scenario than the one it names.

Reports:

  SV_ONLY    declared on vip_chi_cfg_agent.sv, absent from vip_chi_cfg_agent.py
  PY_ONLY    the reverse

Known-and-stated exceptions live in EXPECTED_SV_ONLY below, each with the reason
README gives. Anything else is unrecorded drift.

Fails closed: too few fields parsed from either side means the parser broke, not
that the config is empty.

Companion to `check_type_parity.py`, which already covers the check-ID
registries, the non-opcode enums and the flit field order. This one covers the
agent-config surface those checks do not reach.

Usage:
  python3 scripts/check_cfg_parity.py
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
SV_CFG = ROOT / "sv" / "vip_chi_cfg_agent.sv"
PY_CFG = ROOT / "py" / "vip_chi_cfg_agent.py"

# Minimum plausible field count. The config carries dozens of knobs; a parse
# yielding fewer than this has failed, and a "clean" report would be a lie.
MIN_FIELDS = 40

# Divergences README states explicitly -- the config table's Reporting row, which
# writes them in brace shorthand as `{req,rsp,dat}_verbosity`. Keep the reason
# with the name so this list stays a record of decisions rather than a snooze
# button.
EXPECTED_SV_ONLY = {
  "req_verbosity": "SV only; Python prints through pyUVM's own logger",
  "rsp_verbosity": "SV only; Python prints through pyUVM's own logger",
  "dat_verbosity": "SV only; Python prints through pyUVM's own logger",
}

# SV class-member declarations: `<type> <name> = <init>;` or `<type> <name>;`,
# skipping functions, tasks, constraints and the class header itself.
#
# The type is one-or-more words, not one. SystemVerilog types are routinely two
# (`int unsigned`, `bit signed`, `longint unsigned`), and a single-word type
# pattern silently drops every field declared that way -- 19 of them here, which
# then surface as confident PY_ONLY findings.
SV_FIELD = re.compile(
  r"^\s{2}(?!(?:function|task|constraint|endclass|class|extern|typedef|import|`)\b)"
  r"(?:rand\s+|randc\s+|local\s+|protected\s+)*"
  r"(?:[A-Za-z_][\w:]*(?:\s*#\s*\([^)]*\))?(?:\s*\[[^\]]*\])?\s+)+"
  r"([a-z_]\w*)\s*(?:\[[^\]]*\]\s*)?(?:=|;)"
)

PY_FIELD = re.compile(r"^\s+self\.([a-z_]\w*)\s*(?::[^=]+)?=")


def parse(path: pathlib.Path, pattern: re.Pattern, skip: set[str]) -> set[str]:
  names: set[str] = set()
  for raw in path.read_text().splitlines():
    line = raw.split("//", 1)[0] if path.suffix == ".sv" else raw.split("#", 1)[0]
    m = pattern.match(line)
    if m and m.group(1) not in skip:
      names.add(m.group(1))
  return names


def main() -> int:
  sv = parse(SV_CFG, SV_FIELD, skip={"new"})
  py = parse(PY_CFG, PY_FIELD, skip={"name", "logger"})

  if len(sv) < MIN_FIELDS or len(py) < MIN_FIELDS:
    print(f"INCONCLUSIVE: parsed SV={len(sv)} PY={len(py)}, expected >= {MIN_FIELDS} "
          "on both -- the field regex no longer matches the source", file=sys.stderr)
    return 2

  # An absolute floor is not enough on its own: a parse can clear it and still be
  # missing a quarter of the fields, which then reads as a pile of real findings.
  # A large asymmetry is far more likely to be a broken pattern than genuine
  # drift on a surface both ports are meant to mirror.
  worst, best = sorted((len(sv), len(py)))
  if worst < 0.85 * best:
    print(f"INCONCLUSIVE: parsed SV={len(sv)} PY={len(py)} -- a gap that large on a "
          "mirrored surface means one pattern is missing a declaration form, not "
          "that the ports diverged. Fix the parser before reading the diff.",
          file=sys.stderr)
    return 2

  sv_only = sorted(sv - py)
  py_only = sorted(py - sv)

  print(f"cfg fields: SV {len(sv)}, Python {len(py)}, common {len(sv & py)}")

  problems: list[str] = []
  for name in sv_only:
    if name in EXPECTED_SV_ONLY:
      print(f"  stated: {name} -- {EXPECTED_SV_ONLY[name]}")
    else:
      problems.append(f"SV_ONLY  {name}")
  for name in py_only:
    problems.append(f"PY_ONLY  {name}")

  if problems:
    print()
    for line in problems:
      print(line)
    print(f"\n{len(problems)} field(s) present in one port only and not stated")
    return 1

  print("\nevery config field exists in both ports, or is a stated exception")
  return 0


if __name__ == "__main__":
  sys.exit(main())
