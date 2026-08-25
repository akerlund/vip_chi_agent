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
#   * n_bad_make_unique -- MakeUnique must complete on a data-less Comp.
#   * n_bad_dataless_resp -- and that Comp must carry the Resp encoding the
#     data-less completion table permits for the request (Comp_UC for MakeUnique).
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
  snp_resp_state_gains_permission,
  Resp, RespErr, ReqOpcode, RspOpcode, DatOpcode, SnpOpcode, CACHE_LINE_BYTES,
  snp_opcode_returns_no_data, snp_opcode_invalidates,
  snp_opcode_forbids_retaining_unique, snp_opcode_is_forwarding,
  req_final_state, state_holds_dirty,
  snoop_permitted_for_req, req_generates_snoop,
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

# The completions a CompAck may acknowledge (section 2.8.3): the read's
# CompData is handled in obs_dat, and these are the data-less forms. RetryAck is
# deliberately absent -- see open_comp_ack_window's caller.
_COMP_ACK_COMPLETION_RSP_OPS = frozenset({
  int(RspOpcode.COMP), int(RspOpcode.COMP_DBID_RESP),
  int(RspOpcode.COMP_PERSIST),
})

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
# SnpClean joined cp_snp with Table 4-5: it is what a ReadClean is now snooped
# with, and it downgrades a Unique holder exactly as SnpShared does, so it is a
# transition in its own right and not a synonym.
_CT_SNP_BINS = (int(SnpOpcode.SHARED), int(SnpOpcode.CLEAN), int(SnpOpcode.UNIQUE),
                int(SnpOpcode.CLEAN_INVALID), int(SnpOpcode.MAKE_INVALID))  # cp_snp (5)
_CT_TO_BINS = (int(Resp.I), int(Resp.SC))                              # cp_to (2)
_CT_FROM_SET = frozenset(_CT_FROM_BINS)
_CT_SNP_SET = frozenset(_CT_SNP_BINS)
_CT_TO_SET = frozenset(_CT_TO_BINS)
# The 13 reachable cross tuples that survive the SV ignore_bins:
#   {UC,UD} x {SnpShared,SnpClean} -> SC, and
#   {SC,UC,UD} x {SnpUnique,CleanInvalid,MakeInvalid} -> I.
_CT_CROSS_KEEPERS = frozenset(
  {(f, s, int(Resp.SC))
   for f in (int(Resp.UC), int(Resp.UD_PD))
   for s in (int(SnpOpcode.SHARED), int(SnpOpcode.CLEAN))}
  | {(f, s, int(Resp.I))
     for f in (int(Resp.SC), int(Resp.UC), int(Resp.UD_PD))
     for s in (int(SnpOpcode.UNIQUE), int(SnpOpcode.CLEAN_INVALID),
               int(SnpOpcode.MAKE_INVALID))})


# --------------------------------------------------------------------------
# cg_req_cache_transition port (functional coverage of the requester-side
# held-state x request x granted-state -> final-state transition, IHI 0050 E
# Table 4-14 / D Table 4-12). Faithful to the SV covergroup: four coverpoints
# plus the three-way cross, reported the way SV get_coverage() averages a
# covergroup's items.
#
# The interesting axis is cp_from and it is the one that did not exist before:
# every requester transition in this regression began at Invalid, so "final =
# granted Resp" and "final = join(held, granted)" agreed on all of the stimulus
# and a coverage report with no initial-state axis could not show the hole.
_RT_FROM_BINS = (int(Resp.I), int(Resp.SC), int(Resp.UC),
                 int(Resp.SD_PD), int(Resp.UD_PD))                     # cp_from (5)
_RT_REQ_BINS = (int(ReqOpcode.READ_SHARED), int(ReqOpcode.READ_CLEAN),
                int(ReqOpcode.READ_UNIQUE), int(ReqOpcode.MAKE_READ_UNIQUE),
                int(ReqOpcode.MAKE_UNIQUE))                            # cp_req (5)
_RT_GRANTED_BINS = (int(Resp.SC), int(Resp.UC),
                    int(Resp.SD_PD), int(Resp.UD_PD))                  # cp_granted (4)
_RT_TO_BINS = (int(Resp.SC), int(Resp.UC),
               int(Resp.SD_PD), int(Resp.UD_PD))                       # cp_to (4)
_RT_FROM_SET = frozenset(_RT_FROM_BINS)
_RT_REQ_SET = frozenset(_RT_REQ_BINS)
_RT_GRANTED_SET = frozenset(_RT_GRANTED_BINS)
_RT_TO_SET = frozenset(_RT_TO_BINS)
# The SV cross carries no ignore_bins -- unlike the snoop axis, the reachable
# subset here is a property of the home's response policy rather than of the
# protocol, so pruning it by hand would bake this VIP's HN-F into the denominator.
_RT_CROSS_BIN_COUNT = len(_RT_FROM_BINS) * len(_RT_REQ_BINS) * len(_RT_GRANTED_BINS)


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
    # The REQ opcode the completion belongs to. The Requester's final cache state
    # is a function of the request as well as the granted Resp (IHI 0050 E Table
    # 4-14), so the correlation the checker already keeps for the line has to
    # carry the opcode too -- nothing on the CompData flit says which read it
    # completes.
    self.open_rd_op = [{} for _ in range(N_NODES)]
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
    # ...and the state the node held WHEN THE SNOOP ARRIVED. The shadow is
    # overwritten with the predicted result the moment the snoop is seen, so by
    # the time the response arrives the from-state is gone -- and the from-state
    # is what bounds which states the response may legally report (see
    # snp_resp_state_gains_permission).
    self.pending_snp_from = [int(Resp.I)] * N_NODES
    # The snoop's DoNotGoToSD bit, kept for the same reason the from-state is:
    # the rule it feeds is about the RESPONSE, and by then the flit is gone.
    self.pending_snp_no_sd = [False] * N_NODES
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
    # Catalogue rule D8, the request->snoop correspondence. To judge a snoop
    # against IHI 0050 E Table 4-5 / D Table 4-3 the checker has to know which
    # request caused it, and nothing on the SNP flit says so: the address is the
    # only field shared with the request in every case. So the correlation is by
    # line. Kept separately from the hazard shadow above rather than folded into
    # it, because that one is switched off by a config knob for the hazard
    # negative control and this rule must keep working while it is.
    self.req_op_by_line = [{} for _ in range(N_NODES)]
    self.req_line_by_txn = [{} for _ in range(N_NODES)]
    # The same correlation, carrying the two fields a forwarding snoop has to
    # name its requester by. The opcode above answers "may this snoop be sent for
    # that request"; these answer "is it addressed to it". Kept beside the opcode
    # rather than in a table of their own so one release path retires all three
    # and they cannot fall out of step.
    self.req_src_by_line = [{} for _ in range(N_NODES)]
    self.req_txn_by_line = [{} for _ in range(N_NODES)]
    # n_snp_req_judged is how many snoops were correlated to exactly one
    # outstanding request and therefore had a Table 4-5 row to be judged against;
    # n_snp_req_mismatch is how many of those carried an opcode that row does not
    # permit. n_snp_req_uncorrelated is the honest denominator alongside them and
    # is NOT a violation: the section that gives Table 4-5 states that "it is
    # permitted for the interconnect to generate a snoop request spontaneously
    # without a corresponding request from an RN". It is counted so that a run in
    # which the correlation silently stopped working reads as "judged 0,
    # uncorrelated 40" instead of as a clean pass.
    self.n_snp_req_judged = 0
    self.n_snp_req_mismatch = 0
    self.n_snp_req_uncorrelated = 0
    # The positive half of the FwdNID/FwdTxnID rule. The SNP channel checker
    # judges the negative half -- both fields zero on a snoop that has no
    # requester to name -- from the flit alone, which is all a link-layer bind
    # can see. Section 2.5 also states the other direction: FwdNID "must be the
    # Node ID of the original Requester" and FwdTxnID "must be the TxnID of the
    # original Request". Neither can be judged without knowing which request
    # caused the snoop, so it is judged here, on the same correlation rule D8
    # resolves and at the same moment.
    #
    # n_snp_fwd_judged counts forwarding snoops that had exactly one candidate
    # cause and were therefore addressable; n_snp_fwd_mismatch how many of those
    # named a different transaction than the one they were sent for. A forwarding
    # snoop whose cause is ambiguous is counted by n_snp_req_uncorrelated with
    # the rest, because the two rules decline for the same reason.
    self.n_snp_fwd_judged = 0
    self.n_snp_fwd_mismatch = 0
    # Catalogue rule D9 -- the CompAck ordering window. One slot per node is
    # enough because an RN-F runs its coherent transactions serially, so it never
    # has two acknowledgements outstanding at once.
    #
    # req_eca_line records, at the request, which line a CompAck will eventually
    # be owed for. The window itself does NOT open there: the snoops this very
    # request causes go out before its completion, and a window opened at the
    # request would flag exactly the snoops the protocol requires. It opens at
    # the completion, which is where section 2.8.3 puts it.
    self.req_eca_line = [{} for _ in range(N_NODES)]
    self.eca_open = [False] * N_NODES
    self.eca_line = [0] * N_NODES
    self.eca_txn = [0] * N_NODES
    self.n_eca_windows = 0
    self.n_eca_window_snoops = 0
    self.n_eca_windows_unclosed = 0
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
    self.n_bad_snp_sd_under_no_sd = 0
    # How many snoop responses check_snp_resp_state judged. The rule only runs
    # where a response is correlated to its snoop, so this is the honest measure
    # of whether it saw anything -- and it is the first count of DATA-LESS
    # SnpResp this checker has taken: before D5 it observed SnpRespData on DAT
    # and was blind to the RSP half of the response space entirely.
    self.n_snp_resp_judged = 0
    # Catalogue rule D6: responses reporting a state the snoopee could not have
    # reached from what it held.
    self.n_snp_resp_gains_permission = 0
    # Non-vacuity for the ADOPTION, which is the point of the change: how many
    # responses wrote their reported state into the shadow, and how many of those
    # disagreed with the state derived from the opcode. On this VIP the second is
    # expected to be 0 -- its own RN-F implements exactly the mapping
    # snoop_result() encodes -- so the count is what makes that an OBSERVATION
    # rather than the assumption it replaces. Against a DUT it is the first
    # number to read.
    self.n_snp_resp_adopted = 0
    self.n_snp_resp_state_differs = 0
    # The requester axis of the same question. n_req_final_judged is how many
    # completions the Table 4-14 rule had to decide; n_req_final_retained is how
    # many of those ended in a state the granted Resp alone would NOT have given,
    # which is precisely the count that separates the rule from the shortcut it
    # replaces. It is 0 for any stimulus whose requester is Invalid when it
    # issues -- which was every transition in this regression before the sweep
    # primed the requesting node -- so it is the non-vacuity measure for this
    # rule, not a statistic.
    self.n_req_final_judged = 0
    self.n_req_final_retained = 0
    # Completions whose Resp encoding the data-less completion table does not
    # permit for that request (currently MakeUnique, Table 4-19 / D Table 4-13).
    self.n_bad_dataless_resp = 0
    # Catalogue rule D7: a Dirty snoopee that answered without data and without
    # keeping the dirty. The dual of n_bad_snp_resp_form, which reads the other
    # direction.
    self.n_snp_dirty_lost = 0
    # cg_snp_resp_legality hit set: (snp_opcode, resp_state, with_data).
    self._srl_hit = set()
    # cg_req_snp_pairing hit set: (cause_req_opcode, snp_opcode). The SV port
    # carries this as a covergroup cross; this port has no covergroup object, so
    # the surface is the set of pairs actually reached.
    self._rsp_hit = set()
    # cg_cache_transition hit sets (one per covergroup item; see accessor).
    self._ct_from_hit = set()
    self._ct_snp_hit = set()
    self._ct_to_hit = set()
    self._ct_cross_hit = set()
    # cg_req_cache_transition hit sets (one per covergroup item; see accessor).
    self._rt_from_hit = set()
    self._rt_req_hit = set()
    self._rt_granted_hit = set()
    self._rt_to_hit = set()
    self._rt_cross_hit = set()

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

  def _sample_req_transition(self, held, opcode, granted, final_state):
    # Mirror the SV covergroup .sample(): each coverpoint records independently,
    # and the cross records every (from, req, granted) tuple -- no ignore_bins on
    # this axis, see _RT_CROSS_BIN_COUNT.
    f, q, g, t = _I(held), _I(opcode), _I(granted), _I(final_state)
    if f in _RT_FROM_SET:
      self._rt_from_hit.add(f)
    if q in _RT_REQ_SET:
      self._rt_req_hit.add(q)
    if g in _RT_GRANTED_SET:
      self._rt_granted_hit.add(g)
    if t in _RT_TO_SET:
      self._rt_to_hit.add(t)
    if f in _RT_FROM_SET and q in _RT_REQ_SET and g in _RT_GRANTED_SET:
      self._rt_cross_hit.add((f, q, g))

  def resolve_req_final_state(self, node, line, opcode, granted):
    """Resolve the Requester's cache state when its own request completes.

    The dual of check_snp_resp_state, on the other axis. A snoop asks a node to
    GIVE UP permissions and the checker bounds the answer from above; a
    completion GRANTS permissions and the checker must not let the grant revoke
    what the node already held. IHI 0050 E Tables 4-14, 4-17, 4-18 and 4-19; D
    Tables 4-12 and 4-13.

    The held state is read from the shadow HERE, at the completion, not stashed
    at the request. Tables 4-17 and 4-18 index the final state on the state "at
    time of response" precisely because a snoop can take the line away while the
    request is outstanding, and obs_snp has already written that loss into the
    shadow by the time this runs.
    """
    held = self._entry(line)[node]
    final_state = req_final_state(opcode, held, granted)
    # What this same completion would have produced for a Requester holding
    # nothing. Comparing against THAT rather than against the granted Resp is
    # what isolates the held-state contribution: MakeUnique ends UD whatever it
    # held, so measuring "final != granted" would count every MakeUnique as
    # evidence for a rule it does not exercise.
    from_invalid = req_final_state(opcode, int(Resp.I), granted)

    self.n_req_final_judged += 1
    if final_state != from_invalid:
      # The held state changed the answer. Every such completion is one the
      # pre-3.2 shadow got wrong, so this count is the rule's non-vacuity
      # evidence: zero means the stimulus never presented a non-Invalid requester
      # and the rule was never actually exercised.
      self.n_req_final_retained += 1
      self.logger.debug(
        f"COHERENCY REQ RETAIN: node {node} line 0x{line:x} "
        f"opcode 0x{_I(opcode):x} held 0x{_I(held):x} "
        f"granted 0x{_I(granted):x} -> final 0x{final_state:x}")

    self._sample_req_transition(held, opcode, granted, final_state)
    self.set_node_state(line, node, final_state)

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

  # Request tracking for catalogue rule D8. Deliberately a separate pair from
  # hazard_claim/hazard_release: same call sites, same lifetime, but ungated, so
  # turning the hazard rule off for its negative control does not also turn off
  # the request->snoop correspondence.
  def req_track_claim(self, node, line, txn_id, src_id, opcode):
    self.req_op_by_line[node][line] = _I(opcode)
    self.req_line_by_txn[node][txn_id] = line
    # SrcID is taken from the flit rather than from the node index: the index is
    # this checker's own numbering of the ports it is wired to, and the rule is
    # about the identifier the requester put on the wire.
    self.req_src_by_line[node][line] = _I(src_id)
    self.req_txn_by_line[node][line] = _I(txn_id)

  def req_track_release(self, node, txn_id):
    line = self.req_line_by_txn[node].pop(txn_id, None)
    if line is not None:
      self.req_op_by_line[node].pop(line, None)
      self.req_src_by_line[node].pop(line, None)
      self.req_txn_by_line[node].pop(line, None)

  def check_snoop_fwd_names_requester(self, node, line, snp_op, fwd_nid, fwd_txn_id,
                                      cause_node, cause_src, cause_txn):
    """A forwarding snoop must name the requester it is forwarding to.

    IHI 0050 E 2.5 states both halves of the FwdNID/FwdTxnID rule. The SNP
    channel bind judges the half a link-layer checker can see -- the fields are
    inapplicable and must be zero on every snoop that is not one of the six
    forwarding forms -- and passed ANY value on the six that are. The positive
    half is here because it needs the cause: FwdNID must be the Node ID of the
    original Requester, FwdTxnID the TxnID of the original Request.

    Both fields are judged even though only one of them can fail on this bench.
    Every RN-F here drives SrcID zero, so the FwdNID comparison is 0 == 0 and
    holds whatever the home puts in the field; it is the FwdTxnID half that
    carries the weight until a test gives the two requesters distinct Node IDs.
    Written as one rule rather than two because the specification writes it as
    one and a home that mis-addresses a forward gets both fields from the same
    place -- and reported field by field, so the message says which half broke.
    """
    if not snp_opcode_is_forwarding(_I(snp_op)):
      return

    self.n_snp_fwd_judged += 1

    if _I(fwd_nid) != _I(cause_src):
      self.n_snp_fwd_mismatch += 1
      self.logger.error(
        f"COHERENCY VIOLATION: forwarding snoop opcode 0x{_I(snp_op):x} sent to "
        f"node {node} for line 0x{line:x} carries FwdNID 0x{_I(fwd_nid):x}, but "
        f"the request that caused it (node {cause_node}, TxnID 0x{cause_txn:x}) "
        f"came from SrcID 0x{cause_src:x} -- IHI 0050 E 2.5 requires FwdNID to "
        f"be the Node ID of the original Requester")

    if _I(fwd_txn_id) != _I(cause_txn):
      self.n_snp_fwd_mismatch += 1
      self.logger.error(
        f"COHERENCY VIOLATION: forwarding snoop opcode 0x{_I(snp_op):x} sent to "
        f"node {node} for line 0x{line:x} carries FwdTxnID 0x{_I(fwd_txn_id):x}, "
        f"but the request that caused it (node {cause_node}, SrcID "
        f"0x{cause_src:x}) is TxnID 0x{cause_txn:x} -- IHI 0050 E 2.5 requires "
        f"FwdTxnID to be the TxnID of the original Request")

  def check_snoop_matches_request(self, node, line, snp_op, fwd_nid, fwd_txn_id):
    """Catalogue rule D8: a snoop's opcode must be one IHI 0050 E Table 4-5 / D
    Table 4-3 permits for the request that caused it.

    Nothing in this VIP checked the snoop against its cause before. Every rule on
    the SNP channel judged the flit's own contents -- its opcode is a modeled
    one, its fields are in range, the response to it is a permitted form -- and
    the pairing of a request with the snoop the home chose for it was left to the
    home's own code to get right. It got one row wrong for both issues, and the
    covergroup could not show the gap either, because the bins were drawn from
    the set of opcodes this home originates: the two it should have been sending
    were not binned, so the report was closed on a space that excluded the
    correct answer.

    The correlation is by cache line and excludes the snooped node itself: a
    requester is never snooped for its own request. Two nodes with a request
    outstanding to the same line is ordinary contention, not an error, but it
    leaves the cause ambiguous -- the rule declines to judge rather than guess,
    and the decline is counted.
    """
    causes = [(k, self.req_op_by_line[k][line])
              for k in range(N_NODES)
              if k != node and line in self.req_op_by_line[k]]
    # No cause, or more than one candidate: not judgeable. A spontaneous snoop is
    # explicitly permitted, so silence here is the correct answer and not a
    # missed check.
    if len(causes) != 1:
      self.n_snp_req_uncorrelated += 1
      return
    cause_node, cause_op = causes[0]
    self.n_snp_req_judged += 1
    cause_src = self.req_src_by_line[cause_node][line]
    cause_txn = self.req_txn_by_line[cause_node][line]

    # The cross, recorded for every correlated pair including the ones rejected
    # below: a cross that only ever saw conformant traffic would say nothing
    # about what was exercised. Table 4-5 is indexed by request opcode, so a
    # coverage model carrying the two opcodes on separate axes cannot express a
    # single row of it -- and this is the only point where both are known.
    self._rsp_hit.add((_I(cause_op), _I(snp_op)))

    self.check_snoop_fwd_names_requester(node, line, snp_op, fwd_nid, fwd_txn_id,
                                         cause_node, cause_src, cause_txn)

    if not req_generates_snoop(cause_op):
      self.n_snp_req_mismatch += 1
      self.logger.error(
        f"COHERENCY VIOLATION: snoop opcode 0x{_I(snp_op):x} sent to node {node} "
        f"for line 0x{line:x}, but the request outstanding on that line from "
        f"node {cause_node} (opcode 0x{cause_op:x}) generates no snoop "
        f"(Table 4-5 lists n/a in every snoop column)")
      return
    if not snoop_permitted_for_req(cause_op, snp_op):
      self.n_snp_req_mismatch += 1
      self.logger.error(
        f"COHERENCY VIOLATION: snoop opcode 0x{_I(snp_op):x} sent to node {node} "
        f"for line 0x{line:x} is not permitted for the request that caused it "
        f"(node {cause_node}, opcode 0x{cause_op:x}) -- IHI 0050 E Table 4-5 / "
        f"D Table 4-3 and the bullets under it")

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
    self.req_track_claim(node, line, _I(item.txn_id), item.src_id, wop)
    # Rule D9's arming step. ReadOnce is excluded here rather than at the
    # judgement, because section 2.8.3 names it as the request for which the home
    # need not wait -- the exception belongs to the transaction.
    if _I(item.exp_comp_ack) and wop != int(ReqOpcode.READ_ONCE):
      self.req_eca_line[node][_I(item.txn_id)] = line
    is_read, _uniq = self.is_coherent_read(item)
    if is_read:
      tid = _I(item.txn_id)
      self.open_rd_line[node][tid] = line
      self.open_rd_uniq[node][tid] = _uniq
      self.open_rd_op[node][tid] = wop
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
      self.req_track_release(node, tid)

    # Rule D9: on a CopyBack there is no CompAck flit to wait for, and section
    # 2.8.3 says so in as many words -- "For CopyBack transactions, WriteData
    # acts as an implicit CompAck and an HN-F must wait for WriteData before
    # sending a snoop to the same address." Same window, same guarantee, closed
    # by a DAT flit instead of an RSP one.
    #
    # WriteEvictOrEvict is the only opcode this reaches today: Table 2-9 marks it
    # required, and its data leg answers CompDBIDResp with CopyBackWrData and
    # nothing else. Closing the window on the explicit CompAck alone left that
    # leg's window open forever -- visible as compack_windows_unclosed=1 in
    # tc_chi_{d,e}_write_evict_or_evict, which is what found this.
    if op == int(DatOpcode.COPY_BACK_WR_DATA):
      self.close_comp_ack_window(node, tid)
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
        # The Resp-encoding half of the same pairing, on the data-carrying
        # responses. The last beat carries the snoopee's final state; a
        # SnpRespData with no beats cannot report one, so it is read as Invalid
        # rather than skipped -- an unjudged response is how this rule goes
        # quietly vacuous.
        self.check_snp_resp_state(
          node, self.pending_snp_line[node],
          _I(item.dat_resp[-1]) if item.dat_resp else int(Resp.I),
          True)
        self.record_line_data(self.pending_snp_line[node], item)
        self.pending_snp_valid[node] = False
      return
    if op != int(DatOpcode.COMP_DATA):
      return
    if tid not in self.open_rd_line[node]:
      return

    line = self.open_rd_line[node][tid]
    granted = _I(item.dat_resp[-1]) if item.dat_resp else int(Resp.I)
    self.resolve_req_final_state(
      node, line, self.open_rd_op[node].get(tid, 0), granted)

    ll_excl = self.open_rd_excl[node].get(tid, False)
    if ll_excl:
      ll_okay = bool(item.dat_resp_err) and \
          _I(item.dat_resp_err[-1]) == int(RespErr.EXOKAY)
      if ll_okay:
        self.excl_ll_valid[node][line] = True
        self.excl_clear_cause[node][line] = _EXCL_CLEAR_NONE

    self.open_rd_line[node].pop(tid, None)
    self.open_rd_uniq[node].pop(tid, None)
    self.open_rd_op[node].pop(tid, None)
    self.open_rd_excl[node].pop(tid, None)
    self.n_completions += 1
    self.open_comp_ack_window(node, tid)
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
    from_state = _I(self.pending_snp_from[node])
    predicted = self._entry(line)[node]
    legal = True

    # Sampled unconditionally, legal pairings included: a cross that only ever
    # recorded its violations would say nothing about what was exercised.
    self._srl_hit.add((op, state, bool(with_data)))

    if snp_opcode_invalidates(op) and state != int(Resp.I):
      self.n_bad_snp_resp_state += 1
      legal = False
      self.logger.error(
        f"COHERENCY VIOLATION: node {node} answered invalidating snoop opcode "
        f"0x{op:x} on line 0x{line:x} reporting state 0x{state:x}, but every "
        f"response Chapter 4 permits to it is Invalid")
    elif (snp_opcode_forbids_retaining_unique(op)
          and state in (int(Resp.UC), int(Resp.UD_PD))):
      self.n_bad_snp_resp_state += 1
      legal = False
      self.logger.error(
        f"COHERENCY VIOLATION: node {node} answered shared snoop opcode "
        f"0x{op:x} on line 0x{line:x} still holding Unique (state 0x{state:x}); "
        f"the grant that follows would create a second owner")

    # ------------------------------------------------------------------------
    # DoNotGoToSD, judged from the RESPONSE rather than from the flit.
    #
    # "Snoopee receiving a Snoop request with the DoNotGoToSD bit set, except
    # when the Snoop is SnpOnceFwd, must not transition to SD." The SNP-channel
    # rule CHI_SNP_DO_NOT_GO_TO_SD_LEGAL judges whether the bit was set where the
    # specification requires it; this judges whether the snoopee OBEYED it, which
    # is a different claim and the one that matters to a third-party DUT.
    #
    # Neither D5 nor D6 catches it. D5 bounds the reported state by the opcode,
    # and SD is not Unique, so a shared snoop answered SD passes it. D6 bounds
    # the state by what the snoopee held, and an SD holder answering SD passes
    # that too. The bit is a third bound and it needed its own arm.
    #
    # ------------------------------------------------------------------------
    if (state == int(Resp.SD_PD) and self.pending_snp_no_sd[node]
        and op != int(SnpOpcode.ONCE_FWD)):
      self.n_bad_snp_sd_under_no_sd += 1
      legal = False
      self.logger.error(
        f"COHERENCY VIOLATION: node {node} answered snoop opcode 0x{op:x} on "
        f"line 0x{line:x} reporting SD, but that snoop carried DoNotGoToSD = 1 "
        f"and is not SnpOnceFwd; the snoopee must not transition to SD")

    # ------------------------------------------------------------------------
    # Catalogue rule D6: the reported state must not hold a permission the
    # snoopee did not have when the snoop arrived.
    #
    # D5 above bounds the response by what was ASKED; this bounds it by what was
    # HELD, and neither implies the other -- an SC holder answering SnpOnce with
    # UC passes every opcode-keyed rule and is still impossible. A snoop is a
    # request to give up permissions, never a grant of them; the only path that
    # raises a cache state is a response to that node's own request, on a
    # transaction this snoop knows nothing about.
    #
    # It is a gate and not merely a report, because the reported state is now
    # ADOPTED into the shadow directory below. Without it a peer reporting
    # nonsense would steer every later coherency check through the nonsense.
    # ------------------------------------------------------------------------
    if snp_resp_state_gains_permission(from_state, state):
      self.n_snp_resp_gains_permission += 1
      legal = False
      self.logger.error(
        f"COHERENCY VIOLATION: node {node} held state 0x{from_state:x} on line "
        f"0x{line:x} and answered snoop opcode 0x{op:x} reporting state "
        f"0x{state:x}; a snoop cannot grant a permission the snoopee did not "
        f"already hold")

    # ------------------------------------------------------------------------
    # Catalogue rule D7: a snoopee holding Dirty must hand the dirty data over
    # unless it is keeping it.
    #
    # IHI 0050 E Tables 4-30 to 4-34 (Snoopee state transitions) enumerate this
    # row by row: every row whose INITIAL state is UD, UDP or SD and whose final
    # state does not hold the dirty requires a SnpRespData_*_PD response. The
    # only rows where a Dirty snoopee answers without data are the ones where it
    # stays Dirty -- UD -> UD, UD -> SD, SD -> SD.
    #
    # Answering SnpResp_SC from UD instead loses the only modified copy in the
    # system: the snoopee has dropped its claim to the line, the Home believes
    # memory is current, and the next reader is served stale data with every
    # check agreeing. Nothing else here catches it -- the reported STATE is legal
    # (D5 and D6 both pass SC from UD), and the existing response-form rule reads
    # the other direction, flagging data returned where none was wanted. This is
    # the missing direction: data NOT returned where it was owed.
    #
    # SnpMakeInvalid is excluded because discarding is precisely what it asks
    # for, which is the rule check_snp_resp_form polices.
    # ------------------------------------------------------------------------
    if (state_holds_dirty(from_state) and not state_holds_dirty(state)
        and not snp_opcode_returns_no_data(op) and not with_data):
      self.n_snp_dirty_lost += 1
      self.logger.error(
        f"COHERENCY VIOLATION: node {node} held state 0x{from_state:x} (Dirty) "
        f"on line 0x{line:x} and answered snoop opcode 0x{op:x} with state "
        f"0x{state:x} and NO data; the dirty copy is neither retained nor "
        f"passed on")

    self.n_snp_resp_judged += 1

    # ------------------------------------------------------------------------
    # Take the snoopee's next state FROM THE RESPONSE.
    #
    # The snoop opcode CONSTRAINS the resulting state but does not determine it:
    # a UD holder answering SnpShared may pass the dirty data on and report SC,
    # or keep it and report SD, and which one happened is knowable only here.
    # Deriving it from the opcode alone -- what snoop_result() does, and what
    # this checker did everywhere before D6 -- records what a snoop WOULD do to
    # this VIP's own RN-F, which against any other peer is an assumption
    # presented as an observation. One desynchronized entry then misdirects the
    # single-writer check, the occupancy count and the data-integrity shadow, and
    # every message they produce points at the peer.
    #
    # snoop_result() keeps its job as the PREDICTION: the shadow needs a value
    # between the snoop and its response, and obs_snp still writes one. This
    # reconciles it. An illegal response is not adopted -- D5 and D6 have already
    # reported it, and steering the model with a value known to be wrong would
    # turn one reported violation into a run of unexplained ones.
    # ------------------------------------------------------------------------
    if legal:
      if state != predicted:
        self.n_snp_resp_state_differs += 1
      self.set_node_state(line, node, state)
      self.n_snp_resp_adopted += 1
      # The transition covergroup records the OBSERVED outcome, so it is sampled
      # here rather than at the snoop. Sampled on the prediction it was a pure
      # function of its own inputs, which is why the SV cp_to illegal_bins could
      # never fire: snoop_result() provably returns only I or SC.
      if self.snoop_samples_cache_transition(op):
        self._sample_cache_transition(from_state, op, state)

  def check_snp_resp_form(self, node, line, op):
    if not snp_opcode_returns_no_data(self.pending_snp_opcode[node]):
      return
    self.n_bad_snp_resp_form += 1
    self.logger.error(
      f"COHERENCY VIOLATION: node {node} answered snoop opcode "
      f"0x{_I(self.pending_snp_opcode[node]):x} on line 0x{line:x} with DAT "
      f"opcode 0x{op:x}; that snoop returns no data and discards its dirty copy")

  # Catalogue rule D9 -- SNOOP_OUTSIDE_COMPACK_WINDOW.
  #
  # IHI 0050 E section 2.8.3 (D section 2.8.3), rule 2 of the completion
  # sequence: "An HN-F, except in the case of ReadOnce*, waits for CompAck
  # before sending a subsequent snoop to the same address." The same paragraph
  # states the guarantee from the requester's side, which is the form this rule
  # judges because it is the form that is visible on one node's wires:
  #
  #   "When an RN-F has a transaction in progress that uses CompAck, except for
  #    ReadNoSnp and ReadOnce*, then it is guaranteed not to receive a Snoop
  #    request to the same address between the point that it receives Comp and
  #    the point that it sends CompAck."
  #
  # This is the ordering guarantee CompAck exists to provide, and it is what
  # makes the acknowledgement worth sending at all. Without it the requester can
  # be snooped for a line it has been granted but not yet taken responsibility
  # for, and the completion and the snoop can be observed by the two ends in
  # opposite orders -- the precise outcome section 2.8.3 opens by ruling out.
  #
  # The window is deliberately checked across ALL nodes, not just the snooped
  # one. The home-side wording forbids the snoop outright ("a subsequent snoop to
  # the same address"), whoever it is addressed to, and a snoop sent to a third
  # node in that window is the same ordering hazard seen from a different seat.
  def open_comp_ack_window(self, node, txn_id):
    line = self.req_eca_line[node].pop(txn_id, None)
    if line is None:
      return
    # A window still open here means the previous acknowledgement was never
    # observed. Counted rather than reported: it is a gap in what this checker
    # saw, not a protocol violation, and a summary that says so is what tells a
    # reader whether the zero beside it means "clean" or "never looked".
    if self.eca_open[node]:
      self.n_eca_windows_unclosed += 1
    self.eca_open[node] = True
    self.eca_line[node] = line
    self.eca_txn[node] = txn_id
    self.n_eca_windows += 1

  def close_comp_ack_window(self, node, txn_id):
    if self.eca_open[node] and self.eca_txn[node] == txn_id:
      self.eca_open[node] = False

  def check_snoop_outside_comp_ack_window(self, snooped, line):
    for k in range(N_NODES):
      if not self.eca_open[k] or self.eca_line[k] != line:
        continue
      self.n_eca_window_snoops += 1
      self.logger.error(
        f"COHERENCY VIOLATION: snoop to line 0x{line:x} (node {snooped}) "
        f"arrived inside node {k}'s CompAck window for TxnID "
        f"0x{self.eca_txn[k]:x} -- section 2.8.3 requires the home to wait for "
        f"CompAck before snooping the same address")

  def obs_snp(self, node, item):
    if not self.enable or not item.is_snoop:
      return
    line = self.line_of(item.snp_addr)
    cur = self._entry(line)[node]
    # The PREDICTED result, applied to the shadow so the window between a snoop
    # and its response is not modeled as if the snoop had not happened. It is
    # reconciled against the state the response actually reports in
    # check_snp_resp_state, which is where the transition covergroup is now
    # sampled -- it records the observed outcome, not this guess.
    predicted = self.snoop_result(item.snp_opcode, cur)
    self.set_node_state(line, node, predicted)
    # Keyed off the snoop and not the response on purpose: it is the snoop that
    # breaks the exclusive reservation, whatever the snoopee goes on to report.
    if predicted == int(Resp.I):
      if self.excl_ll_valid[node].get(line):
        self.excl_clear_cause[node][line] = _EXCL_CLEAR_SNOOP
        self.excl_ll_valid[node][line] = False
    if snp_opcode_returns_no_data(item.snp_opcode) and self.state_is_dirty(cur):
      self.n_snp_no_data_on_dirty += 1
    # Rule D8 runs on the request set outstanding at the moment the snoop
    # arrives.
    self.check_snoop_matches_request(node, line, item.snp_opcode,
                                     item.fwd_nid, item.fwd_txn_id)
    # D9 alongside D8, and for the same reason: both judge the snoop as it
    # arrives, against state that the bookkeeping below is about to change.
    self.check_snoop_outside_comp_ack_window(node, line)
    self.pending_snp_line[node] = line
    self.pending_snp_valid[node] = True
    self.pending_snp_opcode[node] = _I(item.snp_opcode)
    # The from-state, kept because the shadow above no longer holds it and D6
    # needs it to bound what the response may legally report.
    self.pending_snp_from[node] = _I(cur)
    self.pending_snp_no_sd[node] = bool(getattr(item, "do_not_go_to_sd", False))
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

    # A CompAck closes rule D9's window and is not a completion of anything --
    # handled first and returned from, exactly like SnpResp above, so it cannot
    # fall through into the correlation tables it was never entered in.
    if _I(item.rsp_opcode) == int(RspOpcode.COMP_ACK):
      self.close_comp_ack_window(node, tid)
      return

    # A data-less completion (CleanUnique, MakeUnique, WriteUnique) opens the
    # window that CompData opens for a read. NOT _HAZARD_RELEASE_RSP_OPS: that
    # set includes RetryAck, which releases the line without completing
    # anything. Opening a window on a bounced request would leave one hanging
    # that no CompAck can ever close -- the re-issue completes under the same
    # TxnID and opens its own -- and every snoop to that line in between would be
    # reported against a transaction the completer had refused outright.
    if _I(item.rsp_opcode) in _COMP_ACK_COMPLETION_RSP_OPS:
      self.open_comp_ack_window(node, tid)

    # Release the line on a genuine completion. DBIDResp and ReadReceipt are
    # deliberately NOT in this set: they grant a buffer and confirm ordering
    # respectively, and the transaction is still live after either. A RetryAck is
    # in it because the completer refused the request outright -- it holds no
    # line, and the re-issue claims one again.
    if _I(item.rsp_opcode) in _HAZARD_RELEASE_RSP_OPS:
      self.hazard_release(node, tid)
      self.req_track_release(node, tid)
    # MakeUnique completion (RSP-only Comp): mark the requester Unique owner and
    # run the single-writer check.
    if tid in self.open_mu_line[node]:
      line = self.open_mu_line[node][tid]
      # Validate the OBSERVED completion rather than inventing a state: a
      # MakeUnique must complete with a data-less Comp.
      if _I(item.rsp_opcode) != int(RspOpcode.COMP):
        self.n_bad_make_unique += 1
        self.logger.error(
          f"COHERENCY VIOLATION: MakeUnique on line 0x{line:x} (node {node}) "
          f"completed opcode=0x{_I(item.rsp_opcode):x} resp=0x{_I(item.rsp_resp):x}, "
          f"expected a data-less Comp")
      # The GRANTED state on that Comp is Comp_UC. MakeUnique's final state is
      # Unique-Dirty from every permitted initial state, but the Requester
      # becomes Dirty by its own act of overwriting the whole line -- no dirty
      # data is being handed to it -- and the response says so: Table 4-19 (D
      # Table 4-13) lists Comp_UC as the completion for MakeUnique, and
      # Comp_UD_PD means "responsibility for a Dirty cache line is being passed",
      # which is a different transaction. Issue D does not define the UD_PD
      # encoding for a data-less completion at all (Table 4-5 lists only Comp_I,
      # Comp_UC and Comp_SC), so requiring it here rejected the one legal answer
      # and demanded one a CHI-D completer may not send.
      if _I(item.rsp_resp) != int(Resp.UC):
        self.n_bad_dataless_resp += 1
        self.logger.error(
          f"COHERENCY VIOLATION: MakeUnique on line 0x{line:x} (node {node}) "
          f"completed resp=0x{_I(item.rsp_resp):x}; Table 4-19 permits only "
          f"Comp_UC (0x{int(Resp.UC):x}) for this request")
      # The final state still comes from the shared table function, which is what
      # turns that Comp_UC into the Unique-Dirty the Requester ends up holding.
      self.resolve_req_final_state(
        node, line, int(ReqOpcode.MAKE_UNIQUE), _I(item.rsp_resp))
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

  def get_snp_resp_gains_permission_count(self):
    return self.n_snp_resp_gains_permission

  def get_snp_resp_adopted_count(self):
    return self.n_snp_resp_adopted

  def get_snp_resp_state_differs_count(self):
    return self.n_snp_resp_state_differs

  def get_req_final_judged_count(self):
    return self.n_req_final_judged

  def get_req_final_retained_count(self):
    return self.n_req_final_retained

  def get_bad_dataless_resp_count(self):
    return self.n_bad_dataless_resp

  def get_snp_dirty_lost_count(self):
    return self.n_snp_dirty_lost

  def get_snp_req_judged_count(self):
    return self.n_snp_req_judged

  def get_snp_req_mismatch_count(self):
    return self.n_snp_req_mismatch

  def get_snp_req_uncorrelated_count(self):
    return self.n_snp_req_uncorrelated

  def get_snp_fwd_judged_count(self):
    return self.n_snp_fwd_judged

  def get_snp_fwd_mismatch_count(self):
    return self.n_snp_fwd_mismatch

  def get_comp_ack_window_count(self):
    return self.n_eca_windows

  def get_comp_ack_window_snoop_count(self):
    return self.n_eca_window_snoops

  def get_comp_ack_window_unclosed_count(self):
    return self.n_eca_windows_unclosed

  def get_snp_resp_legality_tuples(self):
    """The distinct (snoop opcode, resp state, with-data) triples observed.

    The pyUVM port has no covergroup object, so the SV cross is kept here as the
    hit set it would have filled. A test asserts on its size rather than on a
    percentage, because the denominator -- which pairings are reachable -- is a
    property of the stimulus and would have to be maintained by hand.
    """
    return set(self._srl_hit)

  def get_req_snp_pairing_tuples(self):
    """The (cause request opcode, snoop opcode) pairs reached -- the pyUVM twin
    of cg_req_snp_pairing's cross. Distinct pairs, not a count: one pair hit a
    thousand times covers one point of Table 4-5."""
    return set(self._rsp_hit)

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

  def get_req_cache_transition_coverage(self):
    # Functional coverage of the requester-side (held x request x granted ->
    # final) transition, averaged over the group's five items the way SV
    # covergroup.get_coverage() does. Observational only -- no invariant depends
    # on it; the invariant is n_req_final_retained.
    from_cov = len(self._rt_from_hit) / len(_RT_FROM_BINS)
    req_cov = len(self._rt_req_hit) / len(_RT_REQ_BINS)
    granted_cov = len(self._rt_granted_hit) / len(_RT_GRANTED_BINS)
    to_cov = len(self._rt_to_hit) / len(_RT_TO_BINS)
    cross_cov = len(self._rt_cross_hit) / _RT_CROSS_BIN_COUNT
    return 100.0 * (from_cov + req_cov + granted_cov + to_cov + cross_cov) / 5.0

  def total_violations(self):
    return (self.n_multi_owner + self.n_coherent_data_mismatch +
            self.n_excl_violation + self.n_bad_make_unique +
            self.n_bad_snp_resp_form + self.n_bad_snp_resp_state +
            self.n_bad_snp_sd_under_no_sd +
            self.n_bad_dataless_resp + self.n_snp_dirty_lost +
            self.n_snp_req_mismatch + self.n_snp_fwd_mismatch +
            self.n_eca_window_snoops + self.n_line_hazard)

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
      f"bad_snp_resp_state={self.n_bad_snp_resp_state} "
      f"snp_dirty_lost={self.n_snp_dirty_lost}")
    self.logger.info(
      f"COHERENCY DO NOT GO TO SD SUMMARY: "
      f"bad_snp_sd_under_no_sd={self.n_bad_snp_sd_under_no_sd}")
    # Its own line for the same reason as the two above: the report server wraps
    # long lines, and a wrapped field=value pair cannot be swept for with grep.
    self.logger.info(
      f"COHERENCY SNP RESP ADOPT SUMMARY: "
      f"snp_resp_adopted={self.n_snp_resp_adopted} "
      f"snp_resp_state_differs={self.n_snp_resp_state_differs} "
      f"snp_resp_gains_permission={self.n_snp_resp_gains_permission}")
    # Its own line for the same reason as the three above: the report server
    # wraps long lines, and a wrapped field=value pair cannot be swept for with
    # grep across a regression.
    self.logger.info(
      f"COHERENCY REQ FINAL STATE SUMMARY: "
      f"req_final_judged={self.n_req_final_judged} "
      f"req_final_retained={self.n_req_final_retained} "
      f"bad_dataless_resp={self.n_bad_dataless_resp}")
    # Its own line for the same reason as the four above.
    self.logger.info(
      f"COHERENCY COMPACK WINDOW SUMMARY: "
      f"compack_windows={self.n_eca_windows} "
      f"compack_window_snoops={self.n_eca_window_snoops} "
      f"compack_windows_unclosed={self.n_eca_windows_unclosed}")
    self.logger.info(
      f"COHERENCY SNP REQ MATCH SUMMARY: "
      f"snp_req_judged={self.n_snp_req_judged} "
      f"snp_req_mismatch={self.n_snp_req_mismatch} "
      f"snp_req_uncorrelated={self.n_snp_req_uncorrelated}")
    # Its own line: the report server wraps a long one, and a wrapped
    # `field=value` is invisible to the sweeps that grep for these.
    self.logger.info(
      f"COHERENCY SNP FWD NAMES SUMMARY: "
      f"snp_fwd_judged={self.n_snp_fwd_judged} "
      f"snp_fwd_mismatch={self.n_snp_fwd_mismatch}")
    # Its own line: the report server wraps a long one, and a wrapped
    # `field=value` is invisible to the sweeps that grep for these.
    self.logger.info(
      f"COHERENCY REQ SNP PAIRING SUMMARY: "
      f"req_snp_pairs={len(self._rsp_hit)}")
    self.logger.info(
      f"COHERENCY HAZARD SUMMARY: line_hazards={self.n_line_hazard} "
      f"line_claims_cleared={self.n_line_clear}")
