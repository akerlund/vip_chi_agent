################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of tb/vip_chi_tb_config.sv.
#
# The shared TB harness config the testcase owns and publishes once. It gates the
# standalone scoreboard and perf-counter instrumentation and carries the optional
# CHI-E wide-datapath enable + one-shot reset-pulse request. Published via
# ConfigDB (like the SV uvm_config_db handover) and read by the env in
# connect_phase.
#
################################################################################

from __future__ import annotations


class vip_chi_tb_config:

  def __init__(self, name="vip_chi_tb_config"):
    self.name = name
    self.reset()

  def reset(self):
    # Enable the wide CHI-E datapath link (set by vip_chi_e_base_test).
    self.run_e_wide_integrated = False
    # One-shot, test-requested mid-run reset pulse length in cycles.
    self.reset_pulse_cycles = 0
    # Standalone scoreboard gating (a test may disable it in configure_tb_cfg()).
    self.scoreboard_enable = True
    self.scoreboard_check_data = True
    # Standalone perf-counter gating (always-on, opt-out per test).
    self.perf_enable = True

  def request_reset_pulse(self, cycles=3):
    self.reset_pulse_cycles = max(1, int(cycles))
