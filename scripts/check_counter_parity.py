#!/usr/bin/env python3
"""Compare what the two ports' coherency checkers JUDGED on the same testcase.

The four existing parity checks compare SURFACES. `check_type_parity.py` compares
enum values and flit field order, `check_cfg_parity.py` the config fields,
`check_opcodes.py` the opcode sets, `check_classifier_coverage.py` the
classifiers, `check_test_counts.py` the testcase lists. All five pass when the
two ports agree about what EXISTS. None of them looks at what the two ports
DECIDED when the same stimulus was put through them, and that is where the
divergences have actually been:

  * The Python DAT hook never called check_snp_resp_state, so that rule judged
    14 of 19 snoop responses there against SystemVerilog's 19, and the with_data
    axis of an illegal_bins cross was unreachable in the port that declared it.
    Both numbers were printed in both sweeps.
  * The FLITPEND negative control reaches a different set of drivers in each
    port, because some send sites announce inline. The knob EXISTS in both
    configs, spelled identically, so cfg parity passes on it.

Each of those is a parity check passing on something the two ports do
differently. The counters are the one artifact that is a function of BEHAVIOUR
rather than of declarations, they are already printed by both flows, and before
this they were compared by hand after every coherency change.

Scope, stated rather than implied: this reads the `COHERENCY ... SUMMARY:` lines
only. `PERF SUMMARY` is excluded because it reports cycle counts that the two
simulators have no reason to agree on, and the per-check tallies are compared by
check_vacuity.py against its own CSV. Extending this to a new summary line needs
nothing but emitting it from both ports in the same `field=value` form.

One-sided counters are not tolerated by default. A counter only one port can
produce -- a covergroup percentage, say -- is listed in PORT_ONLY_C with the
port that owns it and the reason, and that table is itself checked: an entry
that stops being one-sided fails, so it cannot go on excusing the name after
the thing it excused was fixed.

Fails closed. A testcase that exists in both flows and produced coherency
summaries in one and none in the other is a divergence, not a skip -- that is
precisely the shape of a case where the Python side was silent about
responses it never looked at.

Requires both flows to have been run, and says which of the three answers it is
giving, because the sweep that calls it gates on one of them and not the others:

  0  compared, and the two ports agree
  1  compared, and they do not -- the sweep must fail
  2  INCONCLUSIVE: only one flow has logs, so there was nothing to compare

Two is separate from one for a reason a single non-zero code cannot express. A
one-sided comparison reporting success is the failure mode this check exists to
remove, so it must never exit 0; but a missing pyUVM sweep is not a defect in the
SystemVerilog one, and gating on it would make the SV sweep unrunnable alone.
With neither log tree present it exits 0 -- there is no half-answer to guard
against -- so it is safe to call before anything has run.

Usage:
  python3 scripts/check_counter_parity.py
"""

from __future__ import annotations

import datetime
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]

SV_LOG_DIR = ROOT / "build" / "akerlund__vip_chi_agent_example_0" / "default-vcs"
PY_LOG_DIR = ROOT / "testbench" / "py" / "rundir" / "verilator"

SV_LOG_GLOB = "vcs_tc_*.log"
PY_LOG_GLOB = "tc_*.log"

# Testcases whose stimulus is generated independently in the two flows. Their
# counters are a function of that stimulus, so comparing them compares two
# different experiments -- the SV stress test draws from $urandom and the Python
# one from random.Random(seed), and neither is trying to reproduce the other.
# Excluded by name, with the reason recorded, rather than by sniffing for
# randomness: a check that silently skips whatever looks noisy would also skip
# the divergence it exists to find.
#
# Every name here must exist in both flows (verified below), so the list cannot
# quietly outlive the testcase it excuses.
INDEPENDENT_STIMULUS = {
  "tc_chi_coh_d_stress": "independent random streams: $urandom vs random.Random",
  "tc_chi_coh_e_stress": "independent random streams: $urandom vs random.Random",
}

# Counters one port publishes and the other has no counterpart for, each naming
# the owning port and the reason. An entry is a RECORDED DECISION, not a
# silencer: anything one-sided and NOT listed here is a divergence, and an entry
# that names the wrong port does not excuse anything.
#
# Checked for staleness below, the way check_tally_parity checks its own table.
# An entry that has stopped being one-sided fails, because a table nobody prunes
# stops describing the ports and starts excusing the next divergence to appear
# under the same name.
PORT_ONLY_C: dict[str, tuple[str, str]] = {
  "req_snp_pairing_coverage": (
    "SV",
    "a SystemVerilog covergroup percentage, and pyUVM has no covergroup object "
    "to compute one from; both ports publish req_snp_pairs on the same line for "
    "the part of that cross which is comparable"),
}

# `COHERENCY <NAME> SUMMARY: field=value field=value ...`, anywhere on the line:
# both flows prefix it with their own report-server or logger decoration.
SUMMARY_RE = re.compile(r"(COHERENCY [A-Z0-9 _]*SUMMARY): (.*)$")

# Fractional values are captured whole. An integer-only pattern reads
# `coverage=17.6` as 17 and then reports that two ports which printed 17.6 and
# 17.2 agree -- a comparison silently narrower than the one being claimed.
FIELD_RE = re.compile(r"([a-z0-9_]+)=(-?\d+(?:\.\d+)?)")


def counters_from(path: pathlib.Path) -> dict[str, float]:
  """Every field=value pair on the coherency summary lines of one log.

  Field names are unique across the summary lines by construction, so the
  summary a counter came from is not part of its key: moving a counter to a
  different (or new) summary line must not read as a divergence.
  """
  found: dict[str, float] = {}
  for line in path.read_text(errors="replace").splitlines():
    match = SUMMARY_RE.search(line)
    if not match:
      continue
    for name, value in FIELD_RE.findall(match.group(2)):
      found[name] = float(value) if "." in value else int(value)
  return found


def collect(log_dir: pathlib.Path, glob: str, strip: str) -> dict[str, dict[str, float]]:
  """Map testcase name -> its counters, for every log in one flow's directory."""
  out: dict[str, dict[str, float]] = {}
  if not log_dir.is_dir():
    return out
  for path in sorted(log_dir.glob(glob)):
    name = path.stem
    if strip and name.startswith(strip):
      name = name[len(strip):]
    out[name] = counters_from(path)
  return out


def newest(log_dir: pathlib.Path, glob: str) -> str:
  """When the most recent log in one flow's directory was written."""
  times = [path.stat().st_mtime for path in log_dir.glob(glob)]
  if not times:
    return "none"
  return datetime.datetime.fromtimestamp(max(times)).strftime("%Y-%m-%d %H:%M:%S")


def main() -> int:
  sv = collect(SV_LOG_DIR, SV_LOG_GLOB, "vcs_")
  py = collect(PY_LOG_DIR, PY_LOG_GLOB, "")

  if not sv and not py:
    print("no regression logs in either flow; nothing to compare")
    print(f"  SV: {SV_LOG_DIR}")
    print(f"  PY: {PY_LOG_DIR}")
    return 0

  # One-sided is not a pass: a comparison with nothing to compare against must
  # not report agreement. It is not a divergence either -- see the exit codes in
  # the header -- so it gets its own.
  if not sv or not py:
    missing = "SV" if not sv else "Python"
    print(f"only one flow has logs -- the {missing} regression has not been run")
    print(f"  SV: {len(sv)} log(s) under {SV_LOG_DIR}")
    print(f"  PY: {len(py)} log(s) under {PY_LOG_DIR}")
    return 2

  shared = sorted(set(sv) & set(py))
  print(f"testcases with logs in both flows: {len(shared)} "
        f"(SV {len(sv)}, Python {len(py)})")

  # When this gates a sweep, the commonest cause of a surprise divergence is one
  # flow's logs being older than the source both were built from. The comparison
  # cannot tell -- a log records no provenance -- so it reports the ages and lets
  # whoever reads the failure see a stale tree without going to look for it.
  print(f"  SV logs newest: {newest(SV_LOG_DIR, SV_LOG_GLOB)}")
  print(f"  PY logs newest: {newest(PY_LOG_DIR, PY_LOG_GLOB)}")

  # The exclusion list is itself checked. An entry that no longer names a real
  # testcase is an exclusion nobody can see the effect of.
  stale = sorted(name for name in INDEPENDENT_STIMULUS if name not in shared)
  if stale:
    print()
    print("stale entries in INDEPENDENT_STIMULUS -- no such testcase in both flows:")
    for name in stale:
      print(f"  {name}")
    return 1
  for name in sorted(INDEPENDENT_STIMULUS):
    print(f"  excluded: {name} -- {INDEPENDENT_STIMULUS[name]}")

  divergences: list[str] = []
  stated_used: set[str] = set()
  compared_tests = 0
  compared_counters = 0

  for name in shared:
    if name in INDEPENDENT_STIMULUS:
      continue
    sv_counters = sv[name]
    py_counters = py[name]
    if not sv_counters and not py_counters:
      # Neither port instantiates a coherency checker for this testcase -- the
      # link-layer and proxy topologies. Not a divergence.
      continue
    if not sv_counters or not py_counters:
      silent = "SV" if not sv_counters else "Python"
      other = py_counters if not sv_counters else sv_counters
      divergences.append(
        f"{name}: {silent} emitted no coherency summary at all, the other port "
        f"emitted {len(other)} counters")
      continue

    compared_tests += 1
    for counter in sorted(set(sv_counters) | set(py_counters)):
      if counter not in sv_counters:
        if PORT_ONLY_C.get(counter, (None,))[0] == "Python":
          stated_used.add(counter)
          continue
        divergences.append(f"{name}: {counter} is Python-only "
                           f"(py={py_counters[counter]})")
        continue
      if counter not in py_counters:
        if PORT_ONLY_C.get(counter, (None,))[0] == "SV":
          stated_used.add(counter)
          continue
        divergences.append(f"{name}: {counter} is SV-only "
                           f"(sv={sv_counters[counter]})")
        continue
      compared_counters += 1
      if sv_counters[counter] != py_counters[counter]:
        divergences.append(f"{name}: {counter} sv={sv_counters[counter]} "
                           f"py={py_counters[counter]}")

  print(f"testcases with coherency counters in both flows: {compared_tests}")
  print(f"counter values compared: {compared_counters}")
  for counter in sorted(stated_used):
    port, reason = PORT_ONLY_C[counter]
    print(f"  stated: {counter} is {port}-only -- {reason}")

  # An exception that never applied is either a counter both ports now publish
  # or one neither does. Either way the entry no longer describes the ports, and
  # leaving it in place would excuse the next divergence to carry that name.
  # Only meaningful once something was actually compared. With no shared
  # coherency testcase in the two log trees the table had no chance to apply,
  # and calling every entry stale would be a verdict on the sweep, not the ports.
  stale = sorted(set(PORT_ONLY_C) - stated_used) if compared_tests else []
  if stale:
    print()
    print(f"{len(stale)} stated exception(s) no longer one-sided -- "
          f"delete the entry:")
    for counter in stale:
      print(f"  {counter} ({PORT_ONLY_C[counter][0]}-only)")

  if divergences:
    print()
    print(f"{len(divergences)} counter divergence(s) between the two ports:")
    for line in divergences:
      print(f"  {line}")
    print()
    print("The two ports judged the same stimulus differently. A counter that "
          "differs is a rule that ran in one port and not the other, or ran on "
          "a different set of events.")
    return 1

  if stale:
    return 1

  print()
  print("both ports judged every shared testcase identically")
  return 0


if __name__ == "__main__":
  sys.exit(main())
