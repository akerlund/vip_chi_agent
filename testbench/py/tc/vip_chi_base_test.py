################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of tc/vip_chi_base_test.sv (integrated RN-I <-> SN-F cut).
#
# Builds the env, the RN-I / SN-F agent cfgs (published per-agent via ConfigDB),
# and the reusable write / read sequences the directed tests drive on
# v_sqr.rni_sequencer. Tests override configure() to tweak the agent cfgs (DECERR
# / DERR ranges, force_retry_count, split_write_rsp, ...) before they publish.
# cocotb owns the clock/reset (in the harness); the ChiCfg is taken from the
# ChiBus the harness published so there is one source of truth.
#
################################################################################

from __future__ import annotations

from cocotb.triggers import RisingEdge, FallingEdge

from pyuvm import uvm_test, ConfigDB

from vip_chi_types_pkg import Role
from vip_chi_cfg_agent import VipChiCfgAgent
from vip_chi_tb_env import vip_chi_tb_env
from vip_chi_tb_config import vip_chi_tb_config
from vip_chi_write_seq import vip_chi_write_seq
from vip_chi_read_seq import vip_chi_read_seq
from vip_chi_tb_pkg import WRITE_READ_ADDR_C  # re-exported for tests


class vip_chi_base_test(uvm_test):

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.tb_env = None
    self.v_sqr = None
    self.chi_cfg = None
    self.tb_cfg = None
    self.rni_cfg = None
    self.snf_cfg = None
    self.rni0_wr_seq = None
    self.rni0_rd_seq = None
    self.rni1_wr_seq = None
    self.rni1_rd_seq = None

  def build_phase(self):
    rni_vif = ConfigDB().get(self, "", "rni_vif")
    self.chi_cfg = rni_vif.cfg

    # The testcase owns the shared harness config object and publishes it once
    # (scoreboard / perf gating + the CHI-E datapath enable).
    self.tb_cfg = vip_chi_tb_config("tb_cfg")
    self.tb_cfg.reset()
    self.configure_tb_cfg()
    ConfigDB().set(None, "*", "tb_cfg", self.tb_cfg)

    self.rni_cfg = VipChiCfgAgent("rni_cfg")
    self.rni_cfg.role = Role.RNI
    self.snf_cfg = VipChiCfgAgent("snf_cfg")
    self.snf_cfg.role = Role.SNF
    self.configure(self.rni_cfg, self.snf_cfg)

    ConfigDB().set(self, "tb_env.rni_agent", "cfg", self.rni_cfg)
    ConfigDB().set(self, "tb_env.snf_agent", "cfg", self.snf_cfg)

    self.tb_env = vip_chi_tb_env("tb_env", self)

    self.rni0_wr_seq = vip_chi_write_seq("rni0_wr_seq", cfg=self.chi_cfg)
    self.rni0_rd_seq = vip_chi_read_seq("rni0_rd_seq", cfg=self.chi_cfg)
    self.rni1_wr_seq = vip_chi_write_seq("rni1_wr_seq", cfg=self.chi_cfg)
    self.rni1_rd_seq = vip_chi_read_seq("rni1_rd_seq", cfg=self.chi_cfg)

  def configure_tb_cfg(self):
    """Override hook: seed the shared TB harness config before it is published."""
    pass

  def configure(self, rni_cfg, snf_cfg):
    """Override hook: tweak agent cfgs before they are published."""
    pass

  def connect_phase(self):
    self.v_sqr = self.tb_env.vseq

  # ==========================================================================
  # Shared helpers (SV wait_clocks / drain_observation_fifos / reset pulse).
  # ==========================================================================
  def _bus(self):
    return ConfigDB().get(self, "", "rni_vif")

  async def clk_delay(self, n):
    bus = self._bus()
    for _ in range(n):
      await RisingEdge(bus.clk)

  async def wait_clocks(self, cycles):
    await self.clk_delay(cycles)

  def drain_observation_fifos(self):
    env = self.tb_env
    for f in (env.rni_req_fifo, env.rni_rsp_fifo, env.rni_dat_fifo,
              env.snf_req_fifo, env.snf_rsp_fifo, env.snf_dat_fifo):
      while f.can_get():
        f.try_get()

  async def pulse_reset(self, low_cycles=3):
    """Pulse rst_n low then high. Each agent's reset watcher sees the edges and
    cascades handle_reset() (driver/monitor/sequencer re-init)."""
    bus = self._bus()
    bus.rst_n.value = 0
    for _ in range(low_cycles):
      await RisingEdge(bus.clk)
    bus.rst_n.value = 1
    await RisingEdge(bus.clk)
