################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of vip_chi_lcrd_mgr.sv.
#
# Counts a single CHI channel's send-side link-credit (L-credit) budget. Real
# CHI links start at 0 available and learn the initial grant from peer LCRDV
# pulses after link activation, so reset() defaults initial_available to 0.
#
# Plain Python class (the SV extends uvm_object only for the factory; nothing
# here needs it). One instance per send-side channel per driver.
#
################################################################################

from __future__ import annotations


class VipChiLcrdMgr:

  def __init__(self, name: str = "vip_chi_lcrd_mgr"):
    self.name = name
    self._available = 0
    self._max = 0

  def reset(self, max_credits: int, initial_available_credits: int = 0) -> None:
    """Configure capacity and (optionally) seed the available count."""
    if initial_available_credits > max_credits:
      raise ValueError(
        f"FATAL [{self.name}] Invalid credit reset: "
        f"available={initial_available_credits} max={max_credits}")
    self._available = initial_available_credits
    self._max = max_credits

  def try_acquire_credit(self) -> bool:
    """Consume one send-side credit if available; return whether it succeeded."""
    if self._available == 0:
      return False
    self._available -= 1
    return True

  def has_credit(self) -> bool:
    """Non-consuming: True when a send-side credit is currently available."""
    return self._available != 0

  def return_credit(self) -> None:
    """Return one credit on an inbound LCRDV pulse from the peer."""
    if self._available >= self._max:
      raise ValueError(
        f"FATAL [{self.name}] Credit overflow: "
        f"available={self._available} max={self._max}")
    self._available += 1

  @property
  def available(self) -> int:
    return self._available

  @property
  def max_credits(self) -> int:
    return self._max
