################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of vip_chi_coherent_base_seq.sv -- base sequence for coherent (RN-F)
# traffic. Reuses the whole vip_chi_base_seq generation loop and only redirects
# two decisions: _role_val() -> Role.RNF (items stamp the coherent role) and
# _choose_opcode() -> the configured coherent opcode. Thin per-opcode wrappers
# pin the direction + opcode and defer to super().body().
#
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Role, ReqOpcode
from vip_chi_base_seq import vip_chi_base_seq


class vip_chi_coherent_base_seq(vip_chi_base_seq):

  def __init__(self, name="vip_chi_coherent_base_seq", cfg=None):
    super().__init__(name, cfg=cfg)
    # Coherent opcode stamped on every generated request (set by the wrappers or
    # a test). Defaults to ReadShared so a bare coherent sequence still does
    # something sensible.
    self.coh_opcode = int(ReqOpcode.READ_SHARED)

  def set_coherent_opcode(self, op):
    self.coh_opcode = int(op)

  # Coherent role + opcode overrides consumed by the inherited generation loop.
  def _role_val(self):
    return Role.RNF

  def _choose_opcode(self):
    return self.coh_opcode
