################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of vip_chi_coherency_checker.sv -- Checker D (coherency invariants),
# self-derived from observed traffic. Subscribes to both coherent RN-F streams
# (req/rsp/dat/snp) + the downstream SN-F req/dat, and maintains a per-line,
# per-node ownership shadow built ONLY from the wire -- never the HN-F directory
# it polices. Invariants:
#   * n_multi_owner  -- at most ONE node Unique per line at a time.
#   * n_coherent_data_mismatch -- a read of a line whose data was observed being
#     written must return exactly that data (predictable-only, like Checker C).
#   * n_excl_violation -- an SC reporting ExclOkay must have a continuously-valid
#     self-derived reservation.
#   * n_bad_make_unique -- MakeUnique must complete Comp / Unique-Dirty.
#   * n_bad_snp_resp_form -- a snoop that returns no data (SnpMakeInvalid) must
#     not be answered on DAT.
#
# Advisory: a self.logger.error() does NOT auto-fail pyUVM (verdicts come from
# raised exceptions), so violations both log ("COHERENCY VIOLATION" / "EXCLUSIVE
# VIOLATION", matched by the demoting negctl catcher) AND bump public counters
# the negative-control tests assert on. N_NODES fixed at 2 (two RN-F).
#
# The SV covergroups (cache-transition / occupancy / excl / downstream) are
# functional coverage that never affects a verdict. This port keeps the invariant
# + shadow logic faithful and ports cg_cache_transition for real (see
# get_cache_transition_coverage); the remaining covergroups stay lightweight.
#
################################################################################

from __future__ import annotations

from pyuvm import uvm_component

from vip_chi_types_pkg import (
  Resp, RespErr, ReqOpcode, RspOpcode, DatOpcode, SnpOpcode, CACHE_LINE_BYTES,
  snp_opcode_returns_no_data, snp_opcode_invalidates,
  snp_opcode_forbids_retaining_unique,
)
from vip_chi_analysis_imp import vip_chi_analysis_imp

_I = int

N_NODES = 2

# Exclusive-reservation clear cause (root cause; the first clear wins).
_EXCL_CLEAR_NONE = 0
_EXCL_CLEAR_STORE = 1
_EXCL_CLEAR_SNOOP = 2

_COHERENT_READ_OPS = {
  int(ReqOpcode.READ_SHARED), int(ReqOpcode.READ_CLEAN),
  int(ReqOpcode.READ_UNIQUE), int(ReqOpcode.MAKE_READ_UNIQUE),
}
_UNIQUE_READ_OPS = {int(ReqOpcode.READ_UNIQUE), int(ReqOpcode.MAKE_READ_UNIQUE)}
_UNIQUE_STATES = {int(Resp.UC), int(Resp.UD_PD)}
_DIRTY_STATES = {int(Resp.UD_PD), int(Resp.SD_PD)}

_SNP_TO_SHARED = {
  int(SnpOpcode.SHARED), int(SnpOpcode.CLEAN), int(SnpOpcode.CLEAN_SHARED),
  int(SnpOpcode.SHARED_FWD), int(SnpOpcode.CLEAN_FWD),
  int(SnpOpcode.NOT_SHARED_DIRTY_FWD),
}
# RSP opcodes that end a requester's claim on a cache line. See obs_rsp.
_HAZARD_RELEASE_RSP_OPS = {
  int(RspOpcode.COMP), int(RspOpcode.COMP_DBID_RESP),
  int(RspOpcode.COMP_PERSIST), int(RspOpcode.RETRY_ACK),
}

_SNP_TO_INVALID = {
  int(SnpOpcode.UNIQUE), int(SnpOpcode.CLEAN_INVALID), int(SnpOpcode.MAKE_INVALID),
  int(SnpOpcode.UNIQUE_FWD),
}

# --------------------------------------------------------------------------
# cg_cache_transition port (functional coverage of the state-changing
# snoop-induced from-state x snoop-opcode -> to-state cache transition).
# Faithful to the SV covergroup: three coverpoints plus their cross, reported
# the way SV get_coverage() averages a covergroup's items. Snapshot snoops such
# as SnpOnce still update the shadow state, but are not transition samples.
_CT_FROM_BINS = (int(Resp.SC), int(Resp.UC), int(Resp.UD_PD))          # cp_from (3)
_CT_SNP_BINS = (int(SnpOpcode.SHARED), int(SnpOpcode.UNIQUE),
                int(SnpOpcode.CLEAN_INVALID), int(SnpOpcode.MAKE_INVALID))  # cp_snp (4)
_CT_TO_BINS = (int(Resp.I), int(Resp.SC))                              # cp_to (2)
_CT_FROM_SET = frozenset(_CT_FROM_BINS)
_CT_SNP_SET = frozenset(_CT_SNP_BINS)
_CT_TO_SET = frozenset(_CT_TO_BINS)
# The 11 reachable cross tuples that survive the SV ignore_bins:
#   {UC,UD} x SnpShared -> SC, and {SC,UC,UD} x {SnpUnique,CleanInvalid,MakeInvalid} -> I.
_CT_CROSS_KEEPERS = frozenset(
  {(int(Resp.UC), int(SnpOpcode.SHARED), int(Resp.SC)),
   (int(Resp.UD_PD), int(SnpOpcode.SHARED), int(Resp.SC))}
  | {(f, s, int(Resp.I))
     for f in (int(Resp.SC), int(Resp.UC), int(Resp.UD_PD))
     for s in (int(SnpOpcode.UNIQUE), int(SnpOpcode.CLEAN_INVALID),
               int(SnpOpcode.MAKE_INVALID))})


class vip_chi_coherency_checker(uvm_component):

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.cfg = None
    self.enable = True
    # Same-line hazard rule (see hazard_claim). Set by the env from the
    # requester agent's cfg; set_cfg() carries the bus envelope, not the agent
    # cfg, so this cannot read the knob off self.cfg.
    self.hazard_check_enable = True
    # Analysis exports (built in build_phase).
    for m in ("snf_req_cc", "snf_dat_cc",
              "rnf0_req_cc", "rnf0_rsp_cc", "rnf0_dat_cc", "rnf0_snp_cc",
              "rnf1_req_cc", "rnf1_rsp_cc", "rnf1_dat_cc", "rnf1_snp_cc"):
      setattr(self, m, None)
    self._init_shadow()

  def _init_shadow(self):
    # Per-node open coherent reads + correlation maps (keyed by TxnID -> line).
    self.open_rd_line = [{} for _ in range(N_NODES)]
    self.open_rd_uniq = [{} for _ in range(N_NODES)]
    self.open_rd_excl = [{} for _ in range(N_NODES)]
    self.open_wb_line = [{} for _ in range(N_NODES)]
    self.open_sc_line = [{} for _ in range(N_NODES)]
    self.open_sc_excl = [{} for _ in range(N_NODES)]
    self.open_mu_line = [{} for _ in range(N_NODES)]
    # Per-line per-node held state (line -> [state per node], default Invalid).
    self.line_state = {}
    # Data-integrity shadow (line -> authoritative beats), from observed writes.
    self.line_data = {}
    # Snoop-data attribution (SnpRespData carries no address)...
    self.pending_snp_line = [0] * N_NODES
    self.pending_snp_valid = [False] * N_NODES
    # ...and the opcode that snoop carried, because the permitted RESPONSE FORM
    # is a property of the opcode and nothing else on the DAT flit records which
    # snoop it answers. See check_snp_resp_form.
    self.pending_snp_opcode = [0] * N_NODES
    # Downstream SN-F read correlation (downstream TxnID -> line).
    self.dn_rd_line = {}
    # Exclusive (LL/SC) monitor shadow (per node: line -> bool / clear-cause).
    self.excl_ll_valid = [{} for _ in range(N_NODES)]
    self.excl_clear_cause = [{} for _ in range(N_NODES)]
    # Same-line hazard shadow, per node. hazard_by_line maps a cache line to the
    # TxnID currently outstanding on it, hazard_by_txn the reverse, so a REQ can
    # be tested in O(1) and a completion can retire its line without a scan.
    self.hazard_by_line = [{} for _ in range(N_NODES)]
    self.hazard_by_txn = [{} for _ in range(N_NODES)]
    self.n_line_hazard = 0
    self.n_line_clear = 0
    self.n_multi_owner = 0
    self.n_completions = 0
    self.n_snoops = 0
    self.n_coherent_data_mismatch = 0
    self.n_excl_violation = 0
    self.n_bad_make_unique = 0
    self.n_bad_snp_resp_form = 0
    # Non-vacuity evidence for check_snp_resp_form. The rule can only fire when a
    # snoop that returns no data reaches a snoopee holding the line Dirty: a
    # clean holder answers on RSP whatever the opcode says, so a run without that
    # combination proves nothing about the rule. Counted from the observed snoop
    # and the shadow state, so a test can assert the provoking condition actually
    # occurred instead of reading a zero violation count out of a run that never
    # set it up -- which is the shape of the bug this check exists to catch.
    self.n_snp_no_data_on_dirty = 0
    self.n_bad_snp_resp_state = 0
    # How many snoop responses check_snp_resp_state judged. The rule only runs
    # where a response is correlated to its snoop, so this is the honest measure
    # of whether it saw anything -- and it is the first count of DATA-LESS
    # SnpResp this checker has taken: before D5 it observed SnpRespData on DAT
    # and was blind to the RSP half of the response space entirely.
    self.n_snp_resp_judged = 0
    # cg_snp_resp_legality hit set: (snp_opcode, resp_state, with_data).
    self._srl_hit = set()
    # cg_cache_transition hit sets (one per covergroup item; see accessor).
    self._ct_from_hit = set()
    self._ct_snp_hit = set()
    self._ct_to_hit = set()
    self._ct_cross_hit = set()

  def set_cfg(self, cfg):
    self.cfg = cfg

  def build_phase(self):
    self.snf_req_cc = vip_chi_analysis_imp("snf_req_cc", self, self.obs_snf_req)
    self.snf_dat_cc = vip_chi_analysis_imp("snf_dat_cc", self, self.obs_snf_dat)
    self.rnf0_req_cc = vip_chi_analysis_imp("rnf0_req_cc", self, lambda it: self.obs_req(0, it))
    self.rnf0_rsp_cc = vip_chi_analysis_imp("rnf0_rsp_cc", self, lambda it: self.obs_rsp(0, it))
    self.rnf0_dat_cc = vip_chi_analysis_imp("rnf0_dat_cc", self, lambda it: self.obs_dat(0, it))
    self.rnf0_snp_cc = vip_chi_analysis_imp("rnf0_snp_cc", self, lambda it: self.obs_snp(0, it))
    self.rnf1_req_cc = vip_chi_analysis_imp("rnf1_req_cc", self, lambda it: self.obs_req(1, it))
    self.rnf1_rsp_cc = vip_chi_analysis_imp("rnf1_rsp_cc", self, lambda it: self.obs_rsp(1, it))
    self.rnf1_dat_cc = vip_chi_analysis_imp("rnf1_dat_cc", self, lambda it: self.obs_dat(1, it))
    self.rnf1_snp_cc = vip_chi_analysis_imp("rnf1_snp_cc", self, lambda it: self.obs_snp(1, it))

  # ==========================================================================
  # Shadow helpers.
  # ==========================================================================
  def line_of(self, addr):
    return _I(addr) & ~(CACHE_LINE_BYTES - 1)

  def is_coherent_read(self, item):
    op = _I(item.opcode)
    is_unique = op in _UNIQUE_READ_OPS
    return (op in _COHERENT_READ_OPS), is_unique

  def state_is_unique(self, s):
    return _I(s) in _UNIQUE_STATES

  def state_is_dirty(self, s):
    return _I(s) in _DIRTY_STATES

  def _entry(self, line):
    return self.line_state.get(line, [int(Resp.I)] * N_NODES)

  def set_node_state(self, line, node, st):
    e = list(self._entry(line))
    e[node] = _I(st)
    self.line_state[line] = e

  def check_multi_owner(self, line):
    if line not in self.line_state:
      return
    e = self.line_state[line]
    cnt = sum(1 for k in range(N_NODES) if self.state_is_unique(e[k]))
    if cnt > 1:
      self.n_multi_owner += 1
      self.logger.error(
        f"COHERENCY VIOLATION: line 0x{line:x} has {cnt} Unique owners simultaneously")

  def sharer_count(self, line):
    if line not in self.line_state:
      return 0
    e = self.line_state[line]
    return sum(1 for k in range(N_NODES) if e[k] != int(Resp.I))

  def snoop_result(self, snp_opcode, current):
    op = _I(snp_opcode)
    if op in _SNP_TO_SHARED:
      return int(Resp.I) if _I(current) == int(Resp.I) else int(Resp.SC)
    if op in _SNP_TO_INVALID:
      return int(Resp.I)
    return _I(current)  # SnpOnce / SnpOnceFwd (snapshot) and anything else

  @staticmethod
  def snoop_samples_cache_transition(snp_opcode):
    return _I(snp_opcode) in _CT_SNP_SET

  def _sample_cache_transition(self, cur, snp_opcode, nxt):
    # Mirror the SV covergroup .sample() on state-changing snoops: each coverpoint
    # records independently, and the cross records only the reachable
    # (from, snp, to) tuples.
    f, s, t = _I(cur), _I(snp_opcode), _I(nxt)
    if f in _CT_FROM_SET:
      self._ct_from_hit.add(f)
    if s in _CT_SNP_SET:
      self._ct_snp_hit.add(s)
    if t in _CT_TO_SET:
      self._ct_to_hit.add(t)
    if (f, s, t) in _CT_CROSS_KEEPERS:
      self._ct_cross_hit.add((f, s, t))

  def record_line_data(self, line, item):
    self.line_data[line] = [_I(b) for b in item.data]

  def check_line_data(self, line, item):
    if line not in self.line_data:
      return
    exp = self.line_data[line]
    if len(item.data) != len(exp):
      self.n_coherent_data_mismatch += 1
      self.logger.error(
        f"COHERENCY VIOLATION: line 0x{line:x} read returned {len(item.data)} "
        f"beats, expected {len(exp)}")
      return
    for i in range(len(item.data)):
      if _I(item.data[i]) != exp[i]:
        self.n_coherent_data_mismatch += 1
        self.logger.error(
          f"COHERENCY VIOLATION: line 0x{line:x} beat {i} read "
          f"0x{_I(item.data[i]):x} != authoritative 0x{exp[i]:x}")
        return

  # ==========================================================================
  # Same-line hazard shadow.
  #
  # The invariant: a requester must not have two requests outstanding to the
  # same cache line at once. The completer resolves a line's transactions in
  # the order it chooses and its snoops carry no requester-side sequence, so a
  # requester that overlaps two requests on one line has no way to say which
  # result belongs to which -- and neither has anything watching the link.
  #
  # Scoped per NODE on purpose. Two different requesters holding the same line
  # outstanding is not a hazard, it is the ordinary contention every coherent
  # test in this bench creates deliberately; the home exists to arbitrate it.
  #
  # A line is claimed at the REQ and released at the completion response. The
  # release is the response rather than the last data beat because the response
  # is what every request kind has -- reads, writes, CMOs and the data-less
  # acquires alike -- and a shadow that only understood the kinds with a data
  # phase would leak entries and then blame the next request to that line.
  # ==========================================================================
  def hazard_claim(self, node, line, txn_id, opcode):
    if not self.hazard_check_enable:
      return
    prior = self.hazard_by_line[node].get(line)
    if prior is not None and prior != txn_id:
      self.n_line_hazard += 1
      self.logger.error(
        f"COHERENCY VIOLATION: node {node} issued txn 0x{txn_id:x} "
        f"(opcode=0x{_I(opcode):x}) to line 0x{line:x} while its own txn "
        f"0x{prior:x} to that line was still outstanding")
      return
    if prior is not None:
      # Same TxnID on the same line: a RetryAck'd request being re-issued, not a
      # second request. Re-claiming it would report the requester for obeying the
      # retry protocol.
      return
    self.hazard_by_line[node][line] = txn_id
    self.hazard_by_txn[node][txn_id] = line

  def hazard_release(self, node, txn_id):
    if not self.hazard_check_enable:
      return
    line = self.hazard_by_txn[node].pop(txn_id, None)
    if line is None:
      return
    if self.hazard_by_line[node].get(line) == txn_id:
      del self.hazard_by_line[node][line]
    # Count the clean open/close pair: without it a log cannot distinguish a run
    # in which the rule held from one in which it never evaluated.
    self.n_line_clear += 1

  def clear_excl_all(self, line):
    for k in range(N_NODES):
      if self.excl_ll_valid[k].get(line):
        self.excl_clear_cause[k][line] = _EXCL_CLEAR_STORE
        self.excl_ll_valid[k][line] = False

  def clear_excl_others(self, line, keep_node):
    for k in range(N_NODES):
      if k == keep_node:
        continue
      if self.excl_ll_valid[k].get(line):
        self.excl_clear_cause[k][line] = _EXCL_CLEAR_STORE
        self.excl_ll_valid[k][line] = False

  # ==========================================================================
  # Stream observers.
  # ==========================================================================
  def obs_req(self, node, item):
    if not self.enable or item.is_snoop:
      return
    line = self.line_of(item.addr)
    wop = _I(item.opcode)
    # Every request kind claims the line, including the ones the ownership
    # shadow below does not model: the hazard rule is about a requester
    # overlapping itself, which does not depend on what the request does.
    self.hazard_claim(node, line, _I(item.txn_id), wop)
    is_read, _uniq = self.is_coherent_read(item)
    if is_read:
      tid = _I(item.txn_id)
      self.open_rd_line[node][tid] = line
      self.open_rd_uniq[node][tid] = _uniq
      self.open_rd_excl[node][tid] = bool(_I(item.excl))
    elif wop in (int(ReqOpcode.WRITE_BACK_FULL), int(ReqOpcode.WRITE_CLEAN_FULL)):
      self.open_wb_line[node][_I(item.txn_id)] = line
      self.clear_excl_all(line)
    elif wop == int(ReqOpcode.CLEAN_UNIQUE):
      tid = _I(item.txn_id)
      self.open_sc_line[node][tid] = line
      self.open_sc_excl[node][tid] = bool(_I(item.excl))
      if _I(item.excl):
        self.clear_excl_others(line, node)
      else:
        self.clear_excl_all(line)
    elif wop == int(ReqOpcode.MAKE_UNIQUE):
      self.open_mu_line[node][_I(item.txn_id)] = line
      self.clear_excl_all(line)
    elif wop in (int(ReqOpcode.WRITE_UNIQUE_FULL), int(ReqOpcode.WRITE_UNIQUE_PTL),
                 int(ReqOpcode.CLEAN_INVALID), int(ReqOpcode.MAKE_INVALID)):
      self.clear_excl_all(line)

  def obs_dat(self, node, item):
    if not self.enable:
      return
    op = _I(item.dat_opcode)
    tid = _I(item.txn_id)

    # A read's CompData is its completion, so it releases the line.
    if op == int(DatOpcode.COMP_DATA):
      self.hazard_release(node, tid)

    if op == int(DatOpcode.COPY_BACK_WR_DATA):
      if tid in self.open_wb_line[node]:
        self.record_line_data(self.open_wb_line[node][tid], item)
        del self.open_wb_line[node][tid]
      return
    if op in (int(DatOpcode.SNP_RESP_DATA), int(DatOpcode.SNP_RESP_DATA_FWDED)):
      if self.pending_snp_valid[node]:
        # The response FORM is a property of the snoop opcode, and this is the
        # only place the two are correlated: nothing on a DAT flit says which
        # snoop it answers, so a rule written on encodings alone cannot see
        # this. SnpRespData_I_PD is a legal row of Table 4-11 -- what is
        # prohibited is sending it IN ANSWER TO a snoop that returns no data.
        self.check_snp_resp_form(node, self.pending_snp_line[node], op)
        self.record_line_data(self.pending_snp_line[node], item)
        self.pending_snp_valid[node] = False
      return
    if op != int(DatOpcode.COMP_DATA):
      return
    if tid not in self.open_rd_line[node]:
      return

    line = self.open_rd_line[node][tid]
    granted = _I(item.dat_resp[-1]) if item.dat_resp else int(Resp.I)
    self.set_node_state(line, node, granted)

    ll_excl = self.open_rd_excl[node].get(tid, False)
    if ll_excl:
      ll_okay = bool(item.dat_resp_err) and \
          _I(item.dat_resp_err[-1]) == int(RespErr.EXOKAY)
      if ll_okay:
        self.excl_ll_valid[node][line] = True
        self.excl_clear_cause[node][line] = _EXCL_CLEAR_NONE

    self.open_rd_line[node].pop(tid, None)
    self.open_rd_uniq[node].pop(tid, None)
    self.open_rd_excl[node].pop(tid, None)
    self.n_completions += 1
    self.check_multi_owner(line)
    self.check_line_data(line, item)

  # A data-bearing snoop response answering a snoop that must not return data.
  # IHI 0050 Chapter 4 defines SnpMakeInvalid by exactly this property -- the
  # snoopee invalidates and DISCARDS its Dirty copy -- and Tables 4-9 / 4-11
  # list no SnpRespData form among its permitted responses.
  #
  # Judged here rather than in an SVA bind because it needs the request and the
  # response paired: the snoop is on SNP and the offending flit is on DAT, with
  # no address and no field tying it back. Derived from observed traffic only,
  # so it catches a DUT snoopee as readily as this VIP's own.
  # Catalogue rule D5: the state a snoop response reports must be one Chapter 4
  # permits for that snoop opcode. check_snp_resp_form below is the CHANNEL half
  # of the pairing; this is the Resp-encoding half.
  #
  # Two rules, both read off Tables 4-9 / 4-11 and both restricted to what this
  # home originates:
  #
  #   * an invalidating snoop must leave the snoopee Invalid. Otherwise the
  #     requester about to be granted Unique is not the only owner, and the
  #     single-writer invariant breaks without any flit looking wrong.
  #   * a shared snoop must not leave the snoopee Unique, for the same reason one
  #     step earlier: the grant that follows creates a second holder.
  #
  # It also carries the coverage cross. Chapter 4 states the snoop rules PER
  # OPCODE, so a model without the opcode in the cross cannot express them; the
  # opcode was crossed only with a direction and the response state only with
  # pass-dirty, in two covergroups at two unrelated call sites, so the pairing was
  # structurally unreachable rather than merely uncovered.
  def check_snp_resp_state(self, node, line, state, with_data):
    op = _I(self.pending_snp_opcode[node])
    state = _I(state)

    # Sampled unconditionally, legal pairings included: a cross that only ever
    # recorded its violations would say nothing about what was exercised.
    self._srl_hit.add((op, state, bool(with_data)))

    if snp_opcode_invalidates(op) and state != int(Resp.I):
      self.n_bad_snp_resp_state += 1
      self.logger.error(
        f"COHERENCY VIOLATION: node {node} answered invalidating snoop opcode "
        f"0x{op:x} on line 0x{line:x} reporting state 0x{state:x}, but every "
        f"response Chapter 4 permits to it is Invalid")
    elif (snp_opcode_forbids_retaining_unique(op)
          and state in (int(Resp.UC), int(Resp.UD_PD))):
      self.n_bad_snp_resp_state += 1
      self.logger.error(
        f"COHERENCY VIOLATION: node {node} answered shared snoop opcode "
        f"0x{op:x} on line 0x{line:x} still holding Unique (state 0x{state:x}); "
        f"the grant that follows would create a second owner")

    self.n_snp_resp_judged += 1

  def check_snp_resp_form(self, node, line, op):
    if not snp_opcode_returns_no_data(self.pending_snp_opcode[node]):
      return
    self.n_bad_snp_resp_form += 1
    self.logger.error(
      f"COHERENCY VIOLATION: node {node} answered snoop opcode "
      f"0x{_I(self.pending_snp_opcode[node]):x} on line 0x{line:x} with DAT "
      f"opcode 0x{op:x}; that snoop returns no data and discards its dirty copy")

  def obs_snp(self, node, item):
    if not self.enable or not item.is_snoop:
      return
    line = self.line_of(item.snp_addr)
    cur = self._entry(line)[node]
    nxt = self.snoop_result(item.snp_opcode, cur)
    if self.snoop_samples_cache_transition(item.snp_opcode):
      self._sample_cache_transition(cur, item.snp_opcode, nxt)
    self.set_node_state(line, node, nxt)
    if nxt == int(Resp.I):
      if self.excl_ll_valid[node].get(line):
        self.excl_clear_cause[node][line] = _EXCL_CLEAR_SNOOP
        self.excl_ll_valid[node][line] = False
    if snp_opcode_returns_no_data(item.snp_opcode) and self.state_is_dirty(cur):
      self.n_snp_no_data_on_dirty += 1
    self.pending_snp_line[node] = line
    self.pending_snp_valid[node] = True
    self.pending_snp_opcode[node] = _I(item.snp_opcode)
    self.n_snoops += 1

  def obs_rsp(self, node, item):
    if not self.enable:
      return
    tid = _I(item.txn_id)

    # A data-less snoop response. This checker watched SnpRespData on DAT and
    # nothing on RSP, so until D5 it could not see the response form a clean
    # snoopee actually sends -- which is most of them. Handled first and returned
    # from: a SnpResp carries the SNOOP's TxnID, so letting it fall through to the
    # completion correlation below would look it up against request tables it was
    # never entered in.
    if _I(item.rsp_opcode) in (int(RspOpcode.SNP_RESP),
                               int(RspOpcode.SNP_RESP_FWDED)):
      if self.pending_snp_valid[node]:
        self.check_snp_resp_state(node, self.pending_snp_line[node],
                                  item.rsp_resp, False)
        self.pending_snp_valid[node] = False
      return

    # Release the line on a genuine completion. DBIDResp and ReadReceipt are
    # deliberately NOT in this set: they grant a buffer and confirm ordering
    # respectively, and the transaction is still live after either. A RetryAck is
    # in it because the completer refused the request outright -- it holds no
    # line, and the re-issue claims one again.
    if _I(item.rsp_opcode) in _HAZARD_RELEASE_RSP_OPS:
      self.hazard_release(node, tid)
    # MakeUnique completion (RSP-only Comp): mark the requester Unique owner and
    # run the single-writer check.
    if tid in self.open_mu_line[node]:
      line = self.open_mu_line[node][tid]
      if (_I(item.rsp_opcode) != int(RspOpcode.COMP) or
          _I(item.rsp_resp) != int(Resp.UD_PD)):
        self.n_bad_make_unique += 1
        self.logger.error(
          f"COHERENCY VIOLATION: MakeUnique on line 0x{line:x} (node {node}) "
          f"completed opcode=0x{_I(item.rsp_opcode):x} resp=0x{_I(item.rsp_resp):x}, "
          f"expected Comp / Unique-Dirty")
      self.set_node_state(line, node, _I(item.rsp_resp))
      self.n_completions += 1
      self.check_multi_owner(line)
      del self.open_mu_line[node][tid]
      return

    if tid not in self.open_sc_line[node]:
      return
    line = self.open_sc_line[node][tid]
    success = _I(item.rsp_resp_err) == int(RespErr.EXOKAY)

    if success and not self.excl_ll_valid[node].get(line):
      self.n_excl_violation += 1
      self.logger.error(
        f"EXCLUSIVE VIOLATION: node {node} SC on line 0x{line:x} reported "
        f"ExclOkay with no continuously-valid monitor (no matching uninterrupted "
        f"exclusive load)")

    if line in self.excl_ll_valid[node]:
      self.excl_ll_valid[node][line] = False
    self.open_sc_line[node].pop(tid, None)
    self.open_sc_excl[node].pop(tid, None)

  # Downstream SN-F observers.
  def obs_snf_req(self, item):
    if not self.enable:
      return
    if _I(item.opcode) == int(ReqOpcode.READ_NO_SNP):
      self.dn_rd_line[_I(item.txn_id)] = self.line_of(item.addr)

  def obs_snf_dat(self, item):
    if not self.enable:
      return
    tid = _I(item.txn_id)
    if _I(item.dat_opcode) == int(DatOpcode.COMP_DATA) and tid in self.dn_rd_line:
      self.record_line_data(self.dn_rd_line[tid], item)
      del self.dn_rd_line[tid]

  # ==========================================================================
  # Accessors for tests / negative control.
  # ==========================================================================
  def get_multi_owner_count(self):
    return self.n_multi_owner

  def get_completion_count(self):
    return self.n_completions

  def get_snoop_count(self):
    return self.n_snoops

  def get_coherent_data_mismatch_count(self):
    return self.n_coherent_data_mismatch

  def get_excl_violation_count(self):
    return self.n_excl_violation

  def get_bad_make_unique_count(self):
    return self.n_bad_make_unique

  def get_bad_snp_resp_form_count(self):
    return self.n_bad_snp_resp_form

  def get_snp_no_data_on_dirty_count(self):
    return self.n_snp_no_data_on_dirty

  def get_bad_snp_resp_state_count(self):
    return self.n_bad_snp_resp_state

  def get_snp_resp_judged_count(self):
    return self.n_snp_resp_judged

  def get_snp_resp_legality_tuples(self):
    """The distinct (snoop opcode, resp state, with-data) triples observed.

    The pyUVM port has no covergroup object, so the SV cross is kept here as the
    hit set it would have filled. A test asserts on its size rather than on a
    percentage, because the denominator -- which pairings are reachable -- is a
    property of the stimulus and would have to be maintained by hand.
    """
    return set(self._srl_hit)

  def get_line_hazard_count(self):
    return self.n_line_hazard

  # Clean claim/release pairs. A test asserts on this to show the hazard rule
  # actually evaluated, rather than reading a zero violation count from a run
  # where no request ever claimed a line.
  def get_line_clear_count(self):
    return self.n_line_clear

  def get_cache_transition_coverage(self):
    # Functional coverage of the (from-state x snoop-opcode -> to-state) cache
    # transition, reported the way SV covergroup.get_coverage() averages a group's
    # items: the mean of the four coverpoint/cross coverages (cp_from, cp_snp,
    # cp_to, cx_from_snp_to). Observational only -- no invariant depends on it.
    from_cov = len(self._ct_from_hit) / len(_CT_FROM_BINS)
    snp_cov = len(self._ct_snp_hit) / len(_CT_SNP_BINS)
    to_cov = len(self._ct_to_hit) / len(_CT_TO_BINS)
    cross_cov = len(self._ct_cross_hit) / len(_CT_CROSS_KEEPERS)
    return 100.0 * (from_cov + snp_cov + to_cov + cross_cov) / 4.0

  def total_violations(self):
    return (self.n_multi_owner + self.n_coherent_data_mismatch +
            self.n_excl_violation + self.n_bad_make_unique +
            self.n_bad_snp_resp_form + self.n_bad_snp_resp_state +
            self.n_line_hazard)

  def handle_reset(self):
    self._init_shadow()

  def report_phase(self):
    self.logger.info(
      f"COHERENCY CHECKER SUMMARY: completions={self.n_completions} "
      f"snoops={self.n_snoops} multi_owner_violations={self.n_multi_owner} "
      f"data_mismatches={self.n_coherent_data_mismatch} "
      f"excl_violations={self.n_excl_violation} "
      f"bad_make_unique={self.n_bad_make_unique}")
    # Its own line, short enough never to be wrapped by a report server: the
    # tally has to stay greppable across a whole regression for the check to be
    # provably non-vacuous. Same reason for the snoop-response-form line below.
    self.logger.info(
      f"COHERENCY SNP RESP FORM SUMMARY: "
      f"no_data_snoops_on_dirty={self.n_snp_no_data_on_dirty} "
      f"bad_snp_resp_form={self.n_bad_snp_resp_form}")
    self.logger.info(
      f"COHERENCY SNP RESP STATE SUMMARY: "
      f"snp_resp_judged={self.n_snp_resp_judged} "
      f"bad_snp_resp_state={self.n_bad_snp_resp_state}")
    self.logger.info(
      f"COHERENCY HAZARD SUMMARY: line_hazards={self.n_line_hazard} "
      f"line_claims_cleared={self.n_line_clear}")
