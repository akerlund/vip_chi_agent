################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of vip_chi_hnf_agent.sv -- a thin autonomous agent hosting the
# multi-port vip_chi_driver_hnf. Like the SV, it holds no sequencer and no
# observation ports (the surrounding RN-F agents observe the links); it just
# owns the home driver + config. The driver owns its own rst_n watcher (mirroring
# the ported HN-I driver), so this agent forks nothing. The coherent env assigns
# the RN-/SN-facing ChiBus lists onto the driver in connect_phase (the driver is
# built here, after the env's build_phase).
#
################################################################################

from __future__ import annotations

from pyuvm import uvm_agent

from vip_chi_types_pkg import Role
from vip_chi_driver_hnf import vip_chi_driver_hnf
from vip_chi_cfg_agent import VipChiCfgAgent


class vip_chi_hnf_agent(uvm_agent):

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.cfg = None
    self.hnf_driver = None

  def build_phase(self):
    if self.cfg is None:
      self.cfg = VipChiCfgAgent("hnf_default_cfg")
    self.cfg.role = Role.HNF
    self.hnf_driver = vip_chi_driver_hnf("hnf_driver", self)
    self.hnf_driver.cfg = self.cfg

  def handle_reset(self):
    if self.hnf_driver is not None:
      self.hnf_driver.handle_reset()
