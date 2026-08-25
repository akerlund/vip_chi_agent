################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of tb/chi_coherency_negctl_catcher.sv.
#
# The SV component is a uvm_report_catcher; the pyUVM analog is a logging.Filter
# attached to the coherency checker's logger. It demotes (drops) a deliberately-
# induced Checker-D ERROR -- "COHERENCY VIOLATION" (multi-owner / data-integrity /
# bad-MakeUnique) or "EXCLUSIVE VIOLATION" (the LL/SC invariant) -- so the negative
# control does not print an error, and records that Checker D DID flag it (proving
# the invariant is not a no-op). The specific test disambiguates via the matching
# per-invariant counter (get_multi_owner_count / get_excl_violation_count / ...).
#
# The tally below is its counterpart, and the pair is what puts Checker D into
# the pyUVM verdict at all.
#
################################################################################

from __future__ import annotations

import logging

# The two prefixes every Checker-D violation is reported under. Kept in one place
# because the catcher and the tally must agree on what counts as a violation: a
# rule reported under a third prefix would be claimed by neither -- silently, and
# in the direction that reads as a pass.
_VIOLATION_PREFIXES = ("COHERENCY VIOLATION", "EXCLUSIVE VIOLATION")


def _is_violation(record) -> bool:
  if record.levelno != logging.ERROR:
    return False
  msg = record.getMessage()
  return any(p in msg for p in _VIOLATION_PREFIXES)


class chi_coherency_violation_tally(logging.Handler):
  """Counts the Checker-D violations that no negative control claimed.

  Checker D reports through its logger rather than through an error count, so
  this is what carries its verdict into the env's end-of-test assertion. The
  SystemVerilog port needs no equivalent: its violations are uvm_error and the
  regression script gates on "UVM_ERROR :    0".

  A HANDLER rather than a logger filter, and that is the mechanism rather than a
  detail of placement. Logging applies a logger's own filters first and stops at
  the first that rejects; only surviving records reach the handlers. The
  negative-control catcher above is a logger filter, so anything it demotes never
  arrives here -- leaving exactly the violations nobody asked for. Counting at
  the logger would count the deliberate ones too, and would depend on the order a
  test happened to add its catcher. A test that provokes a violation OUTSIDE the
  window it holds its catcher over is therefore still reported, which is wanted.

  Counted in emit() because a filter on a logging.NullHandler cannot work here:
  NullHandler overrides handle() with a stub, so its filters are never consulted
  and the count stays zero however many violations were reported.
  """

  def __init__(self, name="chi_coherency_violation_tally"):
    super().__init__()
    self.set_name(name)
    self.reported = 0

  def emit(self, record):
    if _is_violation(record):
      self.reported += 1

  # The record is counted, never rendered: the checker's own logger has already
  # printed it through the ordinary handlers.
  def format(self, record):
    return ""


class chi_coherency_negctl_catcher(logging.Filter):

  def __init__(self, name="chi_coherency_negctl_catcher"):
    super().__init__(name)
    self.saw_coherency_error = False
    # How many records this catcher demoted. A count rather than a flag, so a
    # test can hold it against the rule counter it also reads: if the two
    # disagree, either a report escaped the catcher or a counter moved without a
    # report, and both mean the control is measuring something other than what it
    # says. The SV twins make the same comparison through chi_sb_rule_negctl_catcher.
    self.claimed = 0

  def filter(self, record):
    if _is_violation(record):
      self.saw_coherency_error = True
      self.claimed += 1
      return False   # demote: keep the intentional error out of the log
    return True
