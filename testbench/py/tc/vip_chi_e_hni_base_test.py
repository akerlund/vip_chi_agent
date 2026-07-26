################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# Base test for the CHI-E HN-I proxy topology (Wave 6). Builds the single-port
# CHI-E proxy env (hrni0 RN-I <-> HN-I <-> hsnf0 SN-F) at CHI_E_WIDE_CFG, the
# per-agent cfgs (published via ConfigDB), and the reusable wide write/read
# sequences the directed test drives on tb_env.hrni0_agent.sequencer.
#
################################################################################

from __future__ import annotations

from cocotb.triggers import RisingEdge

from pyuvm import uvm_test, ConfigDB

from vip_chi_types_pkg import Role
from vip_chi_cfg_agent import VipChiCfgAgent
from vip_chi_e_proxy_tb_env import vip_chi_e_proxy_tb_env
from vip_chi_write_seq import vip_chi_write_seq
from vip_chi_read_seq import vip_chi_read_seq


class vip_chi_e_hni_base_test(uvm_test):

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.tb_env = None
    self.chi_cfg = None
    self.hrni0_cfg = None
    self.hsnf0_cfg = None
    self.hni_cfg = None
    self.hrni0_wr_seq = None
    self.hrni0_rd_seq = None

  def build_phase(self):
    rni_vif = ConfigDB().get(self, "", "rni_vif")
    self.chi_cfg = rni_vif.cfg

    self.hrni0_cfg = VipChiCfgAgent("hrni0_cfg")
    self.hrni0_cfg.role = Role.RNI
    self.hsnf0_cfg = VipChiCfgAgent("hsnf0_cfg")
    self.hsnf0_cfg.role = Role.SNF
    self.hni_cfg = VipChiCfgAgent("hni_cfg")
    self.hni_cfg.role = Role.HNI
    self.configure()

    ConfigDB().set(self, "tb_env.hrni0_agent", "cfg", self.hrni0_cfg)
    ConfigDB().set(self, "tb_env.hsnf0_agent", "cfg", self.hsnf0_cfg)
    ConfigDB().set(self, "tb_env", "hni_cfg", self.hni_cfg)

    self.tb_env = vip_chi_e_proxy_tb_env("tb_env", self)

    self.hrni0_wr_seq = vip_chi_write_seq("hrni0_wr_seq", cfg=self.chi_cfg)
    self.hrni0_rd_seq = vip_chi_read_seq("hrni0_rd_seq", cfg=self.chi_cfg)

  def configure(self):
    """Override hook: tweak the proxy agent cfgs before they are published."""
    pass

  def _bus(self):
    return ConfigDB().get(self, "", "rni_vif")

  async def wait_clocks(self, cycles):
    bus = self._bus()
    for _ in range(cycles):
      await RisingEdge(bus.clk)
