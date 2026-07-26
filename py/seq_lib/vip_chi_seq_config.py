################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of vip_chi_seq_config.sv -- sequence loop / delay / logging knobs.
#
################################################################################

from __future__ import annotations

import logging

VIP_CHI_UNLIMITED_REQUESTS = -1


class vip_chi_seq_config:

  def __init__(self, name: str = "vip_chi_seq_config"):
    self.name = name
    self.reset()

  def reset(self):
    self.requests = 1
    self.request_delay_enabled = False
    self.request_delay_min = 0
    self.request_delay_max = 0
    self.clock_period = 0.0
    self.verbose = True
    self.log_denominator = 100

  def log_status(self, request_idx, access_type, caller_name):
    # Progress logging on every log_denominator-th request (and the final one).
    # Mirrors SV vip_chi_seq_config::log_status; verdict-neutral.
    if not self.verbose:
      return
    last = (self.requests != VIP_CHI_UNLIMITED_REQUESTS
            and request_idx == self.requests - 1)
    if (request_idx % self.log_denominator) != 0 and not last:
      return
    logger = logging.getLogger(caller_name)
    if self.requests == VIP_CHI_UNLIMITED_REQUESTS:
      logger.info(f"INFO [{caller_name}] {access_type} ({request_idx + 1})")
    else:
      logger.info(
        f"INFO [{caller_name}] {access_type} ({request_idx + 1}/{self.requests})")
