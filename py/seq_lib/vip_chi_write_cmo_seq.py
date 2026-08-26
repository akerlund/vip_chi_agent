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

from vip_chi_types_pkg import ChiCfg, Dir, ReqOpcode, Role
from vip_chi_base_seq import vip_chi_base_seq

# The CMO half. CleanShared and CleanInvalid complete with no state change at a
# memory node, which has no cache; the persistent form is the one that adds an
# observable Persist response and therefore the one with an order to get wrong.
CMO_CLEAN_SH = "clean_sh"
CMO_CLEAN_INV = "clean_inv"
CMO_CLEAN_SH_PER_SEP = "clean_sh_per_sep"

# Which write the combined request carries. NO_SNP reaches a memory node and is
# the default because it is what this sequence drove before the coherent forms
# existed; the other three reach a Home and take the coherent completer path.
CWRITE_NO_SNP = "no_snp"
CWRITE_BACK_FULL = "back_full"
CWRITE_CLEAN_FULL = "clean_full"
CWRITE_UNIQUE = "unique"

# (write class, partial, cmo) -> opcode.
#
# Not every triple is an opcode: Table 13-14 gives CleanInv only to WriteNoSnp
# and WriteBackFull, and a Ptl form only to WriteNoSnp and WriteUnique. A missing
# key raises rather than falling back to the nearest form, because a silent
# substitution puts a different legal opcode on the wire and the test still
# passes.
_OPCODE_C = {
  (CWRITE_NO_SNP, False, CMO_CLEAN_SH): ReqOpcode.WRITE_NO_SNP_FULL_CLEAN_SH,
  (CWRITE_NO_SNP, False, CMO_CLEAN_INV): ReqOpcode.WRITE_NO_SNP_FULL_CLEAN_INV,
  (CWRITE_NO_SNP, False, CMO_CLEAN_SH_PER_SEP): ReqOpcode.WRITE_NO_SNP_FULL_CLEAN_SH_PER_SEP,
  (CWRITE_NO_SNP, True, CMO_CLEAN_SH): ReqOpcode.WRITE_NO_SNP_PTL_CLEAN_SH,
  (CWRITE_NO_SNP, True, CMO_CLEAN_INV): ReqOpcode.WRITE_NO_SNP_PTL_CLEAN_INV,
  (CWRITE_NO_SNP, True, CMO_CLEAN_SH_PER_SEP): ReqOpcode.WRITE_NO_SNP_PTL_CLEAN_SH_PER_SEP,

  (CWRITE_BACK_FULL, False, CMO_CLEAN_SH): ReqOpcode.WRITE_BACK_FULL_CLEAN_SH,
  (CWRITE_BACK_FULL, False, CMO_CLEAN_INV): ReqOpcode.WRITE_BACK_FULL_CLEAN_INV,
  (CWRITE_BACK_FULL, False, CMO_CLEAN_SH_PER_SEP): ReqOpcode.WRITE_BACK_FULL_CLEAN_SH_PER_SEP,

  (CWRITE_CLEAN_FULL, False, CMO_CLEAN_SH): ReqOpcode.WRITE_CLEAN_FULL_CLEAN_SH,
  (CWRITE_CLEAN_FULL, False, CMO_CLEAN_SH_PER_SEP): ReqOpcode.WRITE_CLEAN_FULL_CLEAN_SH_PER_SEP,

  (CWRITE_UNIQUE, False, CMO_CLEAN_SH): ReqOpcode.WRITE_UNIQUE_FULL_CLEAN_SH,
  (CWRITE_UNIQUE, False, CMO_CLEAN_SH_PER_SEP): ReqOpcode.WRITE_UNIQUE_FULL_CLEAN_SH_PER_SEP,
  (CWRITE_UNIQUE, True, CMO_CLEAN_SH): ReqOpcode.WRITE_UNIQUE_PTL_CLEAN_SH,
  (CWRITE_UNIQUE, True, CMO_CLEAN_SH_PER_SEP): ReqOpcode.WRITE_UNIQUE_PTL_CLEAN_SH_PER_SEP,
}


class vip_chi_write_cmo_seq(vip_chi_base_seq):

  def __init__(self, name: str = "vip_chi_write_cmo_seq", cfg: ChiCfg = None):
    super().__init__(name, cfg)
    self._partial = False
    self._cmo = CMO_CLEAN_SH
    self._write_class = CWRITE_NO_SNP

  def set_partial(self, partial: bool) -> None:
    """Ptl rather than Full: the write half becomes a partial write."""
    self._partial = bool(partial)

  def set_cmo(self, cmo: str) -> None:
    if cmo not in (CMO_CLEAN_SH, CMO_CLEAN_INV, CMO_CLEAN_SH_PER_SEP):
      raise ValueError(f"[{self.get_name()}] unknown CMO {cmo!r}")
    self._cmo = cmo

  def set_write_class(self, write_class: str) -> None:
    if write_class not in (CWRITE_NO_SNP, CWRITE_BACK_FULL, CWRITE_CLEAN_FULL,
                           CWRITE_UNIQUE):
      raise ValueError(
        f"[{self.get_name()}] unknown combined write class {write_class!r}")
    self._write_class = write_class

  def _role_val(self):
    """RN-F for the coherent write classes, RN-I for WriteNoSnp.

    The role picks which legal-opcode pool the item is solved against, and the
    two pools are deliberately different: an RN-I is never offered a CopyBack.
    Leaving this at the base class's RN-I made every coherent form unsolvable --
    the opcode is pinned by _choose_opcode and then rejected by a pool that has
    no row for it.
    """
    if self._write_class == CWRITE_NO_SNP:
      return Role.RNI
    return Role.RNF

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
    key = (self._write_class, self._partial, self._cmo)
    if key not in _OPCODE_C:
      raise RuntimeError(
        f"[{self.get_name()}] Table 13-14 has no {self._write_class} + "
        f"{self._cmo} form with partial={self._partial}")
    return _OPCODE_C[key]

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
