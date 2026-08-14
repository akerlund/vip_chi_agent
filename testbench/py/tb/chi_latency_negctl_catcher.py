################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of tb/chi_latency_negctl_catcher.sv.
#
# The SV component is a uvm_report_catcher; pyUVM reports through Python logging,
# so the analog is a logging.Filter attached to the monitor's logger. It demotes
# (drops) the deliberately-provoked latency-bound ERROR so the test does not
# print an error, and records that the monitor DID flag it.
#
################################################################################

from __future__ import annotations

import logging


class chi_latency_negctl_catcher(logging.Filter):

  def __init__(self, name="chi_latency_negctl_catcher"):
    super().__init__(name)
    self.saw_latency_error = False
    self.n_latency_errors = 0

  def filter(self, record):
    if record.levelno == logging.ERROR and \
       "exceeding the configured bound" in record.getMessage():
      self.saw_latency_error = True
      self.n_latency_errors += 1
      return False   # demote: keep the intentional error out of the log
    return True
