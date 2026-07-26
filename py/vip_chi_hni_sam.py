################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of vip_chi_hni_sam.sv -- HN-I System Address Map (SAM).
#
# Configurable address-range -> SN-target-port table for the HN-I proxy's
# request routing. This is the production form of the SN decode: instead of the
# driver's default single-bit address stride, a test/integration hands the HN-I
# a SAM with explicit [base:limit] ranges. `lookup` returns the SN port of the
# first matching range, or `default_port` when no range matches. Ranges are
# inclusive on both ends and compared as unsigned addresses.
#
################################################################################

from __future__ import annotations

import logging


class VipChiHniSamEntry:

  __slots__ = ("base", "limit", "sn_port")

  def __init__(self, base, limit, sn_port):
    self.base = int(base)
    self.limit = int(limit)
    self.sn_port = int(sn_port)


class vip_chi_hni_sam:

  def __init__(self, name="vip_chi_hni_sam"):
    self._name = name
    self.entries = []
    self.default_port = 0
    self._log = logging.getLogger(name)

  def get_name(self):
    return self._name

  # ---------------------------------------------------------------------------
  # Append one inclusive [base:limit] -> sn_port range.
  # ---------------------------------------------------------------------------
  def add_range(self, base, limit, sn_port):
    base = int(base)
    limit = int(limit)
    sn_port = int(sn_port)

    # Validate before appending. A reversed [base:limit] can never match in
    # lookup(); an overlap makes routing insertion-order-dependent (lookup
    # returns the FIRST matching range), which is almost always a config mistake.
    if base > limit:
      raise AssertionError(
        f"[{self._name}] add_range base 0x{base:x} > limit 0x{limit:x} "
        f"(reversed range)")
    for e in self.entries:
      if base <= e.limit and e.base <= limit:
        self._log.warning(
          "[%s] add_range [0x%x:0x%x]->%d overlaps existing [0x%x:0x%x]->%d; "
          "lookup() resolves by insertion order",
          self._name, base, limit, sn_port, e.base, e.limit, e.sn_port)

    self.entries.append(VipChiHniSamEntry(base, limit, sn_port))

  # ---------------------------------------------------------------------------
  # Return the SN port owning `addr` (first matching range), else default_port.
  # ---------------------------------------------------------------------------
  def lookup(self, addr):
    addr = int(addr)
    for e in self.entries:
      if e.base <= addr <= e.limit:
        return e.sn_port
    return self.default_port
