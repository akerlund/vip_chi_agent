################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of tb/vip_chi_coherency_negctl_catcher.sv.
#
# The SV component is a uvm_report_catcher; the pyUVM analog is a logging.Filter
# attached to the coherency checker's logger. It demotes (drops) a deliberately-
# induced Checker-D ERROR -- "COHERENCY VIOLATION" (multi-owner / data-integrity /
# bad-MakeUnique) or "EXCLUSIVE VIOLATION" (the LL/SC invariant) -- so the negative
# control does not print an error, and records that Checker D DID flag it (proving
# the invariant is not a no-op). The specific test disambiguates via the matching
# per-invariant counter (get_multi_owner_count / get_excl_violation_count / ...).
#
################################################################################

from __future__ import annotations

import logging


class vip_chi_coherency_negctl_catcher(logging.Filter):

  def __init__(self, name="vip_chi_coherency_negctl_catcher"):
    super().__init__(name)
    self.saw_coherency_error = False

  def filter(self, record):
    if record.levelno == logging.ERROR:
      msg = record.getMessage()
      if "COHERENCY VIOLATION" in msg or "EXCLUSIVE VIOLATION" in msg:
        self.saw_coherency_error = True
        return False   # demote: keep the intentional error out of the log
    return True
