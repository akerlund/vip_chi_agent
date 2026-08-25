################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of the CHI-E HN-I proxy env (Wave 6): a wide-CHI-E RN-I requester
# (hrni0) <-> HN-I proxy <-> wide-CHI-E SN-F completer (hsnf0). The CHI-D proxy
# topology re-cast at CHI_E_WIDE_CFG. The proxy driver (vip_chi_driver_hni) is a
# pure per-flit verbatim relay -- config-agnostic -- so it needs no _e subclass;
# only the flit shapes widen. The single ported E HN-I test (passthrough) drives
# port 0, so this env carries a single RN/SN pair.
#
################################################################################

from __future__ import annotations

import os

import cocotb
from cocotb.triggers import FallingEdge

from pyuvm import uvm_env, uvm_tlm_analysis_fifo, ConfigDB

from vip_chi_types_pkg import Role
from vip_chi_agent import vip_chi_agent
from vip_chi_hni_agent import vip_chi_hni_agent
from sva.bind_chi import bind_chi
from vip_chi_cfg_agent import VipChiCfgAgent
from vip_chi_coverage import vip_chi_coverage
from vip_chi_scoreboard import vip_chi_scoreboard
from vip_chi_perf_counters import vip_chi_perf_counters


class chi_e_proxy_tb_env(uvm_env):

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.hrni0_agent = None
    self.hsnf0_agent = None
    self.coverage = None
    self.scoreboard = None
    self.perf = None
    self.hni_agent = None
    self.hni = None            # convenience alias -> hni_agent.hni_driver (set in connect_phase)
    self._rn_buses = None
    self._sn_buses = None
    self.hrni0_req_fifo = None
    self.hrni0_rsp_fifo = None
    self.hrni0_dat_fifo = None
    self.hsnf0_req_fifo = None
    self.hni_sva = []

  def build_phase(self):
    rni_vif = ConfigDB().get(self, "", "rni_vif")
    snf_vif = ConfigDB().get(self, "", "snf_vif")
    hrn_vif = ConfigDB().get(self, "", "hrn_vif")
    hsn_vif = ConfigDB().get(self, "", "hsn_vif")

    ConfigDB().set(self, "hrni0_agent", "vif", rni_vif)
    ConfigDB().set(self, "hrni0_agent", "role", Role.RNI)
    ConfigDB().set(self, "hsnf0_agent", "vif", snf_vif)
    ConfigDB().set(self, "hsnf0_agent", "role", Role.SNF)

    self.hrni0_agent = vip_chi_agent("hrni0_agent", self)
    self.hsnf0_agent = vip_chi_agent("hsnf0_agent", self)
    self.coverage = vip_chi_coverage("coverage", self)
    self.scoreboard = vip_chi_scoreboard("scoreboard", self)
    self.perf = vip_chi_perf_counters("perf", self)

    self.hni_agent = vip_chi_hni_agent("hni", self)
    self._rn_buses = [hrn_vif]
    self._sn_buses = [hsn_vif]

    # The HN-I proxy topology's binds, added. A grep for
    # bind_chi in this file returned zero: not a disabled checker, no checker at
    # all. The scoreboard ran; the link and protocol layer did not.
    #
    # Both ends of each link, matching the SV harness and for the same stated
    # reason: a link's two views are the same wires at opposite polarity, and the
    # direction-split rules each run at only one of them. Roles come off the
    # buses, which already have them right -- the proxy's RN-facing port is HN-I
    # (a completer) and its SN-facing port RN-I (a requester).
    #
    # FOUR binds here against the SV harness's eight, and that is a topology
    # difference rather than a parity gap: this port's CHI-E proxy is 1x1 where
    # SV's is 2x2, so ports rni1/rn1/sn1/snf1 do not exist to bind. The names
    # match SV's port-0 set exactly, so the aggregation joins them.
    self.hni_sva = [
      bind_chi(rni_vif, "e_hni_rni0_sva"),
      bind_chi(hrn_vif, "e_hni_rn0_sva", txsactive_from_link_up=True),
      bind_chi(hsn_vif, "e_hni_sn0_sva", txsactive_from_link_up=True,
               multi_source_link=True),
      bind_chi(snf_vif, "e_hni_snf0_sva", multi_source_link=True),
    ]
    try:
      self.hni_agent.cfg = ConfigDB().get(self, "", "hni_cfg")
    except Exception:
      self.hni_agent.cfg = VipChiCfgAgent("hni_cfg")
      self.hni_agent.cfg.role = Role.HNI

    self.hrni0_req_fifo = uvm_tlm_analysis_fifo("hrni0_req_fifo", self)
    self.hrni0_rsp_fifo = uvm_tlm_analysis_fifo("hrni0_rsp_fifo", self)
    self.hrni0_dat_fifo = uvm_tlm_analysis_fifo("hrni0_dat_fifo", self)
    self.hsnf0_req_fifo = uvm_tlm_analysis_fifo("hsnf0_req_fifo", self)

  def connect_phase(self):
    self.hrni0_agent.req_port.connect(self.hrni0_req_fifo.analysis_export)
    self.hrni0_agent.rsp_port.connect(self.hrni0_rsp_fifo.analysis_export)
    self.hrni0_agent.dat_port.connect(self.hrni0_dat_fifo.analysis_export)
    self.hsnf0_agent.req_port.connect(self.hsnf0_req_fifo.analysis_export)

    # Functional coverage: hrni0 req/rsp/dat + hsnf0 req (mirrors SV e_proxy env).
    self.coverage.set_cfg(self.hrni0_agent.vif.cfg)
    self.coverage.enabled = (
      self.hrni0_agent.cfg.coverage_enabled or self.hsnf0_agent.cfg.coverage_enabled)
    self.hrni0_agent.req_port.connect(self.coverage.rni_req_cov_port)
    self.hrni0_agent.rsp_port.connect(self.coverage.rni_rsp_cov_port)
    self.hrni0_agent.dat_port.connect(self.coverage.rni_dat_cov_port)
    self.hsnf0_agent.req_port.connect(self.coverage.snf_req_cov_port)

    # Standalone scoreboard (mirrors SV e_proxy): requester lifecycle/data views
    # (hrni0) + completer REQ fidelity (hsnf0). This is a single RN/SN pair, so
    # the hrni1/hsnf1 imps stay unwired and Checker-B routing stays dormant
    # (n_sn_ports == 1); Checkers A (lifecycle) and C (data) still run.
    self.scoreboard.set_cfg(self.hrni0_agent.vif.cfg)
    self.hrni0_agent.req_port.connect(self.scoreboard.hrni0_req_sb)
    self.hrni0_agent.rsp_port.connect(self.scoreboard.hrni0_rsp_sb)
    self.hrni0_agent.dat_port.connect(self.scoreboard.hrni0_dat_sb)
    self.hsnf0_agent.req_port.connect(self.scoreboard.hsnf0_req_sb)

    # Perf counters on the RN0 requester stream (report-only, mirrors SV e_proxy).
    self.hrni0_agent.req_port.connect(self.perf.req_perf)
    self.hrni0_agent.rsp_port.connect(self.perf.rsp_perf)
    self.hrni0_agent.dat_port.connect(self.perf.dat_perf)
    self.perf.vif = self.hrni0_agent.vif

    tb_cfg = None
    try:
      tb_cfg = ConfigDB().get(self, "", "tb_cfg")
    except Exception:
      tb_cfg = None
    if tb_cfg is not None:
      self.perf.enable = tb_cfg.perf_enable
      self.scoreboard.enable = tb_cfg.scoreboard_enable
      self.scoreboard.check_data = tb_cfg.scoreboard_check_data

    # The HN-I driver is built inside hni_agent (build_phase); assign its link
    # buses now and expose it as self.hni for the tests' configure_hni() hook.
    self.hni = self.hni_agent.hni_driver
    self.hni.rn_buses = self._rn_buses
    self.hni.sn_buses = self._sn_buses

  def start_of_simulation_phase(self):
    # Install the routing policy after the test's configure_hni(); single SN here
    # so n_sn_ports == 1 keeps Checker-B routing dormant.
    self.scoreboard.set_route_policy(
      len(self._sn_buses), self.hni.sn_addr_lsb, self.hni.sam)

  async def run_phase(self):
    # The protocol checkers watch nets continuously and own their own reset
    # handling, so they are started once here rather than restarted below.
    for checker in self.hni_sva:
      cocotb.start_soon(checker.run())

    bus = self.hrni0_agent.vif
    while True:
      await FallingEdge(bus.rst_n)
      self.handle_reset()

  def report_phase(self):
    csv_path = os.environ.get("VIP_CHI_CHECK_CSV", "")
    # The opcode-evidence companion. Same switch as the tally export: a run
    # with no CSV configured writes neither.
    opcode_csv = os.environ.get("VIP_CHI_OPCODE_CSV", "")
    run_name = os.environ.get("VIP_CHI_TESTNAME", "") or "unknown"
    self.scoreboard.report_checks(self.logger)
    if csv_path:
      self.scoreboard.export_check_csv(csv_path, run_name)
    for checker in self.hni_sva:
      checker.report(self.logger)
      if csv_path:
        checker.export_check_csv(csv_path, run_name)
      if opcode_csv:
        checker.export_opcode_csv(opcode_csv, run_name)
    total = sum(checker.errors for checker in self.hni_sva)
    assert total == 0, (
      f"CHI protocol checkers reported {total} violation(s) on the HN-I proxy "
      "links: " + " ".join(f"{c.log.name}={c.errors}" for c in self.hni_sva if c.errors))

  def handle_reset(self):
    self.coverage.handle_reset()
    self.scoreboard.handle_reset()
    self.perf.handle_reset()
