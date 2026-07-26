################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of seq_lib/vip_chi_pipelined_seq.sv -- forwards a caller-supplied
# queue of fully-built items to the driver in order, bypassing the base
# generator/randomization loop. Used for manual SN-F completion injection
# (drive_dat_item / drive_rsp_item / drive_raw_item on the SN-F driver): the test
# builds each completion item, add_item()s it, and starts the sequence on the
# SN-F agent's sequencer.
#
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import ChiCfg
from vip_chi_base_seq import vip_chi_base_seq


class vip_chi_pipelined_seq(vip_chi_base_seq):

  def __init__(self, name: str = "vip_chi_pipelined_seq", cfg: ChiCfg = None):
    super().__init__(name, cfg)
    self.items = []
    self.max_outstanding = 8

  def reset(self):
    super().reset()
    self.items = []
    self.max_outstanding = 8

  def add_item(self, item):
    if item is None:
      raise ValueError(f"[{self.get_name()}] add_item() received a null item handle")
    self.items.append(item)

  def item_count(self):
    return len(self.items)

  def response_count(self):
    return len(self.responses)

  async def body(self):
    if self.max_outstanding <= 0:
      raise ValueError(f"[{self.get_name()}] max_outstanding must be > 0")
    if not self.items:
      return

    for item in self.items:
      await self.start_item(item)
      await self.finish_item(item)
      if self.item_cfg.get_response:
        self.responses.append(item)
