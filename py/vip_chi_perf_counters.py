################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of vip_chi_perf_counters.sv.
#
# Standalone, always-on performance instrumentation: it subscribes to the
# integrated requester stream's REQ/RSP/DAT analysis ports and aggregates
# timing/throughput statistics. It never fails a test -- it only prints a summary
# line at report_phase. The vif (a ChiBus) is handed over by the env in
# connect_phase and used purely as a deterministic reset-gated cycle + tx-channel
# back-pressure source; the component is inert (run_phase returns) if it is never
# wired.
#
# The SV per-TxnID arrays become plain dicts keyed by TxnID (the milestone
# bookkeeping is sparse and first-completion-wins, so a dict is 1:1 in behaviour).
#
################################################################################

from __future__ import annotations

from pyuvm import uvm_component

from vip_chi_types_pkg import (
  Role, ReqOpcode, RspOpcode, DatOpcode, req_opcode_is_atomic,
)
from vip_chi_analysis_imp import vip_chi_analysis_imp

PERF_WINDOW_CYCLES_C = 1000

_WRITE_REQ_OPCODES = {
  int(ReqOpcode.WRITE_NO_SNP_FULL), int(ReqOpcode.WRITE_NO_SNP_PTL),
  int(ReqOpcode.WRITE_NO_SNP_ZERO),
}
_WRITE_COMPLETION_RSP = {int(RspOpcode.COMP), int(RspOpcode.COMP_DBID_RESP)}
_READ_COMPLETION_DAT = {int(DatOpcode.COMP_DATA), int(DatOpcode.DATA_SEP_RESP)}


class vip_chi_perf_counters(uvm_component):

  def __init__(self, name, parent):
    super().__init__(name, parent)
    # Master gate (set from tb_cfg.perf_enable by the env).
    self.enable = True
    # Deterministic cycle / reset / back-pressure source (a ChiBus), set by env.
    self.vif = None
    self.req_perf = None
    self.rsp_perf = None
    self.dat_perf = None
    self._clear_all()

  def _clear_all(self):
    self.cycle_count = 0
    self.reset_count = 0
    self.retry_count = 0
    self.read_count = 0
    self.read_lat_sum = 0
    self.read_lat_min = 0
    self.read_lat_max = 0
    self.write_count = 0
    self.write_lat_sum = 0
    self.write_lat_min = 0
    self.write_lat_max = 0
    self.completions_in_window = 0
    self.windows_closed = 0
    self.peak_completions_per_window = 0
    self.bp_req_cycles = 0
    self.bp_rsp_cycles = 0
    self.bp_dat_cycles = 0
    # Per-transaction issue bookkeeping (indexed by requester TxnID).
    self.start_valid_by_txn = {}
    self.is_write_by_txn = {}
    self.done_by_txn = {}

  # ==========================================================================
  def build_phase(self):
    self.req_perf = vip_chi_analysis_imp("req_perf", self, self.write_req_perf)
    self.rsp_perf = vip_chi_analysis_imp("rsp_perf", self, self.write_rsp_perf)
    self.dat_perf = vip_chi_analysis_imp("dat_perf", self, self.write_dat_perf)

  # Classify a request as write vs read from its OPCODE (the monitor does not
  # populate a reliable sequence-side direction on reconstructed items).
  def _req_is_write(self, opcode):
    op = int(opcode)
    return op in _WRITE_REQ_OPCODES or req_opcode_is_atomic(op)

  # ==========================================================================
  # Clear in-flight bookkeeping on reset; aggregates persist (cumulative).
  # ==========================================================================
  def handle_reset(self):
    self.reset_count += 1
    self.start_valid_by_txn.clear()
    self.done_by_txn.clear()

  def _record_latency(self, is_write, lat):
    if is_write:
      if self.write_count == 0 or lat < self.write_lat_min:
        self.write_lat_min = lat
      if lat > self.write_lat_max:
        self.write_lat_max = lat
      self.write_lat_sum += lat
      self.write_count += 1
    else:
      if self.read_count == 0 or lat < self.read_lat_min:
        self.read_lat_min = lat
      if lat > self.read_lat_max:
        self.read_lat_max = lat
      self.read_lat_sum += lat
      self.read_count += 1
    self.completions_in_window += 1

  # Retire a transaction (first completion milestone wins).
  #
  # The latency comes off the ITEM, not from a private start-cycle shadow kept
  # here. The monitor already stamped every milestone, and two independent
  # measurements of one interval can only drift apart -- when they do, the
  # aggregate quietly disagrees with what a test reads off the transaction and
  # there is nothing in the report to say which is right. tc_chi_item_timestamps
  # asserts the two agree, so this keeps them the same number by construction.
  #
  # Retry semantics are unchanged: item.latency() measures from the re-issue,
  # which is what the start-cycle shadow did too (write_req_perf re-stamped on
  # every REQ observation, including the re-issued one).
  def _complete_txn(self, txn_id, item):
    t = int(txn_id)
    if not self.start_valid_by_txn.get(t, False) or self.done_by_txn.get(t, False):
      return
    self.done_by_txn[t] = True
    self._record_latency(self.is_write_by_txn.get(t, False), item.latency())

  # ==========================================================================
  # Analysis callbacks: stamp REQ issue, retire on the completion milestone.
  # ==========================================================================
  def write_req_perf(self, item):
    if not self.enable or int(item.role) != int(Role.RNI):
      return
    t = int(item.txn_id)
    self.start_valid_by_txn[t] = True
    self.is_write_by_txn[t] = self._req_is_write(item.opcode)
    self.done_by_txn[t] = False

  def write_rsp_perf(self, item):
    if not self.enable:
      return
    if int(item.rsp_opcode) == int(RspOpcode.RETRY_ACK):
      self.retry_count += 1
      return
    # Write completion milestone: first Comp / CompDBIDResp from the completer.
    if int(item.role) == int(Role.SNF) and int(item.rsp_opcode) in _WRITE_COMPLETION_RSP:
      self._complete_txn(item.txn_id, item)

  def write_dat_perf(self, item):
    if not self.enable:
      return
    # Read completion milestone: CompData / DataSepResp from the completer.
    if int(item.role) == int(Role.SNF) and int(item.dat_opcode) in _READ_COMPLETION_DAT:
      self._complete_txn(item.txn_id, item)

  # ==========================================================================
  # Deterministic cycle base + throughput windows + back-pressure sampling.
  # ==========================================================================
  async def run_phase(self):
    if self.vif is None:
      return
    bus = self.vif
    while True:
      await bus.rising()
      await bus.read_only()
      if bus.in_reset():
        continue

      self.cycle_count += 1

      if (self.cycle_count % PERF_WINDOW_CYCLES_C) == 0:
        if self.completions_in_window > self.peak_completions_per_window:
          self.peak_completions_per_window = self.completions_in_window
        self.windows_closed += 1
        self.completions_in_window = 0

      if bus.get_or("txreqflitpend") and not bus.get_or("txreqflitv"):
        self.bp_req_cycles += 1
      if bus.get_or("txrspflitpend") and not bus.get_or("txrspflitv"):
        self.bp_rsp_cycles += 1
      if bus.get_or("txdatflitpend") and not bus.get_or("txdatflitv"):
        self.bp_dat_cycles += 1

  # ==========================================================================
  # Public accessors (used by the anti-vacuity smoke test).
  # ==========================================================================
  def get_cycle_count(self):
    return self.cycle_count

  def get_read_count(self):
    return self.read_count

  def get_write_count(self):
    return self.write_count

  def get_read_lat_sum(self):
    return self.read_lat_sum

  def get_write_lat_sum(self):
    return self.write_lat_sum

  def get_retry_count(self):
    return self.retry_count

  def get_reset_count(self):
    return self.reset_count

  # ==========================================================================
  # One-line summary at end of test.
  # ==========================================================================
  def report_phase(self):
    if not self.enable:
      return
    total_completions = self.read_count + self.write_count
    read_lat_avg = (self.read_lat_sum // self.read_count) if self.read_count else 0
    write_lat_avg = (self.write_lat_sum // self.write_count) if self.write_count else 0
    avg_per_window = (total_completions // self.windows_closed) if self.windows_closed \
      else total_completions

    self.logger.info(
      "PERF SUMMARY: cycles=%d resets=%d | reads=%d lat(min/avg/max)=%d/%d/%d | "
      "writes=%d lat(min/avg/max)=%d/%d/%d | retries=%d | "
      "throughput(avg/peak per %dc)=%d/%d | backpressure(req/rsp/dat)=%d/%d/%d" % (
        self.cycle_count, self.reset_count,
        self.read_count, self.read_lat_min, read_lat_avg, self.read_lat_max,
        self.write_count, self.write_lat_min, write_lat_avg, self.write_lat_max,
        self.retry_count, PERF_WINDOW_CYCLES_C, avg_per_window,
        self.peak_completions_per_window,
        self.bp_req_cycles, self.bp_rsp_cycles, self.bp_dat_cycles))
