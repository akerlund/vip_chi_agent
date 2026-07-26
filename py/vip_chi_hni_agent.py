################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM agent hosting the multi-port vip_chi_driver_hni. The SV models HN-I via
# the generic parameterized vip_chi_agent (ROLE_P == HNI); the pyUVM port keeps
# the HN-I proxy as a multi-port driver (like the HN-F home), so it gets its own
# thin agent -- the sibling of vip_chi_hnf_agent. Like that agent it holds no
# sequencer and no observation ports (the surrounding RN-I/SN-F agents observe
# the links); it just owns the proxy driver + config. The driver owns its own
# rst_n watcher, so this agent forks nothing. The proxy env assigns the RN-/
# SN-facing ChiBus lists onto the driver in connect_phase (the driver is built
# here, after the env's build_phase).
#
################################################################################

from __future__ import annotations

from pyuvm import uvm_agent

from vip_chi_types_pkg import Role
from vip_chi_driver_hni import vip_chi_driver_hni
from vip_chi_cfg_agent import VipChiCfgAgent


class vip_chi_hni_agent(uvm_agent):

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.cfg = None
    self.hni_driver = None

  def build_phase(self):
    # Port deviation (PORTING_PLAN §11.2): SV pulls cfg/sam/arb_window and the
    # per-link vifs from uvm_config_db (vip_chi_hni_agent.sv:89). Here the proxy
    # env assigns the RN-/SN-facing ChiBus lists onto the driver in connect_phase
    # and tests set sam / arb_window_cycles directly via configure_hni(hni).
    if self.cfg is None:
      self.cfg = VipChiCfgAgent("hni_default_cfg")
    self.cfg.role = Role.HNI
    self.hni_driver = vip_chi_driver_hni("hni_driver", self)
    self.hni_driver.cfg = self.cfg

  def handle_reset(self):
    if self.hni_driver is not None:
      self.hni_driver.handle_reset()
