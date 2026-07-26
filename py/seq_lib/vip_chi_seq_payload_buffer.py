################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of vip_chi_seq_payload_buffer.sv -- queued CUSTOM write data/BE
# slices, consumed one DAT burst per request.
#
################################################################################

from __future__ import annotations


class vip_chi_seq_payload_buffer:

  def __init__(self, name: str = "vip_chi_seq_payload_buffer", data_bytes: int = 16):
    self.name = name
    self.data_bytes = int(data_bytes)
    self.data = []
    self.be = []

  def reset(self):
    self.data = []
    self.be = []

  def set_data(self, data):
    self.data = [int(d) for d in data]

  def set_be(self, be):
    self.be = [int(b) for b in be]

  def data_size(self):
    return len(self.data)

  def exhausted(self):
    return len(self.data) == 0

  def has_custom_be(self):
    return len(self.be) != 0

  def clamp_size(self, item_cfg):
    if not self.data:
      return
    remaining_bytes = len(self.data) * self.data_bytes
    max_size = 0
    while max_size < 6 and (1 << (max_size + 1)) <= remaining_bytes:
      max_size += 1
    if item_cfg.max_size > max_size:
      item_cfg.max_size = max_size
      if item_cfg.min_size > item_cfg.max_size:
        item_cfg.min_size = item_cfg.max_size

  def apply(self, item, item_cfg):
    from vip_chi_types_pkg import DataType
    if item_cfg.data_type != DataType.CUSTOM:
      return
    beats = item.get_payload_beat_count()
    if beats > len(self.data):
      raise RuntimeError(
        f"[{self.name}] custom payload underrun: need {beats}, have {len(self.data)}")
    if self.be and beats > len(self.be):
      raise RuntimeError(
        f"[{self.name}] custom BE underrun: need {beats}, have {len(self.be)}")
    for beat in range(beats):
      item.data[beat] = self.data[beat]
      if self.be:
        item.be[beat] = self.be[beat]
    del self.data[:beats]
    if self.be:
      del self.be[:beats]
