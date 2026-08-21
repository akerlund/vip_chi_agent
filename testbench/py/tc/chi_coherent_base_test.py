################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of tc/chi_coherent_base_test.sv -- base test for the isolated
# coherent topology (two RN-F requesters fanning into one HN-F home). Standalone
# scaffolding (no virtual sequencer): tests start sequences directly on
# tb_env.hrnf{0,1}_agent.sequencer. A concrete scenario derives a
# vip_chi_coh_<scenario>_base_test from this; each runnable tc_ fixes the config.
#
################################################################################

from __future__ import annotations

from cocotb.triggers import RisingEdge

from pyuvm import uvm_test, ConfigDB

from vip_chi_types_pkg import Role
from vip_chi_cfg_agent import VipChiCfgAgent, UVM_ACTIVE
from chi_coherent_tb_env import chi_coherent_tb_env
from chi_tb_config import chi_tb_config
from vip_chi_readshared_seq import vip_chi_readshared_seq
from vip_chi_readunique_seq import vip_chi_readunique_seq
from chi_tb_pkg import WRITE_READ_ADDR_C  # re-exported for tests


class chi_coherent_base_test(uvm_test):

  # Global vif key naming the RN-F port-0 harness bus (fixed by the tc_top). The
  # CHI-E base test overrides nothing here; a single geometry-agnostic body.
  RNF0_VIF_KEY = "hrnf0_vif"

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.tb_env = None
    self.chi_cfg = None
    self.tb_cfg = None
    self.hrnf0_cfg = None
    self.hrnf1_cfg = None
    self.hnf_cfg = None
    self.hrnf0_rdshared_seq = None
    self.hrnf0_rdunique_seq = None
    self.hrnf1_rdshared_seq = None
    self.hrnf1_rdunique_seq = None

  def build_phase(self):
    rnf0_vif = ConfigDB().get(self, "", self.RNF0_VIF_KEY)
    self.chi_cfg = rnf0_vif.cfg

    self.tb_cfg = chi_tb_config("tb_cfg")
    self.tb_cfg.reset()
    self.configure_tb_cfg()
    ConfigDB().set(None, "*", "tb_cfg", self.tb_cfg)

    self.hrnf0_cfg = VipChiCfgAgent("hrnf0_cfg")
    self.hrnf0_cfg.role = Role.RNF
    self.hrnf0_cfg.is_active = UVM_ACTIVE
    self.hrnf1_cfg = VipChiCfgAgent("hrnf1_cfg")
    self.hrnf1_cfg.role = Role.RNF
    self.hrnf1_cfg.is_active = UVM_ACTIVE
    self.hnf_cfg = VipChiCfgAgent("hnf_cfg")
    self.hnf_cfg.role = Role.HNF
    self.hnf_cfg.is_active = UVM_ACTIVE
    self.configure_agent_cfgs()

    ConfigDB().set(self, "tb_env.hrnf0_agent", "cfg", self.hrnf0_cfg)
    ConfigDB().set(self, "tb_env.hrnf1_agent", "cfg", self.hrnf1_cfg)
    ConfigDB().set(None, "*", "hnf_cfg", self.hnf_cfg)

    self.tb_env = chi_coherent_tb_env("tb_env", self)

    self.hrnf0_rdshared_seq = vip_chi_readshared_seq("hrnf0_rdshared_seq", cfg=self.chi_cfg)
    self.hrnf0_rdunique_seq = vip_chi_readunique_seq("hrnf0_rdunique_seq", cfg=self.chi_cfg)
    self.hrnf1_rdshared_seq = vip_chi_readshared_seq("hrnf1_rdshared_seq", cfg=self.chi_cfg)
    self.hrnf1_rdunique_seq = vip_chi_readunique_seq("hrnf1_rdunique_seq", cfg=self.chi_cfg)

  # -- override hooks ---------------------------------------------------------
  def configure_tb_cfg(self):
    """Seed the shared TB harness config before it is published."""
    pass

  def configure_agent_cfgs(self):
    """Seed the RN-F / HN-F agent cfgs before they are published."""
    pass

  # ==========================================================================
  # Shared helpers.
  # ==========================================================================
  def _bus(self):
    return ConfigDB().get(self, "", self.RNF0_VIF_KEY)

  async def wait_clocks(self, cycles):
    bus = self._bus()
    for _ in range(cycles):
      await RisingEdge(bus.clk)

  async def wait_reset_settle(self):
    """Wait until the coherent links are out of reset (+4-clock settle)."""
    bus = self._bus()
    if bus.in_reset():
      while bus.in_reset():
        await RisingEdge(bus.clk)
    await self.wait_clocks(4)

  def cfg_read_seq(self, seq, addr=None):
    """Configure a coherent sequence for one single-line, cache-line-sized
    request: no retries, blocking response collection, quiet."""
    if addr is None:
      addr = WRITE_READ_ADDR_C
    seq.reset()
    seq.set_requests(1)
    seq.set_initial_addr(addr)
    seq.set_size(6)
    seq.set_get_response(True)
    seq.set_verbose(False)

  def drain_observation_fifos(self):
    env = self.tb_env
    for f in (env.hrnf0_req_fifo, env.hrnf0_rsp_fifo, env.hrnf0_dat_fifo,
              env.hrnf0_snp_fifo, env.dsnf0_req_fifo):
      while f.can_get():
        f.try_get()

  async def pulse_reset(self, low_cycles=3):
    bus = self._bus()
    bus.rst_n.value = 0
    for _ in range(low_cycles):
      await RisingEdge(bus.clk)
    bus.rst_n.value = 1
    await RisingEdge(bus.clk)
