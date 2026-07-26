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

from cocotb.triggers import FallingEdge

from pyuvm import uvm_env, uvm_tlm_analysis_fifo, ConfigDB

from vip_chi_types_pkg import Role
from vip_chi_agent import vip_chi_agent
from vip_chi_hni_agent import vip_chi_hni_agent
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
    bus = self.hrni0_agent.vif
    while True:
      await FallingEdge(bus.rst_n)
      self.handle_reset()

  def handle_reset(self):
    self.coverage.handle_reset()
    self.scoreboard.handle_reset()
    self.perf.handle_reset()
