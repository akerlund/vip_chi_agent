################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of vip_chi_agent.sv (non-coherent RN-I / SN-F cut).
#
# Builds the monitor always and the role-specific active driver + sequencer when
# the agent is UVM_ACTIVE. Role is a runtime value (Role on cfg/ConfigDB); the SV
# ROLE_P parameter becomes the "role" ConfigDB key resolved in build_phase.
#
# The agent owns the single rst_n watcher: run_phase forks monitor_start() and
# driver_start() after reset deassertion and, on the following FallingEdge(rst_n),
# kills them and cascades handle_reset() to the children, then re-primes the
# driver's driven signals (reset_vif) -- the cocotb analog of the SV
# fork/disable-fork loop. Only RN-I and SN-F are wired here; RN-F/HN-F/HN-I are
# Tier C and left unbuilt.
#
################################################################################

from __future__ import annotations

import cocotb
from cocotb.triggers import FallingEdge

from pyuvm import uvm_agent, uvm_analysis_port, ConfigDB

from vip_chi_types_pkg import Role, Issue, CACHE_LINE_BYTES
from vip_chi_cfg_agent import VipChiCfgAgent, UVM_ACTIVE
from vip_chi_monitor import vip_chi_monitor
from vip_chi_sequencer import vip_chi_sequencer
from vip_chi_driver_rni import vip_chi_driver_rni
from vip_chi_driver_rnf import vip_chi_driver_rnf
from vip_chi_driver_snf import vip_chi_driver_snf


class vip_chi_agent(uvm_agent):

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.vif = None
    self.cfg = None
    self.role = Role.MONITOR
    self.monitor = None
    self.rni_driver = None
    self.rnf_driver = None
    self.snf_driver = None
    self.sequencer = None
    self.req_port = uvm_analysis_port("req_port", self)
    self.rsp_port = uvm_analysis_port("rsp_port", self)
    self.dat_port = uvm_analysis_port("dat_port", self)
    self.snp_port = uvm_analysis_port("snp_port", self)

  # ==========================================================================
  def build_phase(self):
    self.vif = ConfigDB().get(self, "", "vif")
    try:
      self.role = Role(ConfigDB().get(self, "", "role"))
    except Exception:
      self.role = Role.MONITOR
    try:
      self.cfg = ConfigDB().get(self, "", "cfg")
    except Exception:
      self.cfg = VipChiCfgAgent("default_cfg")
    self.cfg.role = self.role
    self._check_chi_cfg(self.vif.cfg)

    is_active = (self.cfg.is_active == UVM_ACTIVE)
    if is_active and self.role == Role.MONITOR:
      raise RuntimeError(
        f"[{self.get_name()}] Active agent requires a driving role, not MONITOR")

    # Publish resolved handles to the children (scoped to this agent subtree).
    self._publish_to_children()

    self.monitor = vip_chi_monitor("monitor", self)

    if is_active:
      if self.role == Role.RNI:
        self.rni_driver = vip_chi_driver_rni("driver", self)
        self.rni_driver.agent_owned = True
      elif self.role == Role.RNF:
        self.rnf_driver = vip_chi_driver_rnf("driver", self)
        self.rnf_driver.agent_owned = True
      elif self.role == Role.SNF:
        self.snf_driver = vip_chi_driver_snf("driver", self)
        self.snf_driver.agent_owned = True
      else:
        # Port deviation (PORTING_PLAN §11.1): SV also builds a single-port HN-I
        # here (vip_chi_agent.sv:119); the port routes all HN-I through the
        # dedicated multi-port vip_chi_hni_agent, so Role.HNI is unsupported here.
        raise RuntimeError(
          f"[{self.get_name()}] role {self.role} is not supported by this "
          f"driver cut")
      self.sequencer = vip_chi_sequencer("sequencer", self)

  def _publish_to_children(self):
    for key, val in (("vif", self.vif), ("cfg", self.cfg), ("role", self.role)):
      ConfigDB().set(self, "*", key, val)

  def _check_chi_cfg(self, chi_cfg):
    # Validate the static CHI geometry consumed by the interface and helpers
    # (mirrors SV vip_chi_agent::check_cfg_p on CFG_P).
    name = self.get_name()
    if chi_cfg.issue not in (Issue.D, Issue.E):
      raise RuntimeError(f"[{name}] cfg.issue={chi_cfg.issue} is not a supported CHI issue")
    if not (1 <= chi_cfg.node_id_width <= 11):
      raise RuntimeError(f"[{name}] cfg.node_id_width={chi_cfg.node_id_width} is outside [1:11]")
    if chi_cfg.addr_width < 1:
      raise RuntimeError(f"[{name}] cfg.addr_width={chi_cfg.addr_width} must be >= 1")
    if chi_cfg.issue == Issue.D and chi_cfg.addr_width > 44:
      raise RuntimeError(f"[{name}] CHI-D cfg.addr_width={chi_cfg.addr_width} exceeds 44")
    if chi_cfg.addr_width > 52:
      raise RuntimeError(f"[{name}] cfg.addr_width={chi_cfg.addr_width} exceeds 52")
    db = chi_cfg.data_bytes
    if db < 1 or db > CACHE_LINE_BYTES or (db & (db - 1)) != 0:
      raise RuntimeError(
        f"[{name}] cfg.data_bytes={db} must be a power of two in [1:{CACHE_LINE_BYTES}]")

  # ==========================================================================
  def connect_phase(self):
    self.monitor.req_port.connect(self.req_port)
    self.monitor.rsp_port.connect(self.rsp_port)
    self.monitor.dat_port.connect(self.dat_port)
    self.monitor.snp_port.connect(self.snp_port)

    drv = self.rni_driver or self.rnf_driver or self.snf_driver
    if drv is not None:
      drv.seq_item_port.connect(self.sequencer.seq_item_export)

    # The monitor samples the same bus as the agent; give it the role + cfg.
    self.monitor.set_bus(self.vif, self.vif.cfg, self.role)

  # ==========================================================================
  # Single rst_n watcher (SV fork/disable-fork -> cocotb tasks + kill).
  # ==========================================================================
  async def run_phase(self):
    bus = self.vif
    self._reset_driver_vif()
    while True:
      while bus.in_reset():
        await bus.rising()

      tasks = [cocotb.start_soon(self.monitor.monitor_start())]
      drv = self.rni_driver or self.rnf_driver or self.snf_driver
      if drv is not None:
        tasks.append(cocotb.start_soon(drv.driver_start()))

      await FallingEdge(bus.rst_n)
      for t in tasks:
        try:
          if not t.done():
            t.kill()
        except Exception:
          pass
      self.handle_reset()
      self._reset_driver_vif()

  def _reset_driver_vif(self):
    drv = self.rni_driver or self.rnf_driver or self.snf_driver
    if drv is not None:
      drv.reset_vif()

  def handle_reset(self):
    self.monitor.handle_reset()
    drv = self.rni_driver or self.rnf_driver or self.snf_driver
    if drv is not None:
      drv.handle_reset()
    if self.cfg.is_active == UVM_ACTIVE and self.sequencer is not None:
      self.sequencer.handle_reset()
