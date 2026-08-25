#!/usr/bin/env python3
"""Compare what the two ports' coherency checkers JUDGED on the same testcase.

The four existing parity checks compare SURFACES. `check_type_parity.py` compares
enum values and flit field order, `check_cfg_parity.py` the config fields,
`check_opcodes.py` the opcode sets, `check_classifier_coverage.py` the
classifiers, `check_test_counts.py` the testcase lists. All five pass when the
two ports agree about what EXISTS. None of them looks at what the two ports
DECIDED when the same stimulus was put through them, and that is where the
divergences have actually been: the Python DAT hook never called check_snp_resp_state, so catalogue
             rule D5 judged 14 of 19 snoop responses on Python against SV's 19,
             and the with_data axis of an illegal_bins cross was unreachable
             there -- in the very commit that added it. Both numbers were printed
             in both sweeps. Nobody was comparing them. the FLITPEND negative control reaches a different set of drivers in
             each port, because eleven send sites announce inline. The knob
             EXISTS in both configs, spelled identically, so cfg parity passes.

That is four findings in this review where a parity check passed on something the
two ports do differently. The counters are the one artifact that is a function of
behaviour rather than of declarations, they are already printed by both flows,
and they were being compared by hand after every coherency change.

Scope, stated rather than implied: this reads the `COHERENCY ... SUMMARY:` lines
only. `PERF SUMMARY` is excluded because it reports cycle counts that the two
simulators have no reason to agree on, and the per-check tallies are compared by
check_vacuity.py against its own CSV. Extending this to a new summary line needs
nothing but emitting it from both ports in the same `field=value` form.

Fails closed. A testcase that exists in both flows and produced coherency
summaries in one and none in the other is a divergence, not a skip -- that is
precisely the shape of a case where the Python side was silent about
responses it never looked at.

Requires both flows to have been run. With neither log tree present it reports
that and exits 0, so it is safe to call from a sweep that has not run yet; with
exactly one present it exits 1, because a one-sided comparison that reports
success is the failure mode this check exists to remove.

Usage:
  python3 scripts/check_counter_parity.py
"""

from __future__ import annotations

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

# `COHERENCY <NAME> SUMMARY: field=value field=value ...`, anywhere on the line:
# both flows prefix it with their own report-server or logger decoration.
SUMMARY_RE = re.compile(r"(COHERENCY [A-Z0-9 _]*SUMMARY): (.*)$")
FIELD_RE = re.compile(r"([a-z0-9_]+)=(-?\d+)")


def counters_from(path: pathlib.Path) -> dict[str, int]:
  """Every field=value pair on the coherency summary lines of one log.

  Field names are unique across the summary lines by construction, so the
  summary a counter came from is not part of its key: moving a counter to a
  different (or new) summary line must not read as a divergence.
  """
  found: dict[str, int] = {}
  for line in path.read_text(errors="replace").splitlines():
    match = SUMMARY_RE.search(line)
    if not match:
      continue
    for name, value in FIELD_RE.findall(match.group(2)):
      found[name] = int(value)
  return found


def collect(log_dir: pathlib.Path, glob: str, strip: str) -> dict[str, dict[str, int]]:
  """Map testcase name -> its counters, for every log in one flow's directory."""
  out: dict[str, dict[str, int]] = {}
  if not log_dir.is_dir():
    return out
  for path in sorted(log_dir.glob(glob)):
    name = path.stem
    if strip and name.startswith(strip):
      name = name[len(strip):]
    out[name] = counters_from(path)
  return out


def main() -> int:
  sv = collect(SV_LOG_DIR, SV_LOG_GLOB, "vcs_")
  py = collect(PY_LOG_DIR, PY_LOG_GLOB, "")

  if not sv and not py:
    print("no regression logs in either flow; nothing to compare")
    print(f"  SV: {SV_LOG_DIR}")
    print(f"  PY: {PY_LOG_DIR}")
    return 0

  # One-sided is a failure, not a pass: a comparison with nothing to compare
  # against must not report agreement.
  if not sv or not py:
    missing = "SV" if not sv else "Python"
    print(f"only one flow has logs -- the {missing} regression has not been run")
    print(f"  SV: {len(sv)} log(s) under {SV_LOG_DIR}")
    print(f"  PY: {len(py)} log(s) under {PY_LOG_DIR}")
    return 1

  shared = sorted(set(sv) & set(py))
  print(f"testcases with logs in both flows: {len(shared)} "
        f"(SV {len(sv)}, Python {len(py)})")

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
        divergences.append(f"{name}: {counter} is Python-only "
                           f"(py={py_counters[counter]})")
        continue
      if counter not in py_counters:
        divergences.append(f"{name}: {counter} is SV-only "
                           f"(sv={sv_counters[counter]})")
        continue
      compared_counters += 1
      if sv_counters[counter] != py_counters[counter]:
        divergences.append(f"{name}: {counter} sv={sv_counters[counter]} "
                           f"py={py_counters[counter]}")

  print(f"testcases with coherency counters in both flows: {compared_tests}")
  print(f"counter values compared: {compared_counters}")

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

  print()
  print("both ports judged every shared testcase identically")
  return 0


if __name__ == "__main__":
  sys.exit(main())
