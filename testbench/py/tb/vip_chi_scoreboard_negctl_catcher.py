################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of tb/vip_chi_scoreboard_negctl_catcher.sv.
#
# The SV component is a uvm_report_catcher; pyUVM reports through Python logging,
# so the analog is a logging.Filter attached to the scoreboard's logger. It
# demotes (drops) the deliberately-injected "Orphan RSP (no open ctx)" ERROR so
# the negative control does not print an error, and records that the scoreboard
# DID flag it (proving Checker A is not a no-op). Returning False from a
# logger-level filter drops the record from every handler -- the pyUVM analog of
# the SV catcher demoting the severity below UVM_ERROR.
#
################################################################################

from __future__ import annotations

import logging


class vip_chi_scoreboard_negctl_catcher(logging.Filter):

  def __init__(self, name="vip_chi_scoreboard_negctl_catcher"):
    super().__init__(name)
    self.saw_orphan_error = False

  def filter(self, record):
    if record.levelno == logging.ERROR and \
       "Orphan RSP (no open ctx)" in record.getMessage():
      self.saw_orphan_error = True
      return False   # demote: keep the intentional error out of the log
    return True
