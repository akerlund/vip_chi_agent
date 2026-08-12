################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of tb/chi_pcrd_leak_negctl_catcher.sv.
#
# The SV component is a uvm_report_catcher; pyUVM reports through Python logging,
# so the analog is a logging.Filter attached to the RN-I driver's logger. It
# demotes the end-of-test P-credit leak ERROR that tc_chi_pcrd_leak induces on
# purpose and records that the driver DID report it, so the test can assert the
# credit accounting is not vacuous without the intentional error reading as a
# real failure.
#
# Demoted in place rather than dropped: the line still prints, at INFO, so the
# evidence that the leak was detected stays in the log.
#
################################################################################

from __future__ import annotations

import logging


class chi_pcrd_leak_negctl_catcher(logging.Filter):

  def __init__(self, name="chi_pcrd_leak_negctl_catcher"):
    super().__init__(name)
    self.saw_leak_error = False

  def filter(self, record):
    if record.levelno >= logging.ERROR and \
       "were granted and never consumed" in record.getMessage():
      self.saw_leak_error = True
      record.levelno = logging.INFO
      record.levelname = "INFO"
    return True
