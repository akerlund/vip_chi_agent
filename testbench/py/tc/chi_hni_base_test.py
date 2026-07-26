################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# Base test for the HN-I proxy topology (Wave 6). Builds the 2 RN-facing x 2
# SN-facing proxy env (hrni{0,1} RN-I <-> HN-I <-> hsnf{0,1} SN-F), the per-agent
# cfgs (published via ConfigDB), and the reusable per-RN write/read sequences the
# directed tests drive on v_sqr.hrni{0,1}_sequencer.
#
# Tests override configure() (no args -- tweak self.hrni0_cfg / hrni1_cfg /
# hsnf0_cfg / hsnf1_cfg / hni_cfg before they publish) for cfg changes, and
# configure_hni() (given the HN-I driver, after the env builds it) to install a
# SAM or a QoS arbitration window.
#
################################################################################

from __future__ import annotations

from cocotb.triggers import RisingEdge

from pyuvm import uvm_test, ConfigDB

from vip_chi_types_pkg import Role
from vip_chi_cfg_agent import VipChiCfgAgent
from chi_proxy_tb_env import chi_proxy_tb_env
from vip_chi_write_seq import vip_chi_write_seq
from vip_chi_read_seq import vip_chi_read_seq
from chi_tb_pkg import WRITE_READ_ADDR_C  # re-exported for tests


class chi_hni_base_test(uvm_test):

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.tb_env = None
    self.v_sqr = None
    self.chi_cfg = None
    self.hrni0_cfg = None
    self.hrni1_cfg = None
    self.hsnf0_cfg = None
    self.hsnf1_cfg = None
    self.hni_cfg = None
    self.rni0_wr_seq = None
    self.rni0_rd_seq = None
    self.rni1_wr_seq = None
    self.rni1_rd_seq = None

  def build_phase(self):
    rni0_vif = ConfigDB().get(self, "", "rni0_vif")
    self.chi_cfg = rni0_vif.cfg

    self.hrni0_cfg = VipChiCfgAgent("hrni0_cfg")
    self.hrni0_cfg.role = Role.RNI
    self.hrni1_cfg = VipChiCfgAgent("hrni1_cfg")
    self.hrni1_cfg.role = Role.RNI
    self.hsnf0_cfg = VipChiCfgAgent("hsnf0_cfg")
    self.hsnf0_cfg.role = Role.SNF
    self.hsnf1_cfg = VipChiCfgAgent("hsnf1_cfg")
    self.hsnf1_cfg.role = Role.SNF
    self.hni_cfg = VipChiCfgAgent("hni_cfg")
    self.hni_cfg.role = Role.HNI
    self.configure()

    ConfigDB().set(self, "tb_env.hrni0_agent", "cfg", self.hrni0_cfg)
    ConfigDB().set(self, "tb_env.hrni1_agent", "cfg", self.hrni1_cfg)
    ConfigDB().set(self, "tb_env.hsnf0_agent", "cfg", self.hsnf0_cfg)
    ConfigDB().set(self, "tb_env.hsnf1_agent", "cfg", self.hsnf1_cfg)
    ConfigDB().set(self, "tb_env", "hni_cfg", self.hni_cfg)

    self.tb_env = chi_proxy_tb_env("tb_env", self)

    self.rni0_wr_seq = vip_chi_write_seq("rni0_wr_seq", cfg=self.chi_cfg)
    self.rni0_rd_seq = vip_chi_read_seq("rni0_rd_seq", cfg=self.chi_cfg)
    self.rni1_wr_seq = vip_chi_write_seq("rni1_wr_seq", cfg=self.chi_cfg)
    self.rni1_rd_seq = vip_chi_read_seq("rni1_rd_seq", cfg=self.chi_cfg)

  def configure(self):
    """Override hook: tweak the proxy agent cfgs before they are published."""
    pass

  def configure_hni(self, hni):
    """Override hook: install a SAM / QoS window on the HN-I driver."""
    pass

  def connect_phase(self):
    self.v_sqr = self.tb_env.vseq
    self.configure_hni(self.tb_env.hni)

  def _bus(self):
    return ConfigDB().get(self, "", "rni0_vif")

  async def wait_clocks(self, cycles):
    bus = self._bus()
    for _ in range(cycles):
      await RisingEdge(bus.clk)

  def drain_observation_fifos(self):
    env = self.tb_env
    for f in (env.hrni0_req_fifo, env.hrni0_rsp_fifo, env.hrni0_dat_fifo,
              env.hrni1_req_fifo, env.hrni1_rsp_fifo, env.hrni1_dat_fifo,
              env.hsnf0_req_fifo, env.hsnf1_req_fifo):
      while f.can_get():
        f.try_get()

  async def pulse_reset(self, low_cycles=3):
    """Pulse the shared rst_n low then high; every agent's reset watcher and the
    HN-I proxy's own watcher see the edges and cascade handle_reset()."""
    bus = self._bus()
    bus.rst_n.value = 0
    for _ in range(low_cycles):
      await RisingEdge(bus.clk)
    bus.rst_n.value = 1
    await RisingEdge(bus.clk)
