################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of seq_lib/vip_chi_write_cmo_seq.sv.
#
# Combined Write + CMO requests (Issue E only): one request carrying both a write
# and a cache maintenance operation to the same address, which the completer must
# apply IN THAT ORDER.
#
# One sequence for all six rather than six sequences, because they differ only in
# two independent choices -- Full or Ptl, and which CMO rides along -- and
# spelling that as two setters keeps the six reachable from one place. A test
# that wants a specific opcode says which write and which CMO it wants, rather
# than picking a class name that encodes both.
#
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import ChiCfg, Dir, ReqOpcode
from vip_chi_base_seq import vip_chi_base_seq

# The CMO half. CleanShared and CleanInvalid complete with no state change at a
# memory node, which has no cache; the persistent form is the one that adds an
# observable Persist response and therefore the one with an order to get wrong.
CMO_CLEAN_SH = "clean_sh"
CMO_CLEAN_INV = "clean_inv"
CMO_CLEAN_SH_PER_SEP = "clean_sh_per_sep"

_OPCODE_C = {
  (False, CMO_CLEAN_SH): ReqOpcode.WRITE_NO_SNP_FULL_CLEAN_SH,
  (False, CMO_CLEAN_INV): ReqOpcode.WRITE_NO_SNP_FULL_CLEAN_INV,
  (False, CMO_CLEAN_SH_PER_SEP): ReqOpcode.WRITE_NO_SNP_FULL_CLEAN_SH_PER_SEP,
  (True, CMO_CLEAN_SH): ReqOpcode.WRITE_NO_SNP_PTL_CLEAN_SH,
  (True, CMO_CLEAN_INV): ReqOpcode.WRITE_NO_SNP_PTL_CLEAN_INV,
  (True, CMO_CLEAN_SH_PER_SEP): ReqOpcode.WRITE_NO_SNP_PTL_CLEAN_SH_PER_SEP,
}


class vip_chi_write_cmo_seq(vip_chi_base_seq):

  def __init__(self, name: str = "vip_chi_write_cmo_seq", cfg: ChiCfg = None):
    super().__init__(name, cfg)
    self._partial = False
    self._cmo = CMO_CLEAN_SH

  def set_partial(self, partial: bool) -> None:
    """Ptl rather than Full: the write half becomes a partial write."""
    self._partial = bool(partial)

  def set_cmo(self, cmo: str) -> None:
    if cmo not in (CMO_CLEAN_SH, CMO_CLEAN_INV, CMO_CLEAN_SH_PER_SEP):
      raise ValueError(f"[{self.get_name()}] unknown CMO {cmo!r}")
    self._cmo = cmo

  def is_persist(self) -> bool:
    """True when the CMO half is persistent, so the completer owes a Persist."""
    return self._cmo == CMO_CLEAN_SH_PER_SEP

  def _choose_opcode(self):
    # Every combined form sits in the Opcode[6] = 1 half of the REQ table and
    # does not fit CHI-D's 6-bit opcode field at all, so this is a hard error
    # rather than a silent downgrade: truncation would put a different, legal
    # opcode on the wire.
    if not self.CFG.is_e:
      raise RuntimeError(
        f"[{self.get_name()}] combined Write+CMO is CHI-E only")
    return _OPCODE_C[(self._partial, self._cmo)]

  def preview_next_request(self):
    # The pool opt-in belongs here too, not only in body(): previewing forces the
    # same opcode through the same constraints, so without it the preview alone
    # fails to solve.
    self.set_direction(Dir.WRITE)
    self.set_combined_write_cmo_enable(True)
    return super().preview_next_request()

  async def body(self):
    self.set_direction(Dir.WRITE)
    # The six are opt-in in the item's legal-opcode pool, and this sequence is
    # the thing opting in: without it the solver rejects the opcode this
    # sequence exists to drive.
    self.set_combined_write_cmo_enable(True)
    if not self.CFG.is_e:
      raise RuntimeError(
        f"[{self.get_name()}] combined Write+CMO is CHI-E only")
    await super().body()
