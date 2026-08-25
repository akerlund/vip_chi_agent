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

  FAILING        any run recorded a failure. Reported first because it is the
                 most alarming thing here, and deliberately NOT a gate -- see
                 the note where it is printed.
  PROVOKED       a failure at OFF or WARNING -- a negative control proving its
                 rule fires, which is evidence rather than a bug
  NOT EXPORTED   in the registry, but no bind wrote a row for it
  ONE SOURCE     exercised under one labelled source and never the rest
  NEVER          zero passes and zero fails in every run that evaluated it
  DEAD ON A BIND zero passes and zero fails on one INTERFACE while alive on
                 another -- a rule that interface checks in name only
  THIN           exercised by only one or two runs -- alive, but one deleted
                 testcase away from silently becoming NEVER, which is the state
                 this whole mechanism exists to prevent recurring

Exits non-zero when anything is NEVER exercised, so a regression can gate on it.

Aggregation happens on (bind, check), not on check alone. A rule is a property
of an interface, not of the registry: one name is bound to every interface of a
matching shape and can be exercised on one and dead on the rest. Joining on the
name reports the union, so a checker that never elaborated reads as a clean link
for as long as any other bind carries the same rule -- which is how a dead bind
survived from the first commit until a human read the instantiation. The
per-name verdicts are kept, because a rule dead EVERYWHERE is the more alarming
state; DEAD ON A BIND is the state that was previously unreportable.
"""

from __future__ import annotations

import argparse
import csv
import fnmatch
import sys
from datetime import datetime
from pathlib import Path
from collections import defaultdict


THIN_RUN_THRESHOLD_C = 2
# How far apart two input CSVs may be written before the comparison between them
# is worth doubting. See the staleness guard in main().
STALE_INPUT_SECONDS_C = 3600


def normalize_severity(raw: str) -> str:
  """Return the bare severity name, whichever port wrote the row.

  The two ports do not spell this column the same way: the Python checker writes
  `ERROR`, the SV export writes the enum literal `VIP_CHI_CHK_SEV_ERROR_E`.
  Comparing against a single spelling does not merely miss rows -- it inverts
  their meaning. Every SV failure at ERROR would fall through to the branch that
  files a failure as one a negative control asked for, so a real regression
  would be reported under a heading saying it was intentional.

  Normalizing on read rather than changing an exporter is deliberate: it keeps
  CSVs already on disk readable, and it means neither port can break this by
  choosing its own spelling later.
  """
  return raw.strip().removeprefix("VIP_CHI_CHK_SEV_").removesuffix("_E")


def _print_stale_sections() -> None:
  """Name the two sections a mismatched comparison invalidates.

  Only these two compare sources against each other; the rest of the report is
  a per-source tally and stays true whatever the inputs describe. Saying which
  is the difference between a warning a reader can act on and one they learn to
  scroll past.
  """
  print("  Re-run the older sweep before trusting EVIDENCE FROM ONE SOURCE "
        "ONLY or\n  DEAD ON A BIND: both compare sources against each other, "
        "so a mismatched\n  file reads as a rule the other port never "
        "exercised.\n")


def main() -> int:
  ap = argparse.ArgumentParser(description=__doc__,
                               formatter_class=argparse.RawDescriptionHelpFormatter)
  ap.add_argument("csv", nargs="+",
                  help="check-tally CSV file(s), optionally LABEL=path so that "
                       "evidence found under only one label is reportable "
                       "(e.g. sv=sv.csv py=py.csv)")
  ap.add_argument("--thin", type=int, default=THIN_RUN_THRESHOLD_C,
                  help=f"flag rules exercised by <= N runs (default {THIN_RUN_THRESHOLD_C})")
  ap.add_argument("--allow-never", action="store_true",
                  help="report but do not fail when a rule is never exercised")
  ap.add_argument("--fail-on-bind-gaps", nargs="?", const="*", metavar="GLOBS",
                  help="also fail when a rule is enabled on a bind, alive on "
                       "another, and never evaluated there. Takes a "
                       "comma-separated list of bind globs (rni_*,snf_*) so "
                       "one bind-set can start gating while the rest are still "
                       "being triaged; the bare flag means every bind. Off by "
                       "default because the list as a whole is untriaged and "
                       "some of it is structural")
  args = ap.parse_args()

  passes = defaultdict(int)
  fails = defaultdict(int)
  deliberate = defaultdict(int)
  runs_exercising = defaultdict(set)
  disabled_everywhere = defaultdict(lambda: True)
  known = []

  # The per-bind axis, keyed on (bind, check). A bind exports only the rules its
  # own registry scope owns -- 7 for an SNP bind, 48 for a full one -- so this
  # does not enumerate rules an interface was never meant to carry.
  bind_evidence = defaultdict(int)
  bind_enabled = defaultdict(bool)
  binds_seen = set()

  # Which labelled source exercised each rule. A rule the SV port checks and the
  # Python port does not is exercised in the union and unchecked in half the
  # product, and the union is what a reader sees. Labels are opt-in because with
  # a single unlabelled CSV -- how the sweep calls this -- the question has no
  # meaning and the section is suppressed rather than answered wrongly.
  labels_exercising = defaultdict(set)
  labels_seen = []
  revs_seen: set[str] = set()
  # (path, mtime) per input, for the staleness guard below.
  inputs_seen = []

  for spec in args.csv:
    # LABEL=path, but only when LABEL is plausibly a label rather than the first
    # half of a path that happens to contain "=". A bare path always wins the
    # tie, because mislabelling a file is silent while a missing label only
    # suppresses an optional section.
    label, sep, path = spec.partition("=")
    if not sep or "/" in label or not path:
      label, path = "", spec
    elif label not in labels_seen:
      labels_seen.append(label)
    try:
      inputs_seen.append((path, Path(path).stat().st_mtime))
      # The revision each input was produced at. Absent on rows written before
      # the column existed, which is why the age fallback stays.
      with open(path, newline="", encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
          revs_seen.add((row.get("rev") or "").strip())
          rule = row["check"]
          if rule not in passes and rule not in fails:
            known.append(rule)
          p, f = int(row["passes"]), int(row["fails"])
          bind = row["bind"]
          binds_seen.add(bind)
          bind_evidence[(bind, rule)] += p + f
          if label and (p or f):
            labels_exercising[rule].add(label)
          passes[rule] += p
          # A failure recorded at severity OFF or WARNING was provoked on
          # purpose -- that is how a negative control proves its rule fires --
          # so it counts as EXERCISED but not as a regression failure. Counting
          # it as one would make every negative control look like a bug.
          if normalize_severity(row["severity"]) == "ERROR":
            fails[rule] += f
          else:
            deliberate[rule] += f
          if row["enabled"] == "1":
            disabled_everywhere[rule] = False
            bind_enabled[(bind, rule)] = True
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
  sv_only = {}
  try:
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "py"))
    from vip_chi_types_pkg import CHECK_IDS, CHECK_IDS_SV_ONLY, CHECK_IDS_SB
    sv_only = dict(CHECK_IDS_SV_ONLY)
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

  # A rule is dead on a bind when that bind exported it, had it enabled, and
  # recorded nothing. Only pairs whose rule is alive on some OTHER bind are
  # collected: a rule dead on every bind is already reported as NEVER above, and
  # listing it once per bind as well would bury the per-bind signal under the
  # per-name one.
  alive_rules = {rule for (_, rule), n in bind_evidence.items() if n}
  dead_on_bind = defaultdict(list)
  for (bind, rule), n in sorted(bind_evidence.items()):
    if n == 0 and bind_enabled[(bind, rule)] and rule in alive_rules:
      dead_on_bind[bind].append(rule)

  # Gating on these gaps is opt-in PER BIND-SET, not all or nothing. The gaps
  # are two kinds this report cannot separate: structural ones, where the rule
  # belongs to a vantage this interface does not have and the fix is to stop
  # the bind claiming it, and plain missing stimulus. A single switch therefore
  # has to stay off until the last bind is clean, and a gate that cannot be
  # turned on for years is one nobody turns on at all. Per bind-set, an
  # interface starts gating the day its own triage lands and cannot quietly
  # regress afterwards.
  gap_globs = [g.strip() for g in (args.fail_on_bind_gaps or "").split(",")
               if g.strip()]
  gating_binds = {b for b in binds_seen
                  if any(fnmatch.fnmatchcase(b, g) for g in gap_globs)}
  # A glob that matches nothing is a typo, and a typo here is indistinguishable
  # from a clean bind-set: the gate passes, and nothing on stdout says the
  # bind-set it was asked to guard was never looked at.
  unmatched_globs = [g for g in gap_globs
                     if not any(fnmatch.fnmatchcase(b, g) for b in binds_seen)]

  # Rules exactly one labelled source ever exercised. A rule no source exercised
  # has an empty set, not a single-element one, so it stays a NEVER rather than
  # being re-reported here as lopsided.
  #
  # CHECK_IDS_SV_ONLY is excluded: those rules are one-source-only BY DESIGN --
  # Verilator's 2-state model cannot evaluate an X/Z rule, which is why they are
  # already reported under "absent by design". Listing them here too would put
  # four permanent entries at the top of a section whose whole value is that it
  # is normally empty, and a section that is never empty is never read.
  one_label_only = []
  if len(labels_seen) > 1:
    for rule in rules:
      if rule in sv_only:
        continue
      where = labels_exercising[rule]
      if len(where) == 1:
        one_label_only.append((rule, next(iter(where))))

  never, thin, failing = [], [], []
  for rule in rules:
    n_runs = len(runs_exercising[rule])
    if fails[rule]:
      failing.append((rule, fails[rule]))
    if n_runs == 0:
      never.append((rule, disabled_everywhere[rule]))
    elif n_runs <= args.thin:
      thin.append((rule, n_runs, sorted(runs_exercising[rule])))

  # Comparing sweeps from different code revisions produces confident nonsense:
  # a rule the older sweep predates reads as one port's rule that the other never
  # exercised, and every per-bind verdict inherits the same skew.
  #
  # The CSV now stamps the producing revision, so this is answered exactly
  # rather than guessed at. Age remains as a FALLBACK, for rows written before
  # the column existed and for an export that could not name a commit -- it is a
  # weaker test and is labelled as one. See F-CHK-011.
  #
  # Warned rather than gated in both cases: comparing an archived sweep against a
  # fresh one is a legitimate thing to do, and the tool should say what it is
  # comparing rather than refuse to.
  revs = {r for r in revs_seen if r and r != "unknown"}
  dirty = {r for r in revs if r.endswith("-dirty")}

  if len(revs) > 1:
    print("WARNING: these CSVs were produced by different revisions, so they do "
          "not describe the same code:")
    for rev in sorted(revs):
      print(f"  {rev}")
    _print_stale_sections()
  elif dirty and len(inputs_seen) > 1:
    # One revision, but at least one sweep ran against uncommitted changes. Same
    # commit is then not the same code, and the stamp cannot tell how different.
    print(f"NOTE: {sorted(dirty)[0]} -- at least one sweep ran against a "
          "modified tree, so a matching revision does not by itself mean the "
          "two describe the same code.\n")

  # The age fallback, only where the stamp could not answer.
  if len(inputs_seen) > 1 and len(revs) <= 1 and not revs:
    newest = max(m for _, m in inputs_seen)
    oldest = min(m for _, m in inputs_seen)
    if (newest - oldest) > STALE_INPUT_SECONDS_C:
      print(f"WARNING: no revision stamp in these CSVs, and they are "
            f"{(newest - oldest) / 3600.0:.1f} hours apart, so they may not "
            "describe the same code:")
      for path, mtime in sorted(inputs_seen, key=lambda pair: pair[1]):
        stamp = datetime.fromtimestamp(mtime).isoformat(timespec="seconds")
        print(f"  {stamp}  {path}")
      _print_stale_sections()

  print(f"checks: {len(rules)}   binds: {len(binds_seen)}   runs: "
        f"{len({r for s in runs_exercising.values() for r in s})}")

  if failing:
    print(f"\nFAILING ({len(failing)}):")
    for rule, n in failing:
      print(f"  {rule:<44s} {n} failure(s)")
    # Reported, not gated, and that is a decision rather than an oversight.
    #
    # Every one of these has already failed its own testcase, at the source and
    # in the run that produced it: the SV env raises uvm_report_error from
    # chi_check_report_tallies for any rule with fails > 0 at ERROR severity,
    # and the Python checker reports through the same path its testcases assert
    # on. A second gate here would not catch anything the sweep let through.
    #
    # What it WOULD add is a false alarm on the one axis this script cannot
    # verify: it reads CSVs whose vintage it can only guess at from file age
    # (see the staleness note above). Gating on a failure -- an event tied to
    # one revision -- would turn a stale file into a live regression report.
    # The gates below are about ABSENCE of evidence, which stays meaningful on
    # a file of uncertain age in a way that a recorded failure does not.
    print("  ^ reported, not gated: each of these failed its own testcase in "
          "the run that\n    recorded it. This script gates on rules with no "
          "evidence, not on failures.")

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

  if one_label_only:
    print(f"\nEVIDENCE FROM ONE SOURCE ONLY ({len(one_label_only)}) -- "
          f"exercised under one of {', '.join(labels_seen)},\n"
          f"never under the rest, so the union above overstates them:")
    for rule, where in one_label_only:
      print(f"  {rule:<44s} {where} only")

  if dead_on_bind:
    n_pairs = sum(len(v) for v in dead_on_bind.values())
    print(f"\nDEAD ON A BIND -- enabled on this interface, exercised on another,"
          f" and never evaluated here ({n_pairs} pair(s) across "
          f"{len(dead_on_bind)} bind(s)):")
    print("  Each line is a rule this interface is checking in name only. Some "
          "are\n  structural -- a request and its completion are not both "
          "visible on one\n  coherent link -- and some are missing stimulus; "
          "the report cannot tell\n  those apart, so a bind only gates once "
          "--fail-on-bind-gaps names it.")
    for bind in sorted(dead_on_bind):
      rules_here = dead_on_bind[bind]
      mark = "  [gating]" if bind in gating_binds else ""
      print(f"\n  {bind}  ({len(rules_here)}):{mark}")
      for rule in rules_here:
        print(f"    {rule}")

  if thin:
    print(f"\nTHIN -- exercised by <= {args.thin} run(s) ({len(thin)}):")
    for rule, n, where in thin:
      print(f"  {rule:<44s} {n}: {', '.join(where)}")

  if (not never and not thin and not failing and not unexported
      and not dead_on_bind and not one_label_only):
    print("\nevery check in both registries was exported, exercised by more "
          f"than {args.thin} run(s) on every bind that enabled it, and none "
          "failed")

  # A rule disabled in every run was not exercised BY REQUEST, so it is reported
  # but does not gate: failing on it would punish the user for using the feature.
  gating = [r for r, was_disabled in never if not was_disabled]
  if (gating or unexported) and not args.allow_never:
    return 1
  if unmatched_globs:
    print(f"\nERROR: --fail-on-bind-gaps matched no bind: "
          f"{', '.join(unmatched_globs)}", file=sys.stderr)
    return 2
  if any(bind in gating_binds for bind in dead_on_bind):
    return 1
  return 0


if __name__ == "__main__":
  sys.exit(main())
