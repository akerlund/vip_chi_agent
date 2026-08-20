################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# The waiver for the wide-operand atomic stress profile, in one place, and it
# proves itself.
#
# vip_chi_atomic_seq records a deliberate decision: atomic Size is not clamped by
# default, and the atomic testcases drive `set_size(clog2(data_bytes))` -- Size 4
# (16 B) on the CHI-D cut -- "to exercise the operand DAT / RMW / return datapath
# at the widest beat". IHI 0050 E Table 2-17 / D Table 2-17 permits at most 8
# bytes for AtomicStore, AtomicLoad and AtomicSwap, so every one of those requests
# carries a Size the specification does not list for it.
#
# That was invisible until CHI_ATOMIC_SIZE_LEGAL existed. Now it reports, and the
# five testcases holding the stress profile have to say so.
#
# Two halves, and the second is the point:
#
#   arm()     turns the rule down to OFF on every checker the testcase owns. OFF
#             still EVALUATES and still COUNTS -- it only suppresses the report --
#             which is what makes the second half possible. disable_check() would
#             stop the counting and leave nothing to assert on, and it would
#             publish enabled=0, so the vacuity report would read the rule as one
#             nothing ever reached rather than one deliberately not enforced here.
#
#   assert_reported()  requires that the rule DID fire. A silenced rule that
#             stopped firing -- because the sequence changed, or the classifier
#             regressed, or the size default moved -- would otherwise look exactly
#             like a passing test. This turns each waiver into its own negative
#             control: the testcase asserts that its traffic is out of spec in the
#             way it claims to be.
#
# If a testcase is ever changed to drive spec-legal operand sizes, assert_reported
# fails and the waiver comes out with it. That is the intended failure mode.
################################################################################

from __future__ import annotations

RULE_C = "CHI_ATOMIC_SIZE_LEGAL"


def arm(checkers) -> None:
  """Turn CHI_ATOMIC_SIZE_LEGAL down to OFF on each checker, keeping the tally."""
  for checker in checkers:
    checker.off_check(RULE_C)


def reported(checkers) -> int:
  """Total CHI_ATOMIC_SIZE_LEGAL reports across the given checkers."""
  return sum(c.fail_count.get(RULE_C, 0) for c in checkers)


def assert_reported(checkers, what: str) -> int:
  """Require the rule to have fired, and say what it means if it did not."""
  n = reported(checkers)
  assert n > 0, (
    f"{RULE_C} recorded no violation across {what}, but this testcase drives the "
    f"wide-operand stress profile on purpose and its Sizes are out of spec by "
    f"Table 2-17. Either the stimulus now uses legal sizes -- in which case drop "
    f"the waiver -- or the rule stopped evaluating, which is worse")
  return n
