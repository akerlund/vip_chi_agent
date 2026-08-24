#!/usr/bin/env python3
"""Every live link carries a checker, every checker reports, and the rules it
cannot possibly evaluate are told apart from the ones nothing drove.

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

It also splits `check_vacuity.py`'s DEAD ON A BIND list, which that report says
outright it cannot do: "some are structural ... and some are missing stimulus;
the report cannot tell those apart". Most of them are structural and mechanically
so. A rule whose evidence can only appear at one end of a link -- the REQ channel
is transmitted at a requester and received at a completer, snoops the other way
round -- is dead at the other end by POLARITY, not for want of a testcase. Naming
the vantage separates the two, and what is left is the actual triage backlog.

A rule can also be dead because of the link's GEOMETRY. The DAT burst-ordering
rules only exist on the second and later beat of a burst, so on a link whose bus
is as wide as the largest transfer CHI can ask for there is nowhere for a second
beat to be. Those want a narrower link, not a testcase, which is a topology item
and a different queue -- so they are counted apart from both of the above rather
than sitting in a backlog no testcase can ever drain.

Both tables are declared rather than parsed, and they check themselves: a rule
declared requester-only that records evidence at a completer bind, or a
multi-beat rule that records evidence on a bus too wide to produce one, is a
contradiction, and the script says so instead of quietly filing 650 pairs under
"structural". That self-check is the reason the tables are trustworthy at all.

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
PKG = ROOT / "testbench" / "sv" / "tb" / "chi_tb_pkg.sv"
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

_REQUESTER_ROLES_C = frozenset({"RNI", "RNF"})
_COMPLETER_ROLES_C = frozenset({"SNF", "HNF", "HNI"})

# Rules whose evidence can only appear at the requester's end of a link. Each is
# about a channel this end transmits, or a response only a requester sends.
REQUESTER_VANTAGE_C = frozenset({
  # REQ is transmitted here and received at the far end.
  "CHI_REQ_FLITV_REQUIRES_LINK",
  "CHI_REQ_KNOWN_WHEN_VALID",
  "CHI_REQ_VALID_REQUIRES_PEND",
  "CHI_TXNID_REUSE_REQUESTER",
  # Write data goes out from here; the read completion comes back to here.
  "CHI_TX_WRITE_DAT_BEAT_COUNT",
  "CHI_WRITE_DAT_BEFORE_DBID",
  "CHI_WRITE_DAT_TXNID_MATCHES_DBID",
  "CHI_RX_READ_COMPLETION_DAT_BEAT_COUNT",
  "CHI_RX_READ_COMPLETION_DAT_OPCODE",
  # CompAck is sent by the requester.
  "CHI_COMPACK_BEFORE_COMPLETION",
  "CHI_COMPACK_WITHOUT_EXPCOMPACK",
  #
  # CHI_TXSACTIVE_COVERS_OUTSTANDING WAS LISTED HERE, on the ground that
  # "TXSACTIVE reports ITS outstanding window -- a completer has none of its
  # own". Section 14.7.2 states the obligation separately for each role and
  # gives the completer one under TXSACTIVE signaling from an ICN interface to
  # an RN: hold the sideband "until after the final completing flit is sent or
  # received". So the rule is live at BOTH ends and belongs in neither vantage
  # set. See F-CORR-005.
  #
  # This entry is why the gate fired when the checker's own gate came off -- the
  # table recorded the same wrong belief the checker did, in a second place.
  # That is the table working: a rule whose vantage changes has to be restated
  # here, and 12 binds said so.
  # Snoop credits are GRANTED by the RN-F that receives snoops.
  "CHI_SNP_LCRDV_REQUIRES_LINK",
})

# The largest data payload one CHI transaction can move. IHI 0050 E Table 2-15
# (Size field value encodings, §2.10.1) and Table 13-20: Size 0b110 is 64 bytes
# and 0b111 is Reserved, so 64 is the ceiling and there is no encoding above it.
CHI_MAX_XFER_BYTES_C = 64

# Rules that only exist on the SECOND and later beat of a DAT burst. Their
# antecedent is "this flit continues a burst already in progress", so a link
# where every transfer fits in one beat cannot reach them -- not for want of a
# testcase, but because the geometry leaves nowhere for a second beat to be.
#
# That is the case on any link whose DAT bus is at least CHI_MAX_XFER_BYTES_C
# wide: the largest transfer CHI can ask for still lands in a single flit.
#
# This is a THIRD reason a rule can be dead, distinct from the vantage above and
# recorded separately because the remedy is different. A vantage-dead rule is
# checked at the other end and wants nothing. A geometry-dead rule is not checked
# on this link AT ALL and wants a narrower link to be checked on -- which is a
# topology change, not a testcase, and belongs in a different queue from the
# triage backlog.
#
# One honest caveat, kept here rather than in a commit message because it is the
# thing that would mislead the next reader: a burst CAN exceed one beat on a wide
# bus when the completer interleaves two transfers under one FLITPEND. Both rules
# stand themselves down in that case (they are gated on !dat_interleave_allowed)
# and record a pass for a flit they did not judge, so the evidence would be real
# and the judgement would not. The self-check below therefore reports any
# evaluation on a wide-bus bind as a contradiction: on this testbench there are
# none, and if one appears it is worth reading either way.
MULTI_BEAT_VANTAGE_C = frozenset({
  "CHI_TX_DAT_DATAID_SEQUENTIAL",
  "CHI_RX_DAT_DATAID_SEQUENTIAL",
  "CHI_TX_DAT_TXNID_STABLE",
  "CHI_RX_DAT_TXNID_STABLE",
})

# The mirror set: evidence only at the completer's end.
COMPLETER_VANTAGE_C = frozenset({
  "CHI_REQ_LCRDV_REQUIRES_LINK",       # REQ credits are granted here
  "CHI_TXNID_REUSE_COMPLETER",
  "CHI_RX_WRITE_DAT_BEAT_COUNT",       # write data arrives here
  "CHI_TX_READ_COMPLETION_DAT_BEAT_COUNT",
  "CHI_TX_READ_COMPLETION_DAT_OPCODE",
  # Snoops are SENT by the home.
  "CHI_SNP_FLITV_REQUIRES_LINK",
  "CHI_SNP_KNOWN_WHEN_VALID",
  "CHI_SNP_VALID_REQUIRES_PEND",
})


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


def parse_bind_roles(sv: str) -> dict[str, str]:
  """Bind instance name -> the ROLE_P it was parameterised with.

  The role is what decides which end of the link a bind sits on, and therefore
  which rules can produce evidence there at all.
  """
  roles: dict[str, str] = {}
  for m in re.finditer(
      r"vip_chi_(?:snp_)?sva\s*#\(([^;]*?)\)\s*\n\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*"
      r"\(\.vif\(", sv):
    role = re.search(r"ROLE_P\(VIP_CHI_ROLE_(\w+)_E\)", m.group(1))
    roles[m.group(2)] = role.group(1) if role else "UNKNOWN"
  return roles


def parse_cfg_data_bytes(pkg: str) -> dict[str, int]:
  """Config localparam name -> DATA_BYTES_P, read from chi_tb_pkg."""
  widths: dict[str, int] = {}
  for m in re.finditer(
      r"localparam\s+vip_chi_cfg_t\s+(\w+)\s*=\s*'\{(.*?)\};", pkg, re.S):
    db = re.search(r"DATA_BYTES_P\s*:\s*(\d+)", m.group(2))
    if db:
      widths[m.group(1)] = int(db.group(1))
  return widths


def parse_bind_data_bytes(sv: str, cfg_widths: dict[str, int]) -> dict[str, int]:
  """Bind instance name -> the DAT bus width of the link it observes.

  Taken from the bind's own CFG_P, not from the interface, for the same reason
  parse_bind_roles reads ROLE_P: what the bind was PARAMETERISED with is what it
  compiled against, and a bind parameterised with the wrong config is a real
  mistake this repository has already made once.
  """
  widths: dict[str, int] = {}
  for m in re.finditer(
      r"vip_chi_(?:snp_)?sva\s*#\((.*?)\)\s*\n\s*(\w+)\s*\(\.vif\(", sv, re.S):
    cfg = re.search(r"CFG_P\((\w+)\)", m.group(1))
    widths[m.group(2)] = cfg_widths.get(cfg.group(1), 0) if cfg else 0
  return widths


def read_evidence(csv_path: Path):
  """(bind, check) -> evaluations, and (bind, check) -> enabled-anywhere."""
  ev: dict[tuple[str, str], int] = {}
  enabled: dict[tuple[str, str], bool] = {}
  with csv_path.open(newline="", encoding="utf-8") as fh:
    for row in csv.DictReader(fh):
      check = (row.get("check") or "").strip()
      bind = (row.get("bind") or "").strip()
      if not bind or check.startswith("CHI_SB_"):
        continue
      key = (bind, check)
      ev[key] = ev.get(key, 0) + int(row["passes"]) + int(row["fails"])
      enabled[key] = enabled.get(key, False) or row["enabled"] == "1"
  return ev, enabled


def split_dead(ev, enabled, roles, data_bytes=None) -> tuple[list, list, list, list]:
  """Split the dead (bind, rule) pairs by what explains them.

  Three explanations, in the order a reader should try them: the rule's evidence
  belongs at the other end of the link (vantage), the link's geometry leaves the
  rule's antecedent unreachable (geometry), or nothing drove it (the backlog).
  """
  alive_rule: dict[str, int] = {}
  for (_b, c), n in ev.items():
    alive_rule[c] = alive_rule.get(c, 0) + n
  data_bytes = data_bytes or {}

  structural, geometry, no_stimulus, contradictions = [], [], [], []
  for (bind, check), n in sorted(ev.items()):
    role = roles.get(bind, "UNKNOWN")
    is_req = role in _REQUESTER_ROLES_C
    is_comp = role in _COMPLETER_ROLES_C
    wrong_end = ((check in REQUESTER_VANTAGE_C and is_comp) or
                 (check in COMPLETER_VANTAGE_C and is_req))
    width = data_bytes.get(bind, 0)
    too_wide = (check in MULTI_BEAT_VANTAGE_C and
                width >= CHI_MAX_XFER_BYTES_C)
    if n and (wrong_end or too_wide):
      contradictions.append((bind, check, role, n))
      continue
    if n or not enabled[(bind, check)] or not alive_rule.get(check):
      continue
    if wrong_end:
      structural.append((bind, check, role))
    elif too_wide:
      geometry.append((bind, check, width))
    else:
      no_stimulus.append((bind, check, role))
  return structural, geometry, no_stimulus, contradictions


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

  # The DEAD ON A BIND split. check_vacuity.py reports the pairs and says it
  # cannot tell structural from untested; the vantage table can, for most of them.
  if seen is not None:
    ev, enabled = read_evidence(Path(args.csv))
    roles = parse_bind_roles(sv)
    cfg_widths = parse_cfg_data_bytes(_read(PKG))
    data_bytes = parse_bind_data_bytes(sv, cfg_widths)
    structural, geometry, no_stimulus, contradictions = split_dead(
      ev, enabled, roles, data_bytes)

    if contradictions:
      print(f"\nVANTAGE TABLE CONTRADICTED ({len(contradictions)}):")
      for bind, check, role, n in contradictions:
        print(f"  FAIL {bind} ({role}) recorded {n} evaluation(s) of {check}, "
              f"which the table calls impossible at this end")
        failures += 1

    print(f"\ndead (bind, rule) pairs: "
          f"{len(structural) + len(geometry) + len(no_stimulus)}  "
          f"= {len(structural)} explained by vantage  "
          f"+ {len(geometry)} explained by geometry  "
          f"+ {len(no_stimulus)} missing stimulus")
    if structural:
      print("  Explained: the rule's evidence can only appear at the other end of "
            "the link.\n  A REQ flit is transmitted at a requester and received "
            "at a completer; snoops\n  go the other way. These are dead by "
            "polarity, not for want of a testcase,\n  and no testcase can move "
            "them.")
    if geometry:
      by_width: dict[int, set[str]] = {}
      for bind, _check, width in geometry:
        by_width.setdefault(width, set()).add(bind)
      widths = ", ".join(f"{len(b)} bind(s) at {w} B"
                         for w, b in sorted(by_width.items()))
      print(f"\n  GEOMETRY -- the rule's antecedent is unreachable on this link "
            f"({len(geometry)}).\n  These want a NARROWER LINK, not a testcase, "
            f"so they are a topology item and\n  not part of the triage backlog "
            f"below. Every one is a DAT burst-ordering rule\n  on a link whose "
            f"bus is at least the largest transfer CHI can ask for\n  "
            f"({CHI_MAX_XFER_BYTES_C} B, IHI 0050 E Table 2-15), so no transfer "
            f"needs a second beat: {widths}.")
    if no_stimulus:
      print(f"\n  MISSING STIMULUS -- alive elsewhere, possible here, and "
            f"nothing drove it ({len(no_stimulus)}).\n  This is the triage "
            f"backlog: every line is a rule some testcase could reach.")
      by_bind: dict[str, list[str]] = {}
      for bind, check, _role in no_stimulus:
        by_bind.setdefault(bind, []).append(check)
      for bind in sorted(by_bind):
        print(f"    {bind} ({len(by_bind[bind])}): "
              f"{', '.join(sorted(by_bind[bind])[:4])}"
              f"{' ...' if len(by_bind[bind]) > 4 else ''}")

  if failures:
    print(f"\nFAILED: {failures} bind-coverage gap(s)")
    return 1
  print("\nevery live link is checked, and every checker reports")
  return 0


if __name__ == "__main__":
  sys.exit(main())
