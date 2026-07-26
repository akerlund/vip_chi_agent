################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of seq_lib/vip_chi_raw_seq.sv -- injects verbatim (raw) flits on the
# REQ / RSP / DAT channels, bypassing the item generator and legality checks. The
# caller supplies each flit as a {field: value} dict; the codec packs it into the
# raw flit integer that the driver drives byte-for-byte (raw_override). Used to
# inject partial / illegal flits the normal item->flit path would normalize.
#
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import ChiCfg, pack
from vip_chi_base_seq import vip_chi_base_seq
from vip_chi_item import vip_chi_item


class vip_chi_raw_seq(vip_chi_base_seq):

  def __init__(self, name: str = "vip_chi_raw_seq", cfg: ChiCfg = None):
    super().__init__(name, cfg)
    self.items = []

  def reset(self):
    super().reset()
    self.items = []

  def _new_item(self):
    return vip_chi_item("raw_item", cfg=self.CFG)

  def add_raw_req(self, fields):
    item = self._new_item()
    item.set_raw_req(pack(self.CFG, "req", fields))
    self.items.append(item)

  def add_raw_rsp(self, fields):
    item = self._new_item()
    item.set_raw_rsp(pack(self.CFG, "rsp", fields))
    self.items.append(item)

  def add_raw_dat(self, fields):
    item = self._new_item()
    item.set_raw_dat(pack(self.CFG, "dat", fields))
    self.items.append(item)

  def item_count(self):
    return len(self.items)

  async def body(self):
    for item in self.items:
      await self.start_item(item)
      await self.finish_item(item)
