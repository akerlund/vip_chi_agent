################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of vip_chi_driver_snf.sv (serial auto-responder path).
#
# SN-F completer. driver_start() forks the credit loop, activates the link, and
# runs seq_loop(): each cycle it samples the REQ channel and, on an inbound
# request, returns the REQ credit and drives the opcode-specific auto response:
#   * ReadNoSnp[Sep]        -> (ordered: ReadReceipt) + CompData/DataSepResp burst
#   * WriteNoSnp{Full,Ptl}  -> CompDBIDResp (or split DBIDResp+Comp), collect the
#                              DAT burst, commit into vip_mem, optional CompAck
#   * WriteNoSnpZero        -> zero the byte range, Comp
# Address-range DECERR/DERR injection mirrors the SV completer. Atomics and the
# separated-persist completions are Tier B and not dispatched here yet.
#
# Same ChiBus timing discipline as the RN-I driver: `@(snf_cb)` -> rising(),
# `snf_cb.rx*` -> get(), `snf_cb.tx* <=` -> drive()/drive_flit().
#
################################################################################

from __future__ import annotations

import cocotb

from pyuvm import uvm_driver, ConfigDB

from vip_chi_types_pkg import (
  Role, ReqOpcode, RspOpcode, DatOpcode, Resp, RespErr, RawChannel,
  chi_xfer_dat_beats, req_opcode_is_atomic, req_opcode_is_atomic_compare,
  req_opcode_is_atomic_returning_data, req_opcode_atomic_variant, mask,
)
from vip_chi_if import ChiBus
from vip_chi_lcrd_mgr import VipChiLcrdMgr
from vip_chi_cfg_agent import VipChiCfgAgent
from vip_mem import vip_mem

_I = int

_AUTO_READ = {int(ReqOpcode.READ_NO_SNP), int(ReqOpcode.READ_NO_SNP_SEP)}
_AUTO_WRITE = {int(ReqOpcode.WRITE_NO_SNP_FULL), int(ReqOpcode.WRITE_NO_SNP_PTL)}
_AUTO_WRITE_ZERO = {int(ReqOpcode.WRITE_NO_SNP_ZERO)}
_AUTO_PERSIST = {int(ReqOpcode.CLEAN_SHARED_PERSIST),
                 int(ReqOpcode.CLEAN_SHARED_PERSIST_SEP)}


class vip_chi_driver_snf(uvm_driver):

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.bus = None
    self.cfg = None
    self.role = Role.SNF
    self.mem = None
    self.mem_rows_written = set()
    # CHI-E MTE tag store: row index -> (dat_tagop, tag, tu), captured from write
    # DAT beats and replayed on the auto-read CompData so tags round-trip.
    self.tag_mem = {}

    self.rsp_lcrd = VipChiLcrdMgr("rsp_lcrd_mgr")
    self.dat_lcrd = VipChiLcrdMgr("dat_lcrd_mgr")
    self.req_lcrdv_pending = 0
    self.rsp_lcrdv_pending = 0
    self.dat_lcrdv_pending = 0
    self.retries_issued = 0

    # Buffered inbound REQ flits awaiting an auto-response, used only on the
    # multi-outstanding path so a pipelined REQ arriving mid-response is queued
    # rather than dropped.
    self.captured_reqs = []

    self._driver_tasks = []
    self.agent_owned = False

    # TXSACTIVE outstanding-window state. See tx_activity_begin().
    self.tx_active_count = 0
    self._tx_active_extend = 0

  # ==========================================================================
  # TXSACTIVE outstanding-window drive.
  #
  # Deliberately the same shape as vip_chi_driver_rni's -- same method names,
  # same counter semantics -- rather than a shared base: the SV SN-F does not
  # inherit the SV RN-I either, and the two flows are kept structurally
  # parallel so a reader can diff them.
  #
  # TXSACTIVE must span the whole window in which this node may have snoopable
  # transactions outstanding, not bracket each flit. For a completer that
  # window runs from taking a request off the wire to finishing its last
  # completion flit, so the count -- not any one response -- decides the level.
  # ==========================================================================
  def tx_activity_begin(self):
    self.tx_active_count += 1
    self._tx_active_extend = 0
    self.bus.drive(txsactive=1)

  def tx_activity_end(self):
    if self.tx_active_count > 0:
      self.tx_active_count -= 1
    if self.tx_active_count == 0:
      self._tx_active_extend = max(0, int(self.cfg.txsactive_extend_max_cycles))

  # Called once per cycle from credit_loop, so the extension counts cycles
  # rather than callers.
  def tx_activity_tick(self):
    if self.tx_active_count > 0:
      return
    if self._tx_active_extend > 0:
      self._tx_active_extend -= 1
      return
    self.bus.drive(txsactive=0)

  # ==========================================================================
  def build_phase(self):
    self.bus = ConfigDB().get(self, "", "vif")
    try:
      self.cfg = ConfigDB().get(self, "", "cfg")
    except Exception:
      self.cfg = VipChiCfgAgent("default_cfg")
      self.cfg.role = Role.SNF
    cfg = self.bus.cfg
    self.mem = vip_mem("mem", row_bytes=cfg.data_bytes, addr_width=cfg.addr_width)
    self.mem.reset()
    self.reset_credit_state()

  # -- fork registry ---------------------------------------------------------
  def _spawn(self, coro):
    self._driver_tasks = [t for t in self._driver_tasks if not t.done()]
    t = cocotb.start_soon(coro)
    self._driver_tasks.append(t)
    return t

  def _kill_driver_tasks(self):
    for t in self._driver_tasks:
      try:
        if not t.done():
          t.kill()
      except Exception:
        pass
    self._driver_tasks = []

  # ==========================================================================
  # Credit bookkeeping.
  # ==========================================================================
  def reset_credit_state(self):
    self.rsp_lcrd.reset(self.cfg.rsp_send_credit_cap, 0)
    self.dat_lcrd.reset(self.cfg.dat_send_credit_cap, 0)
    self.req_lcrdv_pending = 0
    self.rsp_lcrdv_pending = 0
    self.dat_lcrdv_pending = 0

  def schedule_initial_credit_grants(self):
    self.req_lcrdv_pending += self.cfg.initial_req_credits
    self.rsp_lcrdv_pending += self.cfg.initial_rsp_credits
    self.dat_lcrdv_pending += self.cfg.initial_dat_credits

  def schedule_req_credit_return(self):
    self.req_lcrdv_pending += 1

  def schedule_rsp_credit_return(self):
    self.rsp_lcrdv_pending += 1

  def schedule_dat_credit_return(self):
    self.dat_lcrdv_pending += 1

  # ==========================================================================
  # Interface reset.
  # ==========================================================================
  def reset_outputs(self):
    bus = self.bus
    bus.drive(txlinkactivereq=0, txlinkactiveack=0, txsactive=0)
    bus.drive(txreqlcrdv=0)
    bus.drive(txrspflitpend=0, txrspflitv=0, txrsplcrdv=0)
    bus.drive_flit("rsp", {})
    bus.drive(txdatflitpend=0, txdatflitv=0, txdatlcrdv=0)
    bus.drive_flit("dat", {})
    if self.mem is not None:
      self.mem.reset()
    self.mem_rows_written = set()
    self.tag_mem = {}

  def reset_vif(self):
    self.reset_outputs()

  def handle_reset(self):
    self._kill_driver_tasks()
    self.retries_issued = 0
    self.captured_reqs = []
    self.tx_active_count = 0
    self._tx_active_extend = 0
    self.reset_credit_state()
    self.reset_outputs()

  def drive_idle_sideband(self):
    self.bus.drive(txlinkactiveack=self.bus.get("rxlinkactivereq"))

  # ==========================================================================
  # Backing-store row bookkeeping (served data falls back to a deterministic
  # pattern for untouched rows so untouched-address smokes stay stable).
  # ==========================================================================
  def _row_index(self, addr):
    return _I(addr) // self.bus.cfg.data_bytes

  def _mark_row(self, addr):
    self.mem_rows_written.add(self._row_index(addr))

  def _has_row(self, addr):
    return self._row_index(addr) in self.mem_rows_written

  def _addr_in_range(self, addr, base, limit):
    a = _I(addr) & ((1 << self.bus.cfg.addr_width) - 1)
    return base <= a <= limit

  def decerr_check(self, addr):
    return any(self._addr_in_range(addr, b, l) for b, l in self.cfg.decerr_ranges)

  def derr_check(self, addr):
    if self.decerr_check(addr):
      return False
    return any(self._addr_in_range(addr, b, l) for b, l in self.cfg.derr_ranges)

  def auto_read_data(self, addr, beat_index):
    dw = self.bus.cfg.data_bytes * 8
    return (_I(addr) + beat_index) & ((1 << dw) - 1)

  # Beat position carried by the send_index'th DAT beat of a read burst. CHI
  # places a beat by its DataID rather than by its position in the burst, so the
  # completer may send the positions in any order as long as each beat carries
  # the payload belonging to the DataID it announces.
  #
  #   default                    : ascending, 0 .. beat_count-1
  #   cfg.snf_reverse_dat_beats  : descending, beat_count-1 .. 0
  #   cfg.snf_duplicate_dat_beat : the last send repeats position 0, so one
  #     position is delivered twice and the last position never at all -- the
  #     negative control for the monitor's duplicate/missing DataID checks
  #
  # A single-beat transfer has nothing to reorder, so both knobs are inert.
  def dat_beat_position(self, send_index, beat_count):
    if beat_count <= 1:
      return send_index
    if self.cfg.snf_duplicate_dat_beat and send_index == (beat_count - 1):
      return 0
    if self.cfg.snf_reverse_dat_beats:
      return beat_count - 1 - send_index
    return send_index

  def read_data_beat(self, addr, beat_index):
    beat_addr = _I(addr) + beat_index * self.bus.cfg.data_bytes
    if self._has_row(beat_addr):
      return _I(self.mem.rd_addr(beat_addr))
    return self.auto_read_data(addr, beat_index)

  # ==========================================================================
  async def run_phase(self):
    if self.agent_owned:
      return
    self.reset_vif()
    while self.bus.in_reset():
      await self.bus.rising()
    await self.driver_start()

  # ==========================================================================
  async def driver_start(self):
    self._spawn(self.credit_loop())
    await self.activate_link()
    # Manual completion injection runs alongside the wire-observing auto-responder
    # (SV polls try_next_item inside the serial loop; pyUVM has no non-blocking
    # poll, so the manual path is a dedicated coroutine that blocks on the SN-F
    # sequencer). Tests that inject manual completions keep the RN-I idle, so the
    # two never contend for the RSP/DAT channels.
    self._spawn(self.manual_dispatch_loop())
    if self.cfg.multi_outstanding:
      await self.seq_loop_buffered()
    else:
      await self.seq_loop()

  # ==========================================================================
  # Manual SN-F completion dispatch (vip_chi_pipelined_seq): pull each pre-built
  # completion item off the sequencer and drive it verbatim. Channel select
  # mirrors the SV: raw_override -> raw relay, data present -> DAT, else RSP.
  # ==========================================================================
  async def manual_dispatch_loop(self):
    while True:
      item = await self.seq_item_port.get_next_item()
      # A manually injected completion is outbound activity that no captured
      # request accounts for, so it opens a window of its own.
      self.tx_activity_begin()
      try:
        if getattr(item, "raw_override", False):
          await self.drive_raw_item(item)
        elif len(item.data) > 0:
          await self.drive_dat_item(item)
        else:
          await self.drive_rsp_item(item)
      finally:
        self.tx_activity_end()
      self.seq_item_port.item_done()

  # --------------------------------------------------------------------------
  async def credit_loop(self):
    bus = self.bus
    while True:
      await bus.rising()
      self.drive_idle_sideband()
      self.tx_activity_tick()
      bus.drive(txreqlcrdv=1 if self.req_lcrdv_pending else 0)
      bus.drive(txrsplcrdv=1 if self.rsp_lcrdv_pending else 0)
      bus.drive(txdatlcrdv=1 if self.dat_lcrdv_pending else 0)
      if self.req_lcrdv_pending:
        self.req_lcrdv_pending -= 1
      if self.rsp_lcrdv_pending:
        self.rsp_lcrdv_pending -= 1
      if self.dat_lcrdv_pending:
        self.dat_lcrdv_pending -= 1
      if bus.get("rxrsplcrdv"):
        self.rsp_lcrd.return_credit()
      if bus.get("rxdatlcrdv"):
        self.dat_lcrd.return_credit()

  # --------------------------------------------------------------------------
  async def wait_for_credit(self, lcrd):
    bus = self.bus
    while True:
      if lcrd.try_acquire_credit():
        return
      await bus.rising()
      self.drive_idle_sideband()

  # --------------------------------------------------------------------------
  async def activate_link(self):
    bus = self.bus
    while True:
      await bus.rising()
      self.drive_idle_sideband()
      if bus.in_reset() or bus.get("rxlinkactivereq"):
        break
    self.schedule_initial_credit_grants()

  # ==========================================================================
  # Main serial responder loop (auto-responder path).
  #
  # The SN-F is a pure completer here: it samples the REQ channel every cycle and
  # drives the opcode-specific auto response. The SV loop also polls the
  # sequencer (try_next_item) for manual SN-F RSP/DAT items; pyUVM's seq_item
  # port has no non-blocking poll, so manual SN-F sequences (drive_rsp_item /
  # drive_dat_item / drive_raw_item) are a Tier-B concern and this A2 loop is
  # purely the wire-observing auto-responder.
  # ==========================================================================
  async def seq_loop(self):
    bus = self.bus
    while True:
      await bus.rising()
      self.drive_idle_sideband()

      if not bus.get("rxreqflitv"):
        continue

      req = bus.sample_flit("req", "rx")
      self.schedule_req_credit_return()
      # The window opens when the request comes off the wire -- from here until
      # the last completion flit this node owes a response, which is exactly
      # what TXSACTIVE reports.
      self.tx_activity_begin()
      try:
        await self.dispatch_auto_response(req)
      finally:
        self.tx_activity_end()

  # ==========================================================================
  # Buffered responder loop (opt-in via cfg.multi_outstanding): one coroutine
  # captures every inbound REQ into a queue (returning its REQ credit at once),
  # a second drains the queue and drives each auto-response. Decoupling capture
  # from response means a request that arrives while an earlier burst is still
  # being driven is buffered rather than dropped -- which is what lets the RN-I
  # keep several transactions outstanding.
  # ==========================================================================
  async def seq_loop_buffered(self):
    self._spawn(self.req_capture_loop())
    await self.req_response_loop()

  async def req_capture_loop(self):
    bus = self.bus
    while True:
      await bus.rising()
      self.drive_idle_sideband()
      if bus.get("rxreqflitv"):
        self.schedule_req_credit_return()
        self.captured_reqs.append(bus.sample_flit("req", "rx"))
        # Opened at capture, not at dispatch: a buffered request is already
        # outstanding while it waits its turn in the queue, and the sideband
        # has to say so.
        self.tx_activity_begin()

  async def req_response_loop(self):
    bus = self.bus
    while True:
      if self.captured_reqs:
        req = self.captured_reqs.pop(0)
        try:
          await self.dispatch_auto_response(req)
        finally:
          self.tx_activity_end()
      else:
        await bus.rising()
        self.drive_idle_sideband()

  # ==========================================================================
  # Drive the SN-F auto-response for one REQ (already off the wire, credit
  # already returned by the caller). Shared by the serial and buffered loops.
  # ==========================================================================
  async def dispatch_auto_response(self, req):
    if self.should_auto_retry(req):
      self.retries_issued += 1
      await self.drive_auto_retry(req)
      return

    op = req["opcode"]
    if op in _AUTO_READ:
      await self.drive_auto_read_compdata(req)
    elif op == int(ReqOpcode.PREFETCH_TGT):
      return  # PrefetchTgt is a hint with no completion
    elif op in _AUTO_PERSIST:
      await self.drive_auto_persist_rsp(req)
    elif req_opcode_is_atomic(op):
      await self.drive_auto_atomic_completion(req)
    elif op in _AUTO_WRITE_ZERO:
      await self.drive_auto_write_zero_comp(req)
    elif op in _AUTO_WRITE:
      await self.drive_auto_write_comp(req)

  # ==========================================================================
  # Persist CMO auto-response: a single Comp for CleanSharedPersist, or an
  # intermediate Persist followed by a final CompPersist for the CHI-E
  # CleanSharedPersistSep. Carries no data and grants no DBID.
  # ==========================================================================
  async def drive_auto_persist_rsp(self, req):
    is_sep = req["opcode"] == int(ReqOpcode.CLEAN_SHARED_PERSIST_SEP)
    base = {
      "srcid": req["tgtid"], "tgtid": req["srcid"], "txnid": req["txnid"],
      "qos": req["qos"], "resp": int(Resp.I), "resperr": int(RespErr.OKAY),
    }
    first = dict(base)
    first["opcode"] = int(RspOpcode.PERSIST if is_sep else RspOpcode.COMP)
    await self.drive_rsp(first)

    if is_sep:
      second = dict(base)
      second["opcode"] = int(RspOpcode.COMP_PERSIST)
      await self.drive_rsp(second)

  # ==========================================================================
  # Opcode classifiers / helpers.
  # ==========================================================================
  def req_has_ordering(self, req):
    return req["order"] != 0

  def should_auto_retry(self, req):
    return (self.retries_issued < self.cfg.force_retry_count) and req["allowretry"]

  # ==========================================================================
  # RSP / DAT flit drivers (shared by auto responses and manual items).
  # ==========================================================================
  async def drive_rsp(self, fields):
    bus = self.bus
    await self.wait_for_credit(self.rsp_lcrd)
    await bus.rising()
    self.drive_idle_sideband()
    bus.drive(txrspflitpend=0, txrspflitv=1)
    bus.drive_flit("rsp", fields)
    await bus.rising()
    self.drive_idle_sideband()
    bus.drive(txrspflitv=0)
    bus.drive_flit("rsp", {})

  async def drive_rsp_item(self, rsp):
    fields = {
      "dbid": _I(rsp.dbid), "fwdstate": _I(rsp.fwd_state),
      "resp": _I(rsp.rsp_resp), "resperr": _I(rsp.rsp_resp_err),
      "opcode": _I(rsp.rsp_opcode), "txnid": _I(rsp.txn_id),
      "srcid": _I(rsp.src_id), "tgtid": _I(rsp.tgt_id),
      "pcrdtype": _I(rsp.pcrd_type), "qos": _I(rsp.qos),
    }
    await self.drive_rsp(fields)

  async def drive_dat_item(self, rsp):
    bus = self.bus
    n = len(rsp.data)
    for i in range(n):
      fields = {
        "data": _I(rsp.data[i]), "be": _I(rsp.be[i]),
        "dataid": i, "ccid": 0, "dbid": _I(rsp.dbid),
        "resp": _I(rsp.dat_resp[i]) if i < len(rsp.dat_resp) else _I(rsp.rsp_resp),
        "resperr": _I(rsp.dat_resp_err[i]) if i < len(rsp.dat_resp_err) else _I(rsp.rsp_resp_err),
        "opcode": _I(rsp.dat_opcode), "txnid": _I(rsp.txn_id),
        "srcid": _I(rsp.src_id), "tgtid": _I(rsp.tgt_id), "qos": _I(rsp.qos),
      }
      if bus.cfg.is_e:
        fields["tagop"] = _I(rsp.dat_tagop)
        fields["tag"] = _I(rsp.tag[i]) if i < len(rsp.tag) else 0
        fields["tu"] = _I(rsp.tu[i]) if i < len(rsp.tu) else 0
      await self.wait_for_credit(self.dat_lcrd)
      await bus.rising()
      self.drive_idle_sideband()
      bus.drive(txdatflitpend=1 if i != (n - 1) else 0, txdatflitv=1)
      bus.drive_flit("dat", fields)
      await bus.rising()
      self.drive_idle_sideband()
      bus.drive(txdatflitpend=0, txdatflitv=0)
      bus.drive_flit("dat", {})
    await bus.rising()
    self.drive_idle_sideband()

  # ==========================================================================
  # Auto responses.
  # ==========================================================================
  async def drive_auto_read_receipt(self, req):
    await self.drive_rsp({
      "opcode": int(RspOpcode.READ_RECEIPT), "srcid": req["tgtid"],
      "tgtid": req["srcid"], "txnid": req["txnid"], "qos": req["qos"],
      "resp": int(Resp.I), "resperr": int(RespErr.OKAY),
    })

  async def drive_auto_retry(self, req):
    pcrd = 0x1
    await self.drive_rsp({
      "opcode": int(RspOpcode.RETRY_ACK), "srcid": req["tgtid"],
      "tgtid": req["srcid"], "txnid": req["txnid"], "qos": req["qos"],
      "pcrdtype": pcrd, "resp": int(Resp.I), "resperr": int(RespErr.OKAY),
    })
    await self.drive_rsp({
      "opcode": int(RspOpcode.PCRD_GRANT), "srcid": req["tgtid"],
      "tgtid": req["srcid"], "txnid": 0, "qos": req["qos"],
      "pcrdtype": pcrd, "resp": int(Resp.I), "resperr": int(RespErr.OKAY),
    })

  async def drive_auto_write_comp(self, req):
    bus = self.bus
    cfg = self.bus.cfg
    req_addr = req["addr"]
    req_txn = req["txnid"]
    req_src = req["srcid"]
    req_tgt = req["tgtid"]
    beat_count = chi_xfer_dat_beats(req["size"], cfg.data_bytes)
    is_decerr = self.decerr_check(req_addr)

    err = int(RespErr.NDERR) if is_decerr else int(RespErr.OKAY)
    split = self.cfg.split_write_rsp
    if split:
      if cfg.is_e and self.cfg.ordered_dbid_resp and self.req_has_ordering(req):
        grant_op = int(RspOpcode.DBID_RESP_ORD)
      else:
        grant_op = int(RspOpcode.DBID_RESP)
    else:
      grant_op = int(RspOpcode.COMP_DBID_RESP)

    await self.drive_rsp({
      "opcode": grant_op, "srcid": req_tgt, "tgtid": req_src,
      "txnid": req_txn, "dbid": req_txn, "qos": req["qos"],
      "resp": int(Resp.I), "resperr": err,
    })

    write_data, write_be, write_tags = [], [], []
    for beat_index in range(beat_count):
      while not bus.get("rxdatflitv"):
        await bus.rising()
        self.drive_idle_sideband()
      flit = bus.sample_flit("dat", "rx")
      if flit["txnid"] != req_txn:
        raise AssertionError(
          f"[{self.get_name()}] Write DAT txnid 0x{flit['txnid']:x} "
          f"!= granted DBID 0x{req_txn:x}")
      if flit["dbid"] != req_txn:
        raise AssertionError(
          f"[{self.get_name()}] Write DAT dbid 0x{flit['dbid']:x} "
          f"!= granted DBID 0x{req_txn:x}")
      if flit["srcid"] != req_src or flit["tgtid"] != req_tgt:
        raise AssertionError(
          f"[{self.get_name()}] Write DAT src/tgt 0x{flit['srcid']:x}->"
          f"0x{flit['tgtid']:x} != expected 0x{req_src:x}->0x{req_tgt:x}")
      self.schedule_dat_credit_return()
      write_data.append(flit["data"])
      write_be.append(flit["be"])
      if cfg.is_e:
        write_tags.append((flit.get("tagop", 0), flit.get("tag", 0), flit.get("tu", 0)))
      if not bus.get("rxdatflitpend"):
        break
      await bus.rising()
      self.drive_idle_sideband()

    if not is_decerr:
      self.mem.wr_be(req_addr, write_data, write_be)
      for i in range(len(write_data)):
        self._mark_row(req_addr + i * cfg.data_bytes)
        if cfg.is_e and i < len(write_tags):
          self.tag_mem[self._row_index(req_addr + i * cfg.data_bytes)] = write_tags[i]

    if split:
      await self.drive_rsp({
        "opcode": int(RspOpcode.COMP), "srcid": req_tgt, "tgtid": req_src,
        "txnid": req_txn, "dbid": req_txn, "qos": req["qos"],
        "resp": int(Resp.I), "resperr": err,
      })

    if req["expcompack"]:
      await self.wait_for_comp_ack(req_txn, req_src, req_tgt)

  async def drive_auto_write_zero_comp(self, req):
    cfg = self.bus.cfg
    req_addr = req["addr"]
    is_decerr = self.decerr_check(req_addr)
    transfer_bytes = 1 << req["size"]
    beat_count = chi_xfer_dat_beats(req["size"], cfg.data_bytes)

    if not is_decerr:
      remaining = transfer_bytes
      zero_data, zero_be = [], []
      for _ in range(beat_count):
        zero_data.append(0)
        n = min(remaining, cfg.data_bytes)
        zero_be.append((1 << n) - 1)
        remaining -= n
      self.mem.wr_be(req_addr, zero_data, zero_be)
      first_row = self._row_index(req_addr)
      last_row = self._row_index(req_addr + transfer_bytes - 1)
      for row in range(first_row, last_row + 1):
        self.mem_rows_written.add(row)

    await self.drive_rsp({
      "opcode": int(RspOpcode.COMP), "srcid": req["tgtid"], "tgtid": req["srcid"],
      "txnid": req["txnid"], "dbid": req["txnid"], "qos": req["qos"],
      "resp": int(Resp.I),
      "resperr": int(RespErr.NDERR) if is_decerr else int(RespErr.OKAY),
    })

  async def drive_auto_read_compdata(self, req):
    bus = self.bus
    cfg = self.bus.cfg
    req_size = req["size"]
    req_addr = req["addr"]
    req_txn = req["txnid"]
    req_src = req["srcid"]
    req_tgt = req["tgtid"]
    is_sep = (req["opcode"] == int(ReqOpcode.READ_NO_SNP_SEP))
    rsp_txn = req["returntxnid"] if is_sep else req_txn
    rsp_tgt = req["returnnid"] if is_sep else req_src
    is_decerr = self.decerr_check(req_addr)
    is_derr = self.derr_check(req_addr)
    beat_count = chi_xfer_dat_beats(req_size, cfg.data_bytes)

    resp_code = int(Resp.I)
    if is_decerr:
      resp_err = int(RespErr.NDERR)
    else:
      resp_err = int(RespErr.DERR) if is_derr else int(RespErr.OKAY)

    if self.req_has_ordering(req):
      await self.drive_auto_read_receipt(req)

    if is_sep:
      await self.drive_rsp({
        "opcode": int(RspOpcode.RESP_SEP_DATA), "srcid": req_tgt, "tgtid": req_src,
        "txnid": req_txn, "dbid": req_txn, "qos": req["qos"],
        "resp": resp_code, "resperr": resp_err,
      })

    dat_op = int(DatOpcode.DATA_SEP_RESP) if is_sep else int(DatOpcode.COMP_DATA)
    be_all = (1 << cfg.be_width) - 1
    for send_index in range(beat_count):
      # Which beat position this send carries. The knobs move the position
      # without touching the payload, so a beat always carries the data
      # belonging to the DataID it announces.
      beat_index = self.dat_beat_position(send_index, beat_count)
      fields = {
        "data": 0 if is_decerr else self.read_data_beat(req_addr, beat_index),
        "be": 0 if is_decerr else be_all,
        "dataid": beat_index, "ccid": 0, "dbid": rsp_txn,
        "resp": resp_code, "resperr": resp_err, "opcode": dat_op,
        "homenid": req_tgt, "txnid": rsp_txn, "srcid": req_tgt,
        "tgtid": rsp_tgt, "qos": req["qos"],
      }
      if cfg.is_e:
        tg = self.tag_mem.get(self._row_index(req_addr + beat_index * cfg.data_bytes))
        fields["tagop"], fields["tag"], fields["tu"] = tg if tg is not None else (0, 0, 0)
      await self.wait_for_credit(self.dat_lcrd)
      await bus.rising()
      self.drive_idle_sideband()
      bus.drive(txdatflitpend=1 if send_index != (beat_count - 1) else 0,
                txdatflitv=1)
      bus.drive_flit("dat", fields)
      await bus.rising()
      self.drive_idle_sideband()
      bus.drive(txdatflitpend=0, txdatflitv=0)
      bus.drive_flit("dat", {})
    await bus.rising()
    self.drive_idle_sideband()

  def _apply_atomic_variant(self, variant, current, operand):
    dw = self.bus.cfg.data_bytes * 8
    m = mask(dw)
    cur = current & m
    opd = operand & m
    # signed views
    sign = 1 << (dw - 1)
    cur_s = cur - (1 << dw) if cur & sign else cur
    opd_s = opd - (1 << dw) if opd & sign else opd
    if variant == 0:
      return (cur + opd) & m
    if variant == 1:
      return (cur & (~opd & m)) & m
    if variant == 2:
      return (cur ^ opd) & m
    if variant == 3:
      return (cur | opd) & m
    if variant == 4:
      return cur if cur_s > opd_s else opd
    if variant == 5:
      return cur if cur_s < opd_s else opd
    if variant == 6:
      return cur if cur > opd else opd
    if variant == 7:
      return cur if cur < opd else opd
    raise AssertionError(f"[{self.get_name()}] unsupported atomic variant {variant}")

  async def drive_auto_atomic_completion(self, req):
    bus = self.bus
    cfg = self.bus.cfg
    req_addr = req["addr"]
    req_txn = req["txnid"]
    req_src = req["srcid"]
    req_tgt = req["tgtid"]
    op = req["opcode"]
    beat_count = chi_xfer_dat_beats(req["size"], cfg.data_bytes)
    returns_data = req_opcode_is_atomic_returning_data(op)
    is_compare = req_opcode_is_atomic_compare(op)
    # AtomicCompare Size spans compare+swap; the RMW granule is the first half.
    granule = (beat_count // 2) if is_compare else beat_count
    variant = req_opcode_atomic_variant(op)
    is_decerr = self.decerr_check(req_addr)
    is_derr = self.derr_check(req_addr)

    err = int(RespErr.NDERR) if is_decerr else int(RespErr.OKAY)
    # Returning-data atomics always split (DBID grant, then CompData); non-return
    # atomics split only when split_write_rsp is set, else combined CompDBIDResp.
    if returns_data or self.cfg.split_write_rsp:
      if cfg.is_e and self.cfg.ordered_dbid_resp and self.req_has_ordering(req):
        grant_op = int(RspOpcode.DBID_RESP_ORD)
      else:
        grant_op = int(RspOpcode.DBID_RESP)
    else:
      grant_op = int(RspOpcode.COMP_DBID_RESP)

    await self.drive_rsp({
      "opcode": grant_op, "srcid": req_tgt, "tgtid": req_src,
      "txnid": req_txn, "dbid": req_txn, "qos": req["qos"],
      "resp": int(Resp.I), "resperr": err,
    })

    operand = []
    for _ in range(beat_count):
      while not bus.get("rxdatflitv"):
        await bus.rising()
        self.drive_idle_sideband()
      flit = bus.sample_flit("dat", "rx")
      if flit["txnid"] != req_txn or flit["dbid"] != req_txn:
        raise AssertionError(f"[{self.get_name()}] atomic DAT id mismatch")
      if flit["srcid"] != req_src or flit["tgtid"] != req_tgt:
        raise AssertionError(f"[{self.get_name()}] atomic DAT src/tgt mismatch")
      self.schedule_dat_credit_return()
      operand.append(flit["data"])
      if not bus.get("rxdatflitpend"):
        break
      await bus.rising()
      self.drive_idle_sideband()

    # AtomicCompare needs both the compare and swap halves; a short DAT burst
    # (flitpend dropped early) would silently corrupt the compare below.
    if is_compare and len(operand) != beat_count:
      raise AssertionError(
        f"[{self.get_name()}] AtomicCompare expected {beat_count} operand beats, "
        f"got {len(operand)}")

    old = [0 if is_decerr else self.read_data_beat(req_addr, b) for b in range(granule)]

    if not is_decerr:
      if is_compare:
        match = all(old[b] == operand[b] for b in range(granule))
        new = [operand[b + granule] if match else old[b] for b in range(granule)]
      elif op == int(ReqOpcode.ATOMIC_SWAP):
        new = [operand[b] for b in range(beat_count)]
      else:
        new = [self._apply_atomic_variant(variant, old[b], operand[b])
               for b in range(beat_count)]
      be_all = (1 << cfg.be_width) - 1
      self.mem.wr_be(req_addr, new, [be_all] * granule)
      for i in range(len(new)):
        self._mark_row(req_addr + i * cfg.data_bytes)

    if returns_data:
      resp_err = err if is_decerr else (int(RespErr.DERR) if is_derr else int(RespErr.OKAY))
      be_all = (1 << cfg.be_width) - 1
      for b in range(granule):
        fields = {
          "data": old[b], "be": 0 if is_decerr else be_all,
          "dataid": b, "ccid": 0, "dbid": req_txn,
          "resp": int(Resp.I), "resperr": resp_err,
          "opcode": int(DatOpcode.COMP_DATA), "homenid": req_tgt,
          "txnid": req_txn, "srcid": req_tgt, "tgtid": req_src, "qos": req["qos"],
        }
        await self.wait_for_credit(self.dat_lcrd)
        await bus.rising()
        self.drive_idle_sideband()
        bus.drive(txdatflitpend=1 if b != (granule - 1) else 0, txdatflitv=1)
        bus.drive_flit("dat", fields)
        await bus.rising()
        self.drive_idle_sideband()
        bus.drive(txdatflitpend=0, txdatflitv=0)
        bus.drive_flit("dat", {})
      await bus.rising()
      self.drive_idle_sideband()
    elif self.cfg.split_write_rsp:
      await self.drive_rsp({
        "opcode": int(RspOpcode.COMP), "srcid": req_tgt, "tgtid": req_src,
        "txnid": req_txn, "dbid": req_txn, "qos": req["qos"],
        "resp": int(Resp.I), "resperr": err,
      })

    if req["expcompack"]:
      await self.wait_for_comp_ack(req_txn, req_src, req_tgt)

  async def wait_for_comp_ack(self, req_txn, req_src, req_tgt):
    bus = self.bus
    cycles = 0
    while not bus.get("rxrspflitv"):
      await bus.rising()
      self.drive_idle_sideband()
      cycles += 1
      if self.cfg.compack_timeout_cycles > 0 and cycles >= self.cfg.compack_timeout_cycles:
        raise AssertionError(
          f"[{self.get_name()}] Timed out waiting {cycles} cycles for CompAck "
          f"on txnid 0x{req_txn:x}")
    flit = bus.sample_flit("rsp", "rx")
    if flit["opcode"] != int(RspOpcode.COMP_ACK):
      raise AssertionError(
        f"[{self.get_name()}] Expected CompAck, got opcode 0x{flit['opcode']:x}")
    if flit["txnid"] != req_txn:
      raise AssertionError(
        f"[{self.get_name()}] CompAck txnid 0x{flit['txnid']:x} != 0x{req_txn:x}")
    if flit["srcid"] != req_src or flit["tgtid"] != req_tgt:
      raise AssertionError(
        f"[{self.get_name()}] CompAck src/tgt 0x{flit['srcid']:x}->0x{flit['tgtid']:x} "
        f"did not match expected 0x{req_src:x}->0x{req_tgt:x}")
    self.schedule_rsp_credit_return()

  # ==========================================================================
  # Raw-flit injection (RSP/DAT only for the completer).
  # ==========================================================================
  async def drive_raw_item(self, item):
    if not self.cfg.allow_raw_override:
      raise AssertionError(f"[{self.get_name()}] raw_override is disabled in cfg")
    bus = self.bus
    ch = _I(item.raw_channel)
    if ch == int(RawChannel.RSP):
      channel, raw_value = "rsp", item.raw_rsp
    elif ch == int(RawChannel.DAT):
      channel, raw_value = "dat", item.raw_dat
    else:
      raise AssertionError(
        f"[{self.get_name()}] SN-F raw_override only supports RSP or DAT")
    lcrd = self.rsp_lcrd if channel == "rsp" else self.dat_lcrd
    flitpend = 1 if getattr(item, "raw_flitpend", False) else 0
    await self.wait_for_credit(lcrd)
    await bus.rising()
    self.drive_idle_sideband()
    bus.drive(**{f"tx{channel}flitpend": flitpend, f"tx{channel}flitv": 1})
    bus.sig[f"tx{channel}flit"].value = int(raw_value)
    await bus.rising()
    self.drive_idle_sideband()
    bus.drive(**{f"tx{channel}flitpend": 0, f"tx{channel}flitv": 0})
    bus.drive_flit(channel, {})
