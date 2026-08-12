################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of tb/chi_dataid_negctl_catcher.sv.
#
# The SV component is a uvm_report_catcher; pyUVM reports through Python logging,
# so the analog is a logging.Filter attached to a monitor's logger. It demotes
# the two ERRORs a deliberately malformed DAT burst is expected to raise and
# records that the monitor DID report each of them, so the negative control can
# assert the DataID placement checks are not vacuous without the intentional
# errors reading as real failures.
#
# Demoted in place rather than dropped -- rewrite the record's level and let it
# through, as the SV catcher does with set_severity(UVM_INFO) and as
# tc_chi_pcrd_leak's catcher already does here. The evidence stays in the log
# where a reader can see the induced faults did occur; dropping the record would
# leave the run looking as though the burst had been well-formed.
#
# One instance may be attached to several monitors: the burst crosses the link,
# so both endpoints see the same two faults and both would otherwise report them.
#
################################################################################

from __future__ import annotations

import logging


class chi_dataid_negctl_catcher(logging.Filter):

  def __init__(self, name="chi_dataid_negctl_catcher"):
    super().__init__(name)
    self.saw_duplicate_error = False
    self.saw_missing_error = False

  def filter(self, record):
    if record.levelno < logging.ERROR:
      return True

    message = record.getMessage()
    if "duplicate DAT DataID" in message:
      self.saw_duplicate_error = True
    elif "closed with no beat carrying DataID" in message:
      self.saw_missing_error = True
    else:
      return True

    # Demote in place: the line still prints, but at INFO, so it neither reads
    # as a failure nor counts as one.
    record.levelno = logging.INFO
    record.levelname = "INFO"
    return True
