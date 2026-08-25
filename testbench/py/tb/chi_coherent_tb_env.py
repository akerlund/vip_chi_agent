################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of tb/chi_coherent_tb_env.sv -- the isolated coherent env: two
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

import os

import cocotb
from cocotb.triggers import FallingEdge

from pyuvm import uvm_env, uvm_tlm_analysis_fifo, ConfigDB

from sva.bind_chi import bind_chi
from sva.bind_chi_snp import bind_chi_snp
from vip_chi_types_pkg import Role
from vip_chi_agent import vip_chi_agent
from vip_chi_hnf_agent import vip_chi_hnf_agent
from vip_chi_cfg_agent import VipChiCfgAgent
from vip_chi_perf_counters import vip_chi_perf_counters
from vip_chi_coherency_checker import vip_chi_coherency_checker
from vip_chi_coverage import vip_chi_coverage


class chi_coherent_tb_env(uvm_env):

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.hrnf0_agent = None
    self.hrnf1_agent = None
    self.hnf_agent = None
    self.dsnf0_agent = None
    self.perf = None
    self.coh_checker = None
    self.cov = None
    self.rnf_sva = []
    self.hnfr_sva = []
    self.snp_sva = []
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

    # Protocol checkers, mirroring the coherent binds in the SV harness.
    #
    # REQ/RSP/DAT is watched from the RN-F end only. The RN-F endpoint sees the
    # full link traffic, and the HN-F end of the same wires would report every
    # violation a second time.
    #
    # The completion timeout stands down here, as it does on the SV coherent
    # binds: an HN-F may complete a request from another RN-F's snoop data, so a
    # request and its completion are not both visible on any one link and a
    # timeout would fire on correct traffic.
    #
    # The checker's name becomes the `bind` column of the exported tallies, and
    # that column is the only thing saying WHERE a rule ran. This env serves both
    # coherent topologies -- the CHI-E harness publishes the wide bus to the same
    # class -- so a literal name would export the CHI-E interfaces' tallies under
    # the CHI-D names, and "was this rule ever exercised on CHI-E coherent
    # traffic" would be unanswerable from the artifact that exists to answer it.
    # Derive the prefix from the bus's own config instead.
    pfx = "e_" if hrnf0_vif.cfg.is_e else ""
    self.rnf_sva = [
      bind_chi(hrnf0_vif, f"{pfx}hrnf0_sva", enable_completion_timeout=False),
      bind_chi(hrnf1_vif, f"{pfx}hrnf1_sva", enable_completion_timeout=False),
      # The downstream SN-F link, added: the HN-F's SN-facing port
      # and the SN-F endpoint behind it. It carries the memory traffic of every
      # coherent read miss and was checked by nothing, in either port.
      #
      # Both ends, because a link's two views are the same wires at opposite
      # polarity and the direction-split rules each run at only one of them --
      # TX/RX DAT burst shape and DataID ordering, requester-side TxnID reuse
      # against completer-side.
      #
      # The completion timeout stays ON here, unlike the RN-F links above. It is
      # off there because the HN-F may answer from another RN-F's snoop data, so
      # a completion is not visible end to end on one interface. Downstream it is:
      # the HN-F's ReadNoSnp and the SN-F's CompData are both on this link.
      # The HN-F's SN-facing port drives TXSACTIVE from sn_link_up, the same
      # shape the HN-I uses, so the same stand-down applies -- #, which named HN-F and HN-I together and had no evidence for
      # either because neither endpoint was bound.
      bind_chi(hnfs0_vif, f"{pfx}hnf0_sn_sva", txsactive_from_link_up=True),
      bind_chi(dsnf0_vif, f"{pfx}dsnf0_sva"),
      # The MAIN range on the HN-F's RN-facing ports. Those endpoints carried
      # only the SNP bind below, which has no TXSACTIVE property, so the
      # sideband of the role accuses was watched from neither
      # direction -- the RN-F bind opposite judges its OWN txsactive, on a
      # different interface.
      #
      # The completion timeout is OFF, for the reason given for the RN-F links
      # above: the HN-F may answer from another RN-F's snoop data, so a
      # completion is not visible end to end on one interface.
    ]

    # The HN-F's RN-facing ports, in a named list as well as in rnf_sva: a test
    # that has to waive a rule at THIS endpoint should say so by name rather
    # than by position.
    #
    # CHI_TXSACTIVE_DEASSERT_BOUNDED is NOT stood down here. It was, briefly,
    # while rn_credit_loop still drove txsactive from rn_link_up every cycle --
    # the sideband never dropped and the rule reported a signal carrying no
    # information, correctly. The driver now drives it from a counted window with
    # a single owner, so the rule has something real to judge and judges it.
    self.hnfr_sva = [
      bind_chi(hnfr0_vif, f"{pfx}hnfr0_sva", enable_completion_timeout=False),
      bind_chi(hnfr1_vif, f"{pfx}hnfr1_sva", enable_completion_timeout=False),
    ]
    self.rnf_sva += self.hnfr_sva
    # SNP is watched from BOTH ends, because each end exercises a different half
    # of the channel: the HN-F side drives snoops and its txsnp send-credit
    # shadow, the RN-F side receives them and shadows rxsnp.
    self.snp_sva = [
      bind_chi_snp(hnfr0_vif, f"{pfx}hnfr0_snp_sva"),
      bind_chi_snp(hnfr1_vif, f"{pfx}hnfr1_snp_sva"),
      bind_chi_snp(hrnf0_vif, f"{pfx}hrnf0_snp_sva"),
      bind_chi_snp(hrnf1_vif, f"{pfx}hrnf1_snp_sva"),
    ]

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
    self.coh_checker.hazard_check_enable = self.hrnf0_agent.cfg.hazard_check_enable

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
      # Re-read every cycle rather than latched here, so a test may raise
      # dat_reorder_allowed any time before its traffic starts.
      for checker in self.rnf_sva:
        checker.tb_cfg = tb_cfg

  async def run_phase(self):
    # The protocol checkers watch nets continuously and own their own reset
    # handling, so they are started once here rather than restarted below.
    for checker in self.rnf_sva + self.snp_sva:
      cocotb.start_soon(checker.run())

    bus = self.hrnf0_agent.vif
    while True:
      await FallingEdge(bus.rst_n)
      self.handle_reset()

  def report_phase(self):
    # pyUVM runs check_phase TOP-DOWN, unlike UVM, so an assertion placed there
    # can run before the components below have finished folding in their state.
    # report_phase is bottom-up and is where the port puts end-of-test asserts.
    checkers = self.rnf_sva + self.snp_sva
    # The CSV export, which this env never did. The omission was invisible in
    # exactly the way the mechanism exists to prevent: the aggregation reported
    # on the rules it had rows for and said nothing about the SNP rules it had
    # never been given, so a report covering the non-coherent binds alone read as
    # a report on all of them.
    csv_path = os.environ.get("VIP_CHI_CHECK_CSV", "")
    run_name = os.environ.get("VIP_CHI_TESTNAME", "") or "unknown"
    for checker in checkers:
      checker.report(self.logger)
      if csv_path:
        checker.export_check_csv(csv_path, run_name)
    total = sum(checker.errors for checker in checkers)
    assert total == 0, (
      f"CHI protocol checkers reported {total} violation(s): "
      + " ".join(f"{c.log.name}={c.errors}" for c in checkers if c.errors))

  def handle_reset(self):
    self.perf.handle_reset()
    self.coh_checker.handle_reset()
    self.cov.handle_reset()
