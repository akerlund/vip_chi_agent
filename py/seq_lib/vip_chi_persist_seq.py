################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of vip_chi_persist_seq.sv -- issues persist CMOs
# (CleanSharedPersist, or the CHI-E CleanSharedPersistSep) that carry no write
# data and no DBID grant: each just drives its REQ and completes on RSP (a single
# Comp for the non-separated form, a Persist + CompPersist pair for the separated
# form). Write direction with the payload-driven modes rejected.
#
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import ChiCfg, Dir, ReqOpcode
from vip_chi_base_seq import vip_chi_base_seq
from vip_chi_seq_config import VIP_CHI_UNLIMITED_REQUESTS


class vip_chi_persist_seq(vip_chi_base_seq):

  def __init__(self, name: str = "vip_chi_persist_seq", cfg: ChiCfg = None):
    super().__init__(name, cfg)
    self.sep_persist_enabled = False

  def reset(self):
    super().reset()
    self.sep_persist_enabled = False

  def set_sep_persist(self, enabled):
    self.sep_persist_enabled = bool(enabled)

  def _choose_opcode(self):
    if self.sep_persist_enabled:
      if not self.CFG.is_e:
        raise ValueError(
          f"[{self.get_name()}] CleanSharedPersistSep is only legal under CHI-E")
      return ReqOpcode.CLEAN_SHARED_PERSIST_SEP
    return ReqOpcode.CLEAN_SHARED_PERSIST

  def preview_next_request(self):
    self.set_direction(Dir.WRITE)
    return super().preview_next_request()

  async def body(self):
    self.set_direction(Dir.WRITE)

    if self.sep_persist_enabled and not self.CFG.is_e:
      raise ValueError(
        f"[{self.get_name()}] CleanSharedPersistSep is only legal under CHI-E")

    if (self.cfg.requests == VIP_CHI_UNLIMITED_REQUESTS
        or not self.payload_buf.exhausted()
        or self.payload_buf.has_custom_be()):
      raise RuntimeError(
        f"[{self.get_name()}] Persist requests do not support custom "
        f"request payload configuration")

    await super().body()
