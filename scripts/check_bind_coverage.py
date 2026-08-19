#!/usr/bin/env python3
"""Every live link carries a checker, and every checker reports somewhere.

This is the generalization of the defect F-CHK-002 and F-CHK-004 are two
instances of, one level apart. F-CHK-002 was a bind that existed and was
disabled: it still exported rows saying `enabled=0`, so the information was
present and merely unread. F-CHK-004 was worse in the one way that matters --
sixteen live interfaces with no bind at all, exporting nothing, across twelve
testcases. `check_vacuity.py` aggregates over exported rows, and **an aggregation
over rows cannot report the absence of rows**. A report covering the binds that
existed read as a report on all of them.

So this check does not read the rows. It reads the harness, and then asks the
rows whether they cover it:

  1. Every `vip_chi_if` instance in the SV top, and every `chi_link_adapter` that
     joins two of them. An interface no adapter names is not a live link -- the
     three deliberately unconnected compile anchors are exactly that, and they
     drop out without needing to be listed.
  2. Every `vip_chi_sva` / `vip_chi_snp_sva` bind and the interface it names.
  3. The set of bind names that actually wrote rows into the sweep's tally CSV.

and fails when a live interface has no bind, or a bind never wrote a row. The
first catches a topology added without a checker; the second catches a checker
added without an export, which is the half that looks like success.

WAIVED_INTERFACES is the pressure valve, and it is deliberately a table with
reasons rather than a flag: a waiver has to be written down and read by the next
person, and "no bind here" has to be a sentence someone chose to write.

Exit status: 0 clean, 1 a gap. With no tally CSV it reports what it can from the
source alone and exits 0 on the source-only half -- the CSV is a sweep artifact,
and this script is also useful before one exists.
"""

from __future__ import annotations

import argparse
import csv
import os
import re
import sys
from pathlib import Path


ROOT = Path(os.environ.get("CHI_ROOT", Path(__file__).resolve().parents[1]))
TOP = ROOT / "testbench" / "sv" / "tb" / "chi_tb_top.sv"
DEFAULT_CSV = ROOT / "build" / "sv_regression" / "check_tallies.csv"

# Live interfaces that deliberately carry no bind. Each entry is a sentence
# someone chose to write, not a flag someone flipped.
WAIVED_INTERFACES = {
  # (none today: box 0.3 bound every live link, including the A0 pair, which
  # takes a partial bind via HAND_DRIVEN_LINK_P rather than a waiver.)
}

# A bind whose rows are expected to be absent, with the reason. Same discipline
# as above: a bind that reports nowhere is normally the defect this script exists
# to catch, so an exception has to argue for itself.
WAIVED_EXPORTS: dict[str, str] = {}


def _read(path: Path) -> str:
  return path.read_text(encoding="utf-8")


def parse_interfaces(sv: str) -> set[str]:
  """Every vip_chi_if instance name in the top."""
  return set(re.findall(
    r"vip_chi_if\s*#\([^;]*?\)\s*\n\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*\(\.clk", sv))


def parse_live(sv: str) -> set[str]:
  """Interfaces joined into a link by a chi_link_adapter."""
  live: set[str] = set()
  for rn, sn in re.findall(
      r"chi_link_adapter\s+[a-zA-Z_][a-zA-Z0-9_]*\s*\(\s*\.rn\(([a-zA-Z0-9_]+)\)\s*,"
      r"\s*\.sn\(([a-zA-Z0-9_]+)\)\s*\)", sv):
    live.add(rn)
    live.add(sn)
  return live


def parse_binds(sv: str) -> dict[str, str]:
  """Bind instance name -> the interface it observes."""
  binds: dict[str, str] = {}
  for name, vif in re.findall(
      r"vip_chi_(?:snp_)?sva\s*#\([^;]*?\)\s*\n\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*"
      r"\(\.vif\(([a-zA-Z0-9_]+)\)", sv):
    binds[name] = vif
  return binds


def exported_binds(csv_path: Path) -> set[str] | None:
  if not csv_path.is_file():
    return None
  seen: set[str] = set()
  with csv_path.open(newline="", encoding="utf-8") as fh:
    for row in csv.DictReader(fh):
      b = (row.get("bind") or "").strip()
      # The scoreboard registry shares this CSV's schema and files its rows under
      # its own name, which is not an SVA bind instance. Split on the check-name
      # prefix rather than on the bind name: the two registries are told apart by
      # what they check, and a scoreboard rule is the only thing that carries
      # CHI_SB_.
      if b and not (row.get("check") or "").startswith("CHI_SB_"):
        seen.add(b)
  return seen


def main() -> int:
  ap = argparse.ArgumentParser(description=__doc__)
  ap.add_argument("--csv", default=str(DEFAULT_CSV),
                  help="sweep tally CSV (default build/sv_regression/check_tallies.csv)")
  args = ap.parse_args()

  sv = _read(TOP)
  ifaces = parse_interfaces(sv)
  live = parse_live(sv)
  binds = parse_binds(sv)

  # An interface the adapter list names but the declaration list does not is a
  # parse failure, not a finding -- say so rather than reporting a phantom.
  unknown = live - ifaces
  if unknown:
    print(f"PARSE ERROR: adapters name interfaces that were not declared: "
          f"{sorted(unknown)}")
    return 1
  if len(ifaces) < 10 or not live or not binds:
    print(f"PARSE ERROR: implausible census (interfaces={len(ifaces)} "
          f"live={len(live)} binds={len(binds)}); the top's shape changed")
    return 1

  bound_ifaces = set(binds.values())
  anchors = ifaces - live
  print(f"interfaces {len(ifaces)}  live {len(live)}  "
        f"unconnected anchors {len(anchors)}  binds {len(binds)}")

  failures = 0

  unbound = sorted(live - bound_ifaces)
  if unbound:
    print(f"\nlive interfaces carrying NO bind ({len(unbound)}):")
    for name in unbound:
      why = WAIVED_INTERFACES.get(name)
      if why:
        print(f"  ok   {name:22} waived: {why}")
      else:
        print(f"  FAIL {name:22} no vip_chi_sva or vip_chi_snp_sva names it, "
              f"and it is not in WAIVED_INTERFACES")
        failures += 1
  else:
    print("\nevery live interface carries at least one bind")

  seen = exported_binds(Path(args.csv))
  if seen is None:
    print(f"\nno tally CSV at {args.csv}: the export half of this check did not "
          f"run (this is a sweep artifact, not a source fact)")
  else:
    missing = sorted(b for b in binds if b not in seen)
    if missing:
      print(f"\nbinds that wrote NO row into {Path(args.csv).name} "
            f"({len(missing)}):")
      for name in missing:
        why = WAIVED_EXPORTS.get(name)
        if why:
          print(f"  ok   {name:22} waived: {why}")
        else:
          print(f"  FAIL {name:22} the bind exists and reports nowhere; an "
                f"aggregation over rows cannot see it")
          failures += 1
    else:
      print(f"\nall {len(binds)} binds wrote rows into {Path(args.csv).name}")

    # The reverse direction: a row from a bind the top does not declare means the
    # export name and the instance name have drifted apart, and the aggregation
    # is filing evidence under a bind nobody can find.
    orphan = sorted(b for b in seen if b not in binds)
    if orphan:
      print(f"\nexported bind names with no matching instance in the top "
            f"({len(orphan)}):")
      for name in orphan:
        print(f"  FAIL {name:22} rows filed under a name the harness does not "
              f"declare")
        failures += 1

  if failures:
    print(f"\nFAILED: {failures} bind-coverage gap(s)")
    return 1
  print("\nevery live link is checked, and every checker reports")
  return 0


if __name__ == "__main__":
  sys.exit(main())
