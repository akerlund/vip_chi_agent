################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of tb/chi_tb_config.sv.
#
# The shared TB harness config the testcase owns and publishes once. It gates the
# standalone scoreboard and perf-counter instrumentation and carries the optional
# CHI-E wide-datapath enable + one-shot reset-pulse request. Published via
# ConfigDB (like the SV uvm_config_db handover) and read by the env in
# connect_phase.
#
################################################################################

from __future__ import annotations


class chi_tb_config:

  def __init__(self, name="chi_tb_config"):
    self.name = name
    self.reset()

  def reset(self):
    # Enable the wide CHI-E datapath link (set by chi_e_base_test).
    self.run_e_wide_integrated = False
    # One-shot, test-requested mid-run reset pulse length in cycles.
    self.reset_pulse_cycles = 0
    # Standalone scoreboard gating (a test may disable it in configure_tb_cfg()).
    self.scoreboard_enable = True
    self.scoreboard_check_data = True
    # Standalone perf-counter gating (always-on, opt-out per test).
    self.perf_enable = True
    # Stand the protocol checkers' DataID-ordering rules down. Only a test whose
    # completer deliberately emits DAT beats out of DataID order raises this;
    # the beat-count, TxnID and credit checks are unaffected either way.
    self.dat_reorder_allowed = False
    # Cycles a sender may keep TXSACTIVE asserted past the close of its
    # outstanding window. 0 (the default) is the tightest legal behaviour:
    # drop it as soon as the window closes. Raising it models a node that
    # keeps the sideband up speculatively, and widens the bound the
    # checkers allow.
    self.txsactive_extend_max_cycles = 0

  def request_reset_pulse(self, cycles=3):
    self.reset_pulse_cycles = max(1, int(cycles))
