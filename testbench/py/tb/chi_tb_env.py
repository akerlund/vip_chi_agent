################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of tb/chi_tb_env.sv (integrated RN-I <-> SN-F pair cut).
#
# Builds the active RN-I requester agent and the active SN-F completer agent on
# the two link endpoints, plus the per-channel observation FIFOs the directed
# tests consume and the virtual sequencer. The HN-I proxy topology, coverage,
# scoreboard and perf counters of the SV env are Tier C / later and dropped from
# this A2 cut.
#
# Per-agent vif/role come from ConfigDB: the harness publishes the two ChiBus
# handles as "rni_vif"/"snf_vif" (global), and this env re-publishes them scoped
# to each agent along with the fixed role. Per-agent cfg is set by the test.
#
################################################################################

from __future__ import annotations

import os

import cocotb
from cocotb.triggers import FallingEdge

from pyuvm import uvm_env, uvm_tlm_analysis_fifo, ConfigDB

from vip_chi_types_pkg import Role
from vip_chi_agent import vip_chi_agent
from chi_virtual_sequencer import chi_virtual_sequencer
from vip_chi_perf_counters import vip_chi_perf_counters
from vip_chi_scoreboard import vip_chi_scoreboard
from vip_chi_coverage import vip_chi_coverage
from sva.bind_chi import bind_chi


class chi_tb_env(uvm_env):

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.rni_agent = None
    self.snf_agent = None
    self.perf = None
    self.scoreboard = None
    self.coverage = None
    self.vseq = None
    self.rni_req_fifo = None
    self.rni_rsp_fifo = None
    self.rni_dat_fifo = None
    self.snf_req_fifo = None
    self.snf_rsp_fifo = None
    self.snf_dat_fifo = None

  def build_phase(self):
    rni_vif = ConfigDB().get(self, "", "rni_vif")
    snf_vif = ConfigDB().get(self, "", "snf_vif")
    self.rni_vif = rni_vif
    self.snf_vif = snf_vif

    ConfigDB().set(self, "rni_agent", "vif", rni_vif)
    ConfigDB().set(self, "rni_agent", "role", Role.RNI)
    ConfigDB().set(self, "snf_agent", "vif", snf_vif)
    ConfigDB().set(self, "snf_agent", "role", Role.SNF)

    self.rni_agent = vip_chi_agent("rni_agent", self)
    self.snf_agent = vip_chi_agent("snf_agent", self)
    self.perf = vip_chi_perf_counters("perf", self)
    self.scoreboard = vip_chi_scoreboard("scoreboard", self)
    self.coverage = vip_chi_coverage("coverage", self)
    # Link-layer protocol checkers, one per interface, mirroring the per-bind
    # vip_chi_sva instances in the SV harness. They are plain coroutines rather
    # than uvm_components: they watch nets, not analysis traffic.
    self.rni_sva = bind_chi(rni_vif, "rni_sva")
    self.snf_sva = bind_chi(snf_vif, "snf_sva")
    self.vseq = chi_virtual_sequencer("virtual_sequencer", self)

    self.rni_req_fifo = uvm_tlm_analysis_fifo("rni_req_fifo", self)
    self.rni_rsp_fifo = uvm_tlm_analysis_fifo("rni_rsp_fifo", self)
    self.rni_dat_fifo = uvm_tlm_analysis_fifo("rni_dat_fifo", self)
    self.snf_req_fifo = uvm_tlm_analysis_fifo("snf_req_fifo", self)
    self.snf_rsp_fifo = uvm_tlm_analysis_fifo("snf_rsp_fifo", self)
    self.snf_dat_fifo = uvm_tlm_analysis_fifo("snf_dat_fifo", self)

  def connect_phase(self):
    self.rni_agent.req_port.connect(self.rni_req_fifo.analysis_export)
    self.rni_agent.rsp_port.connect(self.rni_rsp_fifo.analysis_export)
    self.rni_agent.dat_port.connect(self.rni_dat_fifo.analysis_export)
    self.snf_agent.req_port.connect(self.snf_req_fifo.analysis_export)
    self.snf_agent.rsp_port.connect(self.snf_rsp_fifo.analysis_export)
    self.snf_agent.dat_port.connect(self.snf_dat_fifo.analysis_export)

    # Perf counters: subscribe to the integrated requester stream + take its vif
    # as the deterministic cycle/back-pressure source.
    self.rni_agent.req_port.connect(self.perf.req_perf)
    self.rni_agent.rsp_port.connect(self.perf.rsp_perf)
    self.rni_agent.dat_port.connect(self.perf.dat_perf)
    self.perf.vif = self.rni_agent.vif

    # Standalone scoreboard, connected in parallel to the same monitor ports:
    # the integrated requester view drives lifecycle/data checks, the completer
    # REQ view drives request-fidelity. The proxy hrni*/hsnf* imps stay unwired
    # in this integrated cut (single SN => routing check dormant).
    self.scoreboard.set_cfg(self.rni_agent.vif.cfg)
    self.rni_agent.req_port.connect(self.scoreboard.rni_req_sb)
    self.rni_agent.rsp_port.connect(self.scoreboard.rni_rsp_sb)
    self.rni_agent.dat_port.connect(self.scoreboard.rni_dat_sb)
    self.snf_agent.req_port.connect(self.scoreboard.snf_req_sb)

    # Functional coverage: RN-I + SN-F req/rsp/dat streams (mirrors SV chi_tb_env).
    self.coverage.set_cfg(self.rni_agent.vif.cfg)
    self.coverage.enabled = (
      self.rni_agent.cfg.coverage_enabled or self.snf_agent.cfg.coverage_enabled)
    self.rni_agent.req_port.connect(self.coverage.rni_req_cov_port)
    self.rni_agent.rsp_port.connect(self.coverage.rni_rsp_cov_port)
    self.rni_agent.dat_port.connect(self.coverage.rni_dat_cov_port)
    self.snf_agent.req_port.connect(self.coverage.snf_req_cov_port)
    self.snf_agent.rsp_port.connect(self.coverage.snf_rsp_cov_port)
    self.snf_agent.dat_port.connect(self.coverage.snf_dat_cov_port)

    tb_cfg = None
    try:
      tb_cfg = ConfigDB().get(self, "", "tb_cfg")
    except Exception:
      tb_cfg = None
    if tb_cfg is not None:
      self.perf.enable = tb_cfg.perf_enable
      self.scoreboard.enable = tb_cfg.scoreboard_enable
      self.scoreboard.check_data = tb_cfg.scoreboard_check_data
      self.scoreboard.check_order = tb_cfg.scoreboard_check_order
      # The checkers re-read tb_cfg every cycle rather than latching it here,
      # so a test may raise dat_reorder_allowed any time before its traffic.
      self.rni_sva.tb_cfg = tb_cfg
      self.snf_sva.tb_cfg = tb_cfg

    self.vseq.rni_sequencer = self.rni_agent.sequencer
    self.vseq.snf_sequencer = self.snf_agent.sequencer

  # ---------------------------------------------------------------------------
  # Watch the shared RN-I reset and forward it into local checker state.
  # ---------------------------------------------------------------------------
  async def run_phase(self):
    # The protocol checkers watch nets continuously and own their own reset
    # handling, so they are started once here rather than restarted by
    # handle_reset below.
    cocotb.start_soon(self.rni_sva.run())
    cocotb.start_soon(self.snf_sva.run())

    bus = self.rni_agent.vif
    while True:
      await FallingEdge(bus.rst_n)
      self.handle_reset()

  def report_phase(self):
    # pyUVM runs check_phase TOP-DOWN, unlike UVM, so an assertion placed there
    # can run before the components below have finished folding in their state.
    # report_phase is bottom-up and is where the port puts end-of-test asserts.
    # The TESTCASE name, not the env's: the aggregation's whole value is being
    # able to say which test exercised a rule, and every run would otherwise
    # carry the same label.
    csv_path = os.environ.get("VIP_CHI_CHECK_CSV", "")
    run_name = os.environ.get("VIP_CHI_TESTNAME", "") or "unknown"

    for checker in (self.rni_sva, self.snf_sva):
      checker.report(self.logger)
      if csv_path:
        checker.export_check_csv(csv_path, run_name)

    # The scoreboard's rules go into the SAME export, under its own bind name.
    # They were outside the mechanism entirely until now, which meant a
    # scoreboard check could stop evaluating and no report anywhere would say so.
    self.scoreboard.report_checks(self.logger)
    if csv_path:
      self.scoreboard.export_check_csv(csv_path, run_name)

    total = self.rni_sva.errors + self.snf_sva.errors
    assert total == 0, (
      f"CHI protocol checkers reported {total} violation(s): "
      f"rni_sva={self.rni_sva.errors} snf_sva={self.snf_sva.errors}")

  def handle_reset(self):
    self.coverage.handle_reset()
    self.scoreboard.handle_reset()
    self.perf.handle_reset()
