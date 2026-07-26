################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of vip_chi_addr_iterator.sv -- per-request address generation
# (explicit list, fixed stride, or auto Size-stride).
#
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import chi_size_bytes


class vip_chi_addr_iterator:

  def __init__(self, name: str = "vip_chi_addr_iterator"):
    self.name = name
    self.reset()

  def reset(self):
    self.current_addr = 0
    self.addrs = []
    self.enabled = True
    self.fixed_inc = 0

  def set_initial_addr(self, addr):
    self.current_addr = int(addr)

  def load_list(self, addr_list):
    self.addrs = [int(a) for a in addr_list]

  def list_size(self):
    return len(self.addrs)

  def pop_list_front(self):
    return self.addrs.pop(0)

  def set_increment(self, increment):
    self.fixed_inc = int(increment)

  def set_enabled(self, en):
    self.enabled = bool(en)

  def current(self):
    return self.current_addr

  def advance(self, size):
    if self.addrs:
      self.current_addr = self.addrs.pop(0)
      return self.current_addr
    if not self.enabled:
      return self.current_addr
    if self.fixed_inc != 0:
      self.current_addr = self.current_addr + self.fixed_inc
      return self.current_addr
    self.current_addr = self.current_addr + chi_size_bytes(int(size))
    return self.current_addr
