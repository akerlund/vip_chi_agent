################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of tb/vip_chi_coherent_tb_env.sv -- the isolated coherent env: two
# coherent RN-F requesters fan into a single HN-F home that also straddles one
# downstream SN-F link:
#
#   hrnf{0,1}_agent (RN-F) --> HN-F home (vip_chi_hnf_agent, 2 RN ports) --> dsnf0 (SN-F)
#
# Standalone (no virtual sequencer): tests start sequences directly on
# hrnf{0,1}_agent.sequencer. The RN-F agents observe the outer links; the HN-F is
# autonomous; perf + coherency_checker + coverage subscribe to the requester
# streams (always-on, advisory). The harness publishes six ChiBus handles
# (hrnf0_/hrnf1_/hnfr0_/hnfr1_/hnfs0_/dsnf0_ vifs); this env wires them up.
#
################################################################################

from __future__ import annotations

from cocotb.triggers import FallingEdge

from pyuvm import uvm_env, uvm_tlm_analysis_fifo, ConfigDB

from vip_chi_types_pkg import Role
from vip_chi_agent import vip_chi_agent
from vip_chi_hnf_agent import vip_chi_hnf_agent
from vip_chi_cfg_agent import VipChiCfgAgent
from vip_chi_perf_counters import vip_chi_perf_counters
from vip_chi_coherency_checker import vip_chi_coherency_checker
from vip_chi_coverage import vip_chi_coverage


class vip_chi_coherent_tb_env(uvm_env):

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.hrnf0_agent = None
    self.hrnf1_agent = None
    self.hnf_agent = None
    self.dsnf0_agent = None
    self.perf = None
    self.coh_checker = None
    self.cov = None
    self.hrnf0_req_fifo = None
    self.hrnf0_rsp_fifo = None
    self.hrnf0_dat_fifo = None
    self.hrnf0_snp_fifo = None
    self.dsnf0_req_fifo = None
    self._rn_buses = None
    self._sn_buses = None

  def build_phase(self):
    hrnf0_vif = ConfigDB().get(self, "", "hrnf0_vif")
    hrnf1_vif = ConfigDB().get(self, "", "hrnf1_vif")
    hnfr0_vif = ConfigDB().get(self, "", "hnfr0_vif")
    hnfr1_vif = ConfigDB().get(self, "", "hnfr1_vif")
    hnfs0_vif = ConfigDB().get(self, "", "hnfs0_vif")
    dsnf0_vif = ConfigDB().get(self, "", "dsnf0_vif")
    self._rn_buses = [hnfr0_vif, hnfr1_vif]
    self._sn_buses = [hnfs0_vif]

    ConfigDB().set(self, "hrnf0_agent", "vif", hrnf0_vif)
    ConfigDB().set(self, "hrnf0_agent", "role", Role.RNF)
    ConfigDB().set(self, "hrnf1_agent", "vif", hrnf1_vif)
    ConfigDB().set(self, "hrnf1_agent", "role", Role.RNF)
    ConfigDB().set(self, "dsnf0_agent", "vif", dsnf0_vif)
    ConfigDB().set(self, "dsnf0_agent", "role", Role.SNF)

    self.hrnf0_agent = vip_chi_agent("hrnf0_agent", self)
    self.hrnf1_agent = vip_chi_agent("hrnf1_agent", self)
    self.dsnf0_agent = vip_chi_agent("dsnf0_agent", self)

    self.hnf_agent = vip_chi_hnf_agent("hnf_agent", self)
    try:
      self.hnf_agent.cfg = ConfigDB().get(self, "", "hnf_cfg")
    except Exception:
      self.hnf_agent.cfg = VipChiCfgAgent("hnf_cfg")
      self.hnf_agent.cfg.role = Role.HNF

    self.perf = vip_chi_perf_counters("perf", self)
    self.coh_checker = vip_chi_coherency_checker("coh_checker", self)
    self.cov = vip_chi_coverage("cov", self)

    self.hrnf0_req_fifo = uvm_tlm_analysis_fifo("hrnf0_req_fifo", self)
    self.hrnf0_rsp_fifo = uvm_tlm_analysis_fifo("hrnf0_rsp_fifo", self)
    self.hrnf0_dat_fifo = uvm_tlm_analysis_fifo("hrnf0_dat_fifo", self)
    self.hrnf0_snp_fifo = uvm_tlm_analysis_fifo("hrnf0_snp_fifo", self)
    self.dsnf0_req_fifo = uvm_tlm_analysis_fifo("dsnf0_req_fifo", self)

  def connect_phase(self):
    # Requester-side observation (port 0).
    self.hrnf0_agent.req_port.connect(self.hrnf0_req_fifo.analysis_export)
    self.hrnf0_agent.rsp_port.connect(self.hrnf0_rsp_fifo.analysis_export)
    self.hrnf0_agent.dat_port.connect(self.hrnf0_dat_fifo.analysis_export)
    self.hrnf0_agent.snp_port.connect(self.hrnf0_snp_fifo.analysis_export)

    # Downstream SN-F REQ observation (proves the HN-F issued ReadNoSnp/WriteNoSnp).
    self.dsnf0_agent.req_port.connect(self.dsnf0_req_fifo.analysis_export)

    # Checker D end-to-end integrity across the downstream fetch.
    self.dsnf0_agent.req_port.connect(self.coh_checker.snf_req_cc)
    self.dsnf0_agent.dat_port.connect(self.coh_checker.snf_dat_cc)

    # Perf counters: subscribe to requester port 0 + take its vif as the source.
    self.hrnf0_agent.req_port.connect(self.perf.req_perf)
    self.hrnf0_agent.rsp_port.connect(self.perf.rsp_perf)
    self.hrnf0_agent.dat_port.connect(self.perf.dat_perf)
    self.perf.vif = self.hrnf0_agent.vif

    # Checker D (coherency invariants): both RN-F streams (req/rsp/dat/snp).
    self.hrnf0_agent.req_port.connect(self.coh_checker.rnf0_req_cc)
    self.hrnf0_agent.rsp_port.connect(self.coh_checker.rnf0_rsp_cc)
    self.hrnf0_agent.dat_port.connect(self.coh_checker.rnf0_dat_cc)
    self.hrnf0_agent.snp_port.connect(self.coh_checker.rnf0_snp_cc)
    self.hrnf1_agent.req_port.connect(self.coh_checker.rnf1_req_cc)
    self.hrnf1_agent.rsp_port.connect(self.coh_checker.rnf1_rsp_cc)
    self.hrnf1_agent.dat_port.connect(self.coh_checker.rnf1_dat_cc)
    self.hrnf1_agent.snp_port.connect(self.coh_checker.rnf1_snp_cc)
    self.coh_checker.set_cfg(self.hrnf0_agent.vif.cfg)

    # Coherent functional coverage: both RN-F requester streams.
    for ag in (self.hrnf0_agent, self.hrnf1_agent):
      ag.req_port.connect(self.cov.rnf_req_cov_port)
      ag.rsp_port.connect(self.cov.rnf_rsp_cov_port)
      ag.dat_port.connect(self.cov.rnf_dat_cov_port)
      ag.snp_port.connect(self.cov.snp_cov_port)
    self.cov.set_cfg(self.hrnf0_agent.vif.cfg)
    self.cov.enabled = (self.hrnf0_agent.cfg.coverage_enabled or
                        self.hrnf1_agent.cfg.coverage_enabled)

    # Hand the HN-F home its RN-/SN-facing bus lists (driver built by the agent).
    self.hnf_agent.hnf_driver.rn_buses = self._rn_buses
    self.hnf_agent.hnf_driver.sn_buses = self._sn_buses

    tb_cfg = None
    try:
      tb_cfg = ConfigDB().get(self, "", "tb_cfg")
    except Exception:
      tb_cfg = None
    if tb_cfg is not None:
      self.perf.enable = tb_cfg.perf_enable

  async def run_phase(self):
    bus = self.hrnf0_agent.vif
    while True:
      await FallingEdge(bus.rst_n)
      self.handle_reset()

  def handle_reset(self):
    self.perf.handle_reset()
    self.coh_checker.handle_reset()
    self.cov.handle_reset()
