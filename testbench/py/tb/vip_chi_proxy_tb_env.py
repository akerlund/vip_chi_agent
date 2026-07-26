################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of the HN-I proxy env (Wave 6), sized to the SV vip_chi_tb_env
# proxy geometry: two dedicated RN-I requester agents feed the proxy's RN-facing
# ports and two dedicated SN-F responder agents sit behind its SN-facing ports,
# all straddled by a single multi-port HN-I proxy:
#
#   hrni{0,1}_agent (RN-I) --> HN-I proxy --> hsnf{0,1}_agent (SN-F)
#
# The agents monitor the outer links (rni{0,1}_ / snf{0,1}_) while the proxy
# relays flits across the inner ports (hrn{0,1}_ / hsn{0,1}_). Each SN-F sits on
# the far side, so hsnf{0,1}_req_fifo only see traffic the proxy actually
# forwarded to that SN target -- which is what the routing tests check.
#
################################################################################

from __future__ import annotations

from cocotb.triggers import FallingEdge

from pyuvm import uvm_env, uvm_tlm_analysis_fifo, ConfigDB

from vip_chi_types_pkg import Role
from vip_chi_agent import vip_chi_agent
from vip_chi_hni_agent import vip_chi_hni_agent
from vip_chi_cfg_agent import VipChiCfgAgent
from vip_chi_virtual_sequencer import vip_chi_virtual_sequencer
from vip_chi_scoreboard import vip_chi_scoreboard
from vip_chi_perf_counters import vip_chi_perf_counters


class vip_chi_proxy_tb_env(uvm_env):

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.hrni0_agent = None
    self.hrni1_agent = None
    self.hsnf0_agent = None
    self.hsnf1_agent = None
    self.hni_agent = None
    self.hni = None            # convenience alias -> hni_agent.hni_driver (set in connect_phase)
    self._rn_buses = None
    self._sn_buses = None
    self.scoreboard = None
    self.perf = None
    self.vseq = None
    self.hrni0_req_fifo = None
    self.hrni0_rsp_fifo = None
    self.hrni0_dat_fifo = None
    self.hrni1_req_fifo = None
    self.hrni1_rsp_fifo = None
    self.hrni1_dat_fifo = None
    self.hsnf0_req_fifo = None
    self.hsnf1_req_fifo = None

  def build_phase(self):
    rni0_vif = ConfigDB().get(self, "", "rni0_vif")
    rni1_vif = ConfigDB().get(self, "", "rni1_vif")
    snf0_vif = ConfigDB().get(self, "", "snf0_vif")
    snf1_vif = ConfigDB().get(self, "", "snf1_vif")
    hrn0_vif = ConfigDB().get(self, "", "hrn0_vif")
    hrn1_vif = ConfigDB().get(self, "", "hrn1_vif")
    hsn0_vif = ConfigDB().get(self, "", "hsn0_vif")
    hsn1_vif = ConfigDB().get(self, "", "hsn1_vif")

    ConfigDB().set(self, "hrni0_agent", "vif", rni0_vif)
    ConfigDB().set(self, "hrni0_agent", "role", Role.RNI)
    ConfigDB().set(self, "hrni1_agent", "vif", rni1_vif)
    ConfigDB().set(self, "hrni1_agent", "role", Role.RNI)
    ConfigDB().set(self, "hsnf0_agent", "vif", snf0_vif)
    ConfigDB().set(self, "hsnf0_agent", "role", Role.SNF)
    ConfigDB().set(self, "hsnf1_agent", "vif", snf1_vif)
    ConfigDB().set(self, "hsnf1_agent", "role", Role.SNF)

    self.hrni0_agent = vip_chi_agent("hrni0_agent", self)
    self.hrni1_agent = vip_chi_agent("hrni1_agent", self)
    self.hsnf0_agent = vip_chi_agent("hsnf0_agent", self)
    self.hsnf1_agent = vip_chi_agent("hsnf1_agent", self)

    self.hni_agent = vip_chi_hni_agent("hni", self)
    self._rn_buses = [hrn0_vif, hrn1_vif]
    self._sn_buses = [hsn0_vif, hsn1_vif]
    try:
      self.hni_agent.cfg = ConfigDB().get(self, "", "hni_cfg")
    except Exception:
      self.hni_agent.cfg = VipChiCfgAgent("hni_cfg")
      self.hni_agent.cfg.role = Role.HNI

    self.vseq = vip_chi_virtual_sequencer("virtual_sequencer", self)
    self.scoreboard = vip_chi_scoreboard("scoreboard", self)
    self.perf = vip_chi_perf_counters("perf", self)

    self.hrni0_req_fifo = uvm_tlm_analysis_fifo("hrni0_req_fifo", self)
    self.hrni0_rsp_fifo = uvm_tlm_analysis_fifo("hrni0_rsp_fifo", self)
    self.hrni0_dat_fifo = uvm_tlm_analysis_fifo("hrni0_dat_fifo", self)
    self.hrni1_req_fifo = uvm_tlm_analysis_fifo("hrni1_req_fifo", self)
    self.hrni1_rsp_fifo = uvm_tlm_analysis_fifo("hrni1_rsp_fifo", self)
    self.hrni1_dat_fifo = uvm_tlm_analysis_fifo("hrni1_dat_fifo", self)
    self.hsnf0_req_fifo = uvm_tlm_analysis_fifo("hsnf0_req_fifo", self)
    self.hsnf1_req_fifo = uvm_tlm_analysis_fifo("hsnf1_req_fifo", self)

  def connect_phase(self):
    self.hrni0_agent.req_port.connect(self.hrni0_req_fifo.analysis_export)
    self.hrni0_agent.rsp_port.connect(self.hrni0_rsp_fifo.analysis_export)
    self.hrni0_agent.dat_port.connect(self.hrni0_dat_fifo.analysis_export)
    self.hrni1_agent.req_port.connect(self.hrni1_req_fifo.analysis_export)
    self.hrni1_agent.rsp_port.connect(self.hrni1_rsp_fifo.analysis_export)
    self.hrni1_agent.dat_port.connect(self.hrni1_dat_fifo.analysis_export)
    self.hsnf0_agent.req_port.connect(self.hsnf0_req_fifo.analysis_export)
    self.hsnf1_agent.req_port.connect(self.hsnf1_req_fifo.analysis_export)

    self.vseq.hrni0_sequencer = self.hrni0_agent.sequencer
    self.vseq.hrni1_sequencer = self.hrni1_agent.sequencer
    self.vseq.hsnf0_sequencer = self.hsnf0_agent.sequencer
    self.vseq.hsnf1_sequencer = self.hsnf1_agent.sequencer

    # Standalone scoreboard (mirrors the proxy wiring in SV vip_chi_tb_env):
    # requester lifecycle/data views (both proxy RNs) + completer REQ fidelity/
    # route views (both proxy SNs). The integrated rni/snf imps stay unwired in
    # this dedicated proxy cut. The route policy is installed later (see
    # start_of_simulation_phase) so a test's configure_hni() SAM is captured.
    self.scoreboard.set_cfg(self.hrni0_agent.vif.cfg)
    self.hrni0_agent.req_port.connect(self.scoreboard.hrni0_req_sb)
    self.hrni0_agent.rsp_port.connect(self.scoreboard.hrni0_rsp_sb)
    self.hrni0_agent.dat_port.connect(self.scoreboard.hrni0_dat_sb)
    self.hrni1_agent.req_port.connect(self.scoreboard.hrni1_req_sb)
    self.hrni1_agent.rsp_port.connect(self.scoreboard.hrni1_rsp_sb)
    self.hrni1_agent.dat_port.connect(self.scoreboard.hrni1_dat_sb)
    self.hsnf0_agent.req_port.connect(self.scoreboard.hsnf0_req_sb)
    self.hsnf1_agent.req_port.connect(self.scoreboard.hsnf1_req_sb)

    # Perf counters on the RN0 requester stream (report-only, mirrors e_proxy).
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
    # Hand the scoreboard the proxy's exact routing policy (SN port count, stride
    # LSB, optional SAM). Runs after the test's connect_phase configure_hni(), so
    # any installed SAM is captured; n_sn_ports > 1 arms Checker-B routing.
    self.scoreboard.set_route_policy(
      len(self._sn_buses), self.hni.sn_addr_lsb, self.hni.sam)

  async def run_phase(self):
    bus = self.hrni0_agent.vif
    while True:
      await FallingEdge(bus.rst_n)
      self.handle_reset()

  def handle_reset(self):
    self.scoreboard.handle_reset()
    self.perf.handle_reset()
