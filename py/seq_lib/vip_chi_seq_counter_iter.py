################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of vip_chi_seq_counter_iter.sv -- COUNTER-mode payload state that
# threads a running counter across successive generated requests.
#
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import DataType


class vip_chi_seq_counter_iter:

  def __init__(self, name: str = "vip_chi_seq_counter_iter"):
    self.name = name
    self.counter = 0
    self.counter_increment = 1

  def reset(self):
    self.counter = 0
    self.counter_increment = 1

  def set_counter(self, start):
    self.counter = int(start)

  def set_increment(self, increment):
    self.counter_increment = int(increment)

  def get_counter(self):
    return self.counter

  def next(self):
    value = self.counter
    self.counter += self.counter_increment
    return value

  def configure_item(self, item):
    item.set_counter_value(self.counter)
    item.set_counter_increment(self.counter_increment)

  def advance(self, item, item_cfg):
    if item_cfg.data_type == DataType.COUNTER:
      # After randomize the item's counter_value holds the next value.
      self.counter = int(item.counter_value)
