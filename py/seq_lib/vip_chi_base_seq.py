################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of vip_chi_base_seq.sv.
#
# Generates CHI request items from the configured iterators / stamp state,
# randomizes them with the direction / role / opcode / attribute pins, sends
# them through the sequencer, and (optionally) collects the completed item as
# its response. The RN-I driver mutates the request in place with the observed
# completion, so finish_item() returning IS the response -- no separate
# get_response() handshake is needed.
#
# Scope: serial send/collect + pipelined_send (which only overlaps against a
# multi-outstanding driver; against the serial driver it collects the same items
# in order). The full CUSTOM-payload path is carried but not exercised by the
# Tier-A2 smoke.
#
################################################################################

from __future__ import annotations

import random

from cocotb.triggers import Event, Timer

from pyuvm import uvm_sequence

from vip_chi_types_pkg import (
  ChiCfg, VIP_CHI_DEFAULT_CFG, Dir, Role, DataType, ReqOpcode,
)
from vip_chi_item import vip_chi_item
from vip_chi_cfg_item import VipChiCfgItem
from vip_chi_seq_config import vip_chi_seq_config, VIP_CHI_UNLIMITED_REQUESTS
from vip_chi_addr_iterator import vip_chi_addr_iterator
from vip_chi_seq_payload_buffer import vip_chi_seq_payload_buffer
from vip_chi_seq_counter_iter import vip_chi_seq_counter_iter


class vip_chi_base_seq(uvm_sequence):

  def __init__(self, name: str = "vip_chi_base_seq", cfg: ChiCfg = None):
    super().__init__(name)
    # Mirror the item's no-arg fallback so the sequence, its items, and the
    # payload buffer all share one geometry (SV VIP_CHI_DEFAULT_CFG_C).
    self.CFG = cfg if cfg is not None else VIP_CHI_DEFAULT_CFG
    self.cfg = vip_chi_seq_config("cfg")
    self.item_cfg = VipChiCfgItem("item_cfg")
    self.addr_iter = vip_chi_addr_iterator("addr_iter")
    self.payload_buf = vip_chi_seq_payload_buffer(
      "payload_buf", data_bytes=self.CFG.data_bytes)
    self.counter_iter = vip_chi_seq_counter_iter("counter_iter")
    self.responses = []
    self.reset()

  # ==========================================================================
  def reset(self):
    saved_direction = self.item_cfg.direction
    self.cfg.reset()
    self.item_cfg.reset()
    self.addr_iter.reset()
    self.payload_buf.reset()
    self.counter_iter.reset()

    self.item_cfg.direction = saved_direction
    self.ns_val = 1
    self.order_val = 0
    self.mem_attr_val = 0
    self.allow_retry_val = 1
    self.exp_comp_ack_val = 0
    self.excl_val = 0
    self.pcrd_type_val = 0
    self.src_id_val = 0
    self.tgt_id_val = 0
    self.lp_id_val = 0
    self.return_nid_val = 0
    self.return_txn_id_val = 0
    self.qos_val = 0
    self.tracetag_val = 0
    self.dodwt_val = 0
    self.likelyshared_val = 0
    self.endian_val = 0
    self.group_id_ext_val = 0
    self.tagop_val = 0
    self.dat_tagop_val = 0
    self.tag_val = []
    self.tu_val = []
    self.sep_read_enabled = False
    self.pipelined_send = False
    self.responses = []

  # ==========================================================================
  # Configuration setters (mirror the SV set_* API used by the tests).
  # ==========================================================================
  def set_pipelined_send(self, enabled): self.pipelined_send = bool(enabled)
  def set_direction(self, direction): self.item_cfg.direction = direction
  def get_direction(self): return self.item_cfg.direction

  def set_requests(self, requests):
    if requests < 0:
      raise ValueError(f"[{self.get_name()}] set_requests({requests}) is negative")
    if self.item_cfg.data_type == DataType.CUSTOM:
      self.cfg.requests = VIP_CHI_UNLIMITED_REQUESTS
    else:
      self.cfg.requests = requests

  def set_initial_addr(self, addr): self.addr_iter.set_initial_addr(addr)

  def set_addr_list(self, addr_list):
    self.addr_iter.load_list(addr_list)
    self.cfg.requests = self.addr_iter.list_size()
    if self.addr_iter.list_size() != 0:
      self.addr_iter.set_initial_addr(self.addr_iter.pop_list_front())

  def set_addr_stride(self, stride): self.addr_iter.set_increment(stride)
  def set_addr_enabled(self, enabled): self.addr_iter.set_enabled(enabled)
  def set_size(self, size): self.item_cfg.min_size = self.item_cfg.max_size = int(size)

  def set_size_range(self, min_size, max_size):
    if min_size < 0 or max_size > 6 or min_size > max_size:
      raise ValueError(f"[{self.get_name()}] Illegal size range [{min_size}:{max_size}]")
    self.item_cfg.min_size = min_size
    self.item_cfg.max_size = max_size

  def set_enforce_addr_alignment(self, value): self.item_cfg.enforce_addr_alignment = bool(value)
  def set_atomic_strict_size(self, enabled): self.item_cfg.atomic_strict_size = bool(enabled)
  def set_combined_write_cmo_enable(self, enabled):
    self.item_cfg.combined_write_cmo_enable = bool(enabled)

  def set_write_unique_zero_enable(self, enabled):
    self.item_cfg.write_unique_zero_enable = bool(enabled)

  def set_write_evict_or_evict_enable(self, enabled):
    self.item_cfg.write_evict_or_evict_enable = bool(enabled)

  def set_data_type(self, data_type):
    self.item_cfg.data_type = data_type
    if data_type == DataType.CUSTOM:
      self.cfg.requests = VIP_CHI_UNLIMITED_REQUESTS

  def set_data(self, data):
    self.payload_buf.set_data(data)
    self.item_cfg.data_type = DataType.CUSTOM
    self.cfg.requests = VIP_CHI_UNLIMITED_REQUESTS

  def set_be(self, be): self.payload_buf.set_be(be)
  def set_counter_value(self, start): self.counter_iter.set_counter(start)
  def set_counter_increment(self, inc): self.counter_iter.set_increment(inc)
  def get_counter(self): return self.counter_iter.get_counter()
  def set_src_id(self, src_id): self.src_id_val = int(src_id)
  def set_tgt_id(self, tgt_id): self.tgt_id_val = int(tgt_id)
  def set_lp_id(self, lp_id): self.lp_id_val = int(lp_id)
  def set_return_nid(self, return_nid): self.return_nid_val = int(return_nid)
  def set_return_txn_id(self, return_txn_id): self.return_txn_id_val = int(return_txn_id)
  def set_qos(self, qos): self.qos_val = int(qos)
  def set_tracetag(self, tracetag): self.tracetag_val = int(tracetag)
  def set_dodwt(self, dodwt): self.dodwt_val = int(dodwt)
  def set_likelyshared(self, likelyshared): self.likelyshared_val = int(likelyshared)
  def set_endian(self, endian): self.endian_val = int(endian)
  def set_group_id_ext(self, group_id_ext): self.group_id_ext_val = int(group_id_ext)
  def set_tagop(self, tagop): self.tagop_val = int(tagop)
  def set_dat_tagop(self, dat_tagop): self.dat_tagop_val = int(dat_tagop)
  def set_tag(self, tag): self.tag_val = [int(t) for t in tag]
  def set_tu(self, tu): self.tu_val = [int(t) for t in tu]
  def set_ns(self, ns): self.ns_val = int(ns)
  def set_order(self, order): self.order_val = int(order)
  def set_mem_attr(self, mem_attr): self.mem_attr_val = int(mem_attr)
  def set_allow_retry(self, allow_retry): self.allow_retry_val = int(allow_retry)
  def set_exp_comp_ack(self, exp_comp_ack): self.exp_comp_ack_val = int(exp_comp_ack)
  def set_excl(self, excl): self.excl_val = int(excl)
  def set_pcrd_type(self, pcrd_type): self.pcrd_type_val = int(pcrd_type)
  def set_sep_read(self, enabled): self.sep_read_enabled = bool(enabled)
  def set_get_response(self, enabled): self.item_cfg.get_response = bool(enabled)
  def set_verbose(self, verbose): self.cfg.verbose = bool(verbose)

  def set_request_delay(self, enabled, min_delay, max_delay, period):
    if min_delay < 0 or max_delay < min_delay:
      raise ValueError(
        f"[{self.get_name()}] Illegal request delay range [{min_delay}:{max_delay}]")
    if enabled and period <= 0.0:
      raise ValueError(
        f"[{self.get_name()}] request-delay period must be > 0 when enabled")
    self.cfg.request_delay_enabled = bool(enabled)
    self.cfg.request_delay_min = int(min_delay)
    self.cfg.request_delay_max = int(max_delay)
    self.cfg.clock_period = float(period)

  def set_log_denominator(self, log_denominator):
    if log_denominator <= 0:
      raise ValueError(f"[{self.get_name()}] log_denominator must be > 0")
    self.cfg.log_denominator = int(log_denominator)

  def get_responses(self):
    out, self.responses = self.responses, []
    return out

  # ==========================================================================
  # Item generation.
  # ==========================================================================
  def _role_val(self):
    return Role.RNI

  def _choose_opcode(self):
    if self.item_cfg.direction == Dir.READ:
      if self.sep_read_enabled:
        if not self.CFG.is_e:
          raise ValueError(f"[{self.get_name()}] ReadNoSnpSep is CHI-E only")
        return ReqOpcode.READ_NO_SNP_SEP
      return ReqOpcode.READ_NO_SNP
    if self.payload_buf.has_custom_be():
      return ReqOpcode.WRITE_NO_SNP_PTL
    return ReqOpcode.WRITE_NO_SNP_FULL

  def access_name(self):
    # Human-readable access type for progress logging (mirrors SV access_name).
    if self.item_cfg.direction == Dir.READ:
      return "ReadNoSnpSep" if self.sep_read_enabled else "ReadNoSnp"
    if self.payload_buf.has_custom_be():
      return "WriteNoSnpPtl"
    return "WriteNoSnpFull"

  async def apply_request_delay(self, request_idx):
    # Optional inter-request spacing (opt-in; mirrors SV apply_request_delay).
    # clock_period is interpreted in ns, matching the port's 10 ns bus clock.
    if not self.cfg.request_delay_enabled or request_idx == 0:
      return
    delay_cycles = random.randint(self.cfg.request_delay_min, self.cfg.request_delay_max)
    delay_time = delay_cycles * self.cfg.clock_period
    if delay_time > 0:
      await Timer(delay_time, unit="ns")

  def build_request_item(self, request_idx):
    req = vip_chi_item(f"req_{request_idx}", self.CFG)

    if self.item_cfg.data_type == DataType.CUSTOM:
      if self.payload_buf.exhausted():
        raise RuntimeError(f"[{self.get_name()}] CUSTOM data mode needs queued payload")
      self.payload_buf.clamp_size(self.item_cfg)
      req.deferred_custom_payload = True

    req.set_size_range(self.item_cfg.min_size, self.item_cfg.max_size)
    req.set_data_type(self.item_cfg.data_type)
    req.set_enforce_addr_alignment(self.item_cfg.enforce_addr_alignment)
    req.set_atomic_strict_size(self.item_cfg.atomic_strict_size)
    req.set_combined_write_cmo_enable(self.item_cfg.combined_write_cmo_enable)
    req.set_write_unique_zero_enable(self.item_cfg.write_unique_zero_enable)
    req.set_write_evict_or_evict_enable(self.item_cfg.write_evict_or_evict_enable)
    req.min_addr = self.addr_iter.current()
    req.max_addr = self.addr_iter.current()
    self.counter_iter.configure_item(req)

    direction_val = int(self.item_cfg.direction)
    opcode_val = int(self._choose_opcode())
    role_val = int(self._role_val())

    with req.randomize_with() as x:
      x.direction == direction_val
      x.role == role_val
      x.opcode == opcode_val
      x.src_id == self.src_id_val
      x.tgt_id == self.tgt_id_val
      x.lp_id == self.lp_id_val
      x.return_nid == self.return_nid_val
      x.return_txn_id == self.return_txn_id_val
      x.qos == self.qos_val
      x.tracetag == self.tracetag_val
      x.dodwt == self.dodwt_val
      x.likelyshared == self.likelyshared_val
      x.endian == self.endian_val
      x.group_id_ext == self.group_id_ext_val
      x.tagop == self.tagop_val
      x.ns == self.ns_val
      x.order == self.order_val
      x.mem_attr == self.mem_attr_val
      x.allow_retry == self.allow_retry_val
      x.exp_comp_ack == self.exp_comp_ack_val
      x.excl == self.excl_val
      x.pcrd_type == self.pcrd_type_val

    if self.item_cfg.data_type == DataType.CUSTOM:
      self.payload_buf.apply(req, self.item_cfg)

    # CHI-E DAT tag metadata is stamped onto the post-randomize per-beat arrays
    # (mirrors the SV set_dat_tagop / set_tag / set_tu after randomize()).
    req.dat_tagop = self.dat_tagop_val
    for beat in range(len(req.tag)):
      if beat < len(self.tag_val):
        req.tag[beat] = self.tag_val[beat]
    for beat in range(len(req.tu)):
      if beat < len(self.tu_val):
        req.tu[beat] = self.tu_val[beat]

    return req

  def preview_next_request(self):
    return self.build_request_item(0)

  # ==========================================================================
  async def body(self):
    if (self.cfg.requests == VIP_CHI_UNLIMITED_REQUESTS
        and self.item_cfg.data_type != DataType.CUSTOM):
      raise RuntimeError(
        f"[{self.get_name()}] unlimited requests only supported in CUSTOM mode")

    if self.pipelined_send:
      await self._pipelined_body()
      return

    request_idx = 0
    while True:
      if (self.cfg.requests != VIP_CHI_UNLIMITED_REQUESTS
          and request_idx >= self.cfg.requests):
        break
      if self.item_cfg.data_type == DataType.CUSTOM and self.payload_buf.exhausted():
        break

      await self.apply_request_delay(request_idx)
      self.cfg.log_status(request_idx, self.access_name(), self.get_name())

      req = self.build_request_item(request_idx)
      await self.start_item(req)
      await self.finish_item(req)

      if self.item_cfg.get_response:
        self.responses.append(req)

      self.counter_iter.advance(req, self.item_cfg)
      self.addr_iter.advance(int(req.size))
      request_idx += 1

  async def _pipelined_body(self):
    # Pipelined send: launch every request first, then drain completions. Against
    # the multi-outstanding driver, item_done() fires at REQUEST ACCEPTANCE (so
    # finish_item() returns before the transaction completes and the next request
    # can enter the pipeline). The completed item is therefore NOT ready when
    # finish_item() returns, so each request carries a `_mo_evt` completion event
    # the driver sets on retire; we await all of them before collecting. Against
    # the serial driver, item_done() fires at completion and the event is set then
    # too, so the same barrier collapses to in-order collection.
    reqs = []
    if self.item_cfg.data_type == DataType.CUSTOM:
      n = 0
      while not self.payload_buf.exhausted():
        self.cfg.log_status(n, self.access_name(), self.get_name())
        req = self.build_request_item(n)
        req._mo_evt = Event()
        await self.start_item(req)
        await self.finish_item(req)
        reqs.append(req)
        self.counter_iter.advance(req, self.item_cfg)
        self.addr_iter.advance(int(req.size))
        n += 1
    else:
      if self.cfg.requests == VIP_CHI_UNLIMITED_REQUESTS:
        raise RuntimeError(f"[{self.get_name()}] pipelined_send needs a bounded count")
      for i in range(self.cfg.requests):
        self.cfg.log_status(i, self.access_name(), self.get_name())
        req = self.build_request_item(i)
        req._mo_evt = Event()
        await self.start_item(req)
        await self.finish_item(req)
        reqs.append(req)
        self.counter_iter.advance(req, self.item_cfg)
        self.addr_iter.advance(int(req.size))

    for req in reqs:
      await req._mo_evt.wait()

    if self.item_cfg.get_response:
      self.responses.extend(reqs)
