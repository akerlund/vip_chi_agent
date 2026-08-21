################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM/cocotb port of tc/tc_chi_e_retry_field_negctl.sv.
#
# The negative control for the two retry field rules, which both pass on every
# flit this VIP drives. That is the problem: a rule that has never failed is a
# rule whose failing branch has never run, and a stateless implication whose
# antecedent is subtly unreachable passes forever while reporting a healthy
# tally. Both rules were landed against tables rather than against a failure, so
# both need a flit that makes them move.
#
#   phase A  IHI 0050 E section 2.9.4: "If the AllowRetry field is asserted, the
#            PCrdType field must be set to 0b0000." One WriteUniqueZero carrying
#            both, which no driver here will produce -- the retry machinery sets
#            PCrdType only on the re-issue, where AllowRetry is already clear.
#   phase B  Table A-2 and Table A-3 mark every PCrdReturn field but QoS, TgtID,
#            SrcID, Opcode and PCrdType inapplicable and zero. One PCrdReturn
#            carrying an address. return_unused_pcrds builds its flit from zero
#            and fills in five fields, so the violation is a refactor away
#            rather than present today -- which is what a guard is for.
#   phase C  Section 2.6.5 step 2: "The TxnID is set to the same value as the
#            TxnID of the request." One RetryAck naming a TxnID no request has
#            used. The RN-I driver already fatals on this for its own
#            bookkeeping, but only while waiting on a specific request and only
#            at the requester -- nothing judges the SN-F end at all.
#
# Both phases inject rather than configure. A cfg knob would have to reach into
# the driver's retry path to corrupt a field the driver computes correctly, and
# the raw REQ path already carries the whole flit.
#
# The rules go to OFF rather than being disabled: OFF still evaluates and still
# counts, and only suppresses the report.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import CHECK_IDS, ReqOpcode, Resp, RespErr, RspOpcode
from chi_e_base_test import chi_e_base_test
from vip_chi_raw_seq import vip_chi_raw_seq
from chi_tb_pkg import (E_RETRY_NEGCTL_ADDR_C, E_RETRY_NEGCTL_PCRD_TYPE_C,
                        E_RETRY_NEGCTL_RNI_NODE_ID_C,
                        E_RETRY_NEGCTL_SNF_NODE_ID_C,
                        E_RETRY_NEGCTL_STRAY_TXN_ID_C, E_RETRY_NEGCTL_TXN_ID_C)

NON_SECURE_C = 1
SETTLE_C = 40
# Phase A's WriteUniqueZero has a modeled completion, so the checker holds it
# outstanding until the CompDBIDResp arrives while the raw-inject path scopes the
# REQ's TXSACTIVE window to the flit. Holding the sideband is legal -- TXSACTIVE
# says a node MAY have traffic outstanding, so over-assertion is permitted and
# under-assertion is the violation -- and honest where a waiver would not be.
TXSACTIVE_EXTEND_C = 32
ALLOW_RETRY_C = "CHI_REQ_ALLOW_RETRY_PCRD_ZERO"
PCRD_RETURN_C = "CHI_REQ_PCRD_RETURN_FIELDS_ZERO"
RETRY_ACK_TXN_ID_C = "CHI_RSP_RETRY_ACK_TXN_ID"
# One report per vantage, not "at least one". More would mean the rule is also
# firing on the compliant traffic that brought the link up.
EXPECTED_FAILS_C = 1


class tc_chi_e_retry_field_negctl(chi_e_base_test):

  # The injected flits are serviced by this test, not by the responder, so the
  # scoreboard sees flits it never paired. Correct of the scoreboard and beside
  # the point here.
  def configure_tb_cfg(self):
    super().configure_tb_cfg()
    self.tb_cfg.scoreboard_enable = False
    self.tb_cfg.txsactive_extend_max_cycles = TXSACTIVE_EXTEND_C

  # The driver half of the same hold: tb_cfg reaches the checkers, the agent cfg
  # reaches the RN-I that drives the wire, and both have to agree or the checker
  # would judge a window the driver never drove.
  def configure(self, rni_cfg, snf_cfg):
    super().configure(rni_cfg, snf_cfg)
    rni_cfg.txsactive_extend_max_cycles = TXSACTIVE_EXTEND_C

  # Phase A's flit: conformant in every respect except the one under test, so
  # exactly one rule can object to it. Table 2-9 marks WriteUniqueZero's
  # ExpCompAck prohibited, so that field stays zero; the opcode is Snoopable only
  # (Table 2-14) and Table 2-12 lists no Snoopable row without Cacheable and EWA,
  # so MemAttr is set here rather than left at the raw flit's zero.
  def _retry_field_violator(self) -> dict:
    return {
      "txnid": E_RETRY_NEGCTL_TXN_ID_C,
      "srcid": E_RETRY_NEGCTL_RNI_NODE_ID_C,
      "tgtid": E_RETRY_NEGCTL_SNF_NODE_ID_C,
      "opcode": int(ReqOpcode.WRITE_UNIQUE_ZERO),
      "addr": E_RETRY_NEGCTL_ADDR_C,
      "size": 6,
      "snpattr": 1,
      "memattr": 0b0101,
      "ns": NON_SECURE_C,
      "qos": 0x7,
      # The violation, and nothing else on this flit is wrong.
      "allowretry": 1,
      "pcrdtype": E_RETRY_NEGCTL_PCRD_TYPE_C,
    }

  # The completion phase A's opcode takes: a combined CompDBIDResp carrying the
  # request's own TxnID. The buffer it grants goes unused because the request
  # carries no data -- the completion form is normative regardless.
  def _comp_dbid_resp(self) -> dict:
    return {
      "opcode": int(RspOpcode.COMP_DBID_RESP),
      "txnid": E_RETRY_NEGCTL_TXN_ID_C,
      "dbid": E_RETRY_NEGCTL_TXN_ID_C,
      "resp": int(Resp.I),
      "resperr": int(RespErr.OKAY),
      "srcid": E_RETRY_NEGCTL_SNF_NODE_ID_C,
      "tgtid": E_RETRY_NEGCTL_RNI_NODE_ID_C,
      "qos": 0x7,
    }

  # Phase C's flit: a RetryAck for a transaction that does not exist. Well
  # formed in every other respect -- Table A-4 gives RetryAck RespErr and Resp
  # both "0", and DBID is not valid on it -- so the only thing wrong with the
  # flit is the one thing under test.
  def _stray_retry_ack(self) -> dict:
    return {
      "opcode": int(RspOpcode.RETRY_ACK),
      "srcid": E_RETRY_NEGCTL_SNF_NODE_ID_C,
      "tgtid": E_RETRY_NEGCTL_RNI_NODE_ID_C,
      "pcrdtype": E_RETRY_NEGCTL_PCRD_TYPE_C,
      "qos": 0x7,
      # The violation: no request on this link has carried this TxnID.
      "txnid": E_RETRY_NEGCTL_STRAY_TXN_ID_C,
    }

  # Phase B's flit: a PCrdReturn carrying an address. AllowRetry stays zero and
  # PCrdType stays set, so this flit does NOT also violate phase A's rule and the
  # two counts stay separable. TxnID stays zero for the same reason: it is in the
  # same zero-marked set as Addr, and setting both would still be one report but
  # would stop naming which field moved.
  def _pcrd_return_violator(self) -> dict:
    return {
      "opcode": int(ReqOpcode.PCRD_RETURN),
      "srcid": E_RETRY_NEGCTL_RNI_NODE_ID_C,
      "tgtid": E_RETRY_NEGCTL_SNF_NODE_ID_C,
      "pcrdtype": E_RETRY_NEGCTL_PCRD_TYPE_C,
      "qos": 0x7,
      # The violation. Table A-3 gives PCrdReturn's Addr column "0a": the
      # transaction addresses nothing.
      "addr": E_RETRY_NEGCTL_ADDR_C,
    }

  def _require_silent(self, rule: str) -> None:
    """The rule may not have reported yet, or the counts below prove nothing."""
    rni = self.tb_env.rni_sva.fail_count.get(rule, 0)
    snf = self.tb_env.snf_sva.fail_count.get(rule, 0)
    assert rni == 0 and snf == 0, (
      f"{rule} already reported rni_e={rni} snf_e={snf} time(s) on compliant "
      f"traffic; the counts below would prove nothing")

  def _require_provoked(self, rule: str) -> None:
    """Exactly one report at each vantage.

    Both, because a rule asserted at two vantages under one name may be doing
    its job at only one of them, and a link may carry a bind at either end
    alone.
    """
    rni = self.tb_env.rni_sva.fail_count.get(rule, 0)
    snf = self.tb_env.snf_sva.fail_count.get(rule, 0)
    assert rni == EXPECTED_FAILS_C, (
      f"{rule} reported {rni} time(s) at the RN-I, expected exactly "
      f"{EXPECTED_FAILS_C}; below means the flit is not reaching the rule, "
      f"above means it is firing on compliant traffic too")
    assert snf == EXPECTED_FAILS_C, (
      f"{rule} reported {snf} time(s) at the SN-F, expected exactly "
      f"{EXPECTED_FAILS_C}; the receiving vantage of the rule is not doing its "
      f"half")

  def _require_nothing_else_fired(self, *allowed: str) -> None:
    """What makes a corrupted flit an honest control.

    Without this, a flit that is wrong in several ways at once would still show
    the two expected reports and pass.
    """
    for rule in CHECK_IDS:
      if rule in allowed:
        continue
      rni = self.tb_env.rni_sva.fail_count.get(rule, 0)
      snf = self.tb_env.snf_sva.fail_count.get(rule, 0)
      assert rni == 0 and snf == 0, (
        f"{rule} also failed (rni_e={rni} snf_e={snf}); the injected flits are "
        f"wrong in more ways than the two under test")

  async def _inject_req(self, flit: dict) -> None:
    seq = vip_chi_raw_seq("rni_raw_seq", cfg=self.chi_cfg)
    seq.reset()
    seq.add_raw_req(flit)
    await seq.start(self.tb_env.rni_agent.sequencer)

  async def _inject_completion(self) -> None:
    seq = vip_chi_raw_seq("snf_raw_seq", cfg=self.chi_cfg)
    seq.reset()
    seq.add_raw_rsp(self._comp_dbid_resp())
    await seq.start(self.tb_env.snf_agent.sequencer)

  async def _inject_rsp(self, flit: dict) -> None:
    seq = vip_chi_raw_seq("snf_raw_seq", cfg=self.chi_cfg)
    seq.reset()
    seq.add_raw_rsp(flit)
    await seq.start(self.tb_env.snf_agent.sequencer)

  async def run_phase(self):
    self.raise_objection()

    rni_sva, snf_sva = self.tb_env.rni_sva, self.tb_env.snf_sva

    # Compliant traffic first. It brings the link to RUN and puts real requests
    # past both rules, so the silence asserted next is a statement about
    # compliant flits rather than about an idle link.
    wr = self.rni_wr_seq
    wr.reset()
    wr.set_requests(1)
    wr.set_initial_addr(E_RETRY_NEGCTL_ADDR_C)
    wr.set_size(6)
    wr.set_get_response(True)
    wr.set_verbose(False)
    await wr.start(self.tb_env.rni_agent.sequencer)

    await self.wait_clocks(4)
    self.drain_observation_fifos()

    self._require_silent(ALLOW_RETRY_C)
    self._require_silent(PCRD_RETURN_C)
    self._require_silent(RETRY_ACK_TXN_ID_C)

    allow_retry_pass_before = rni_sva.pass_count.get(ALLOW_RETRY_C, 0)
    pcrd_return_pass_before = rni_sva.pass_count.get(PCRD_RETURN_C, 0)

    assert allow_retry_pass_before > 0, (
      f"{ALLOW_RETRY_C} recorded no pass on the compliant write; the rule is "
      f"not evaluating and its silence below would mean nothing")

    # -- Phase A: AllowRetry asserted together with a P-Credit type. ----------
    rni_sva.off_check(ALLOW_RETRY_C)
    snf_sva.off_check(ALLOW_RETRY_C)

    await self._inject_req(self._retry_field_violator())
    await self.wait_clocks(4)

    # Complete it. Leaving it outstanding would time out the completion rule and
    # mix two verdicts into one run.
    await self._inject_completion()
    await self.wait_clocks(SETTLE_C)

    self._require_provoked(ALLOW_RETRY_C)
    self._require_silent(PCRD_RETURN_C)

    # -- Phase B: a PCrdReturn that addresses something. ----------------------
    rni_sva.off_check(PCRD_RETURN_C)
    snf_sva.off_check(PCRD_RETURN_C)

    await self._inject_req(self._pcrd_return_violator())
    await self.wait_clocks(SETTLE_C)

    self._require_provoked(PCRD_RETURN_C)
    # Phase A's count must not have moved: the PCrdReturn carries AllowRetry
    # zero, so the earlier rule has nothing to say about it, and a second report
    # here would mean the two rules are not separable.
    self._require_provoked(ALLOW_RETRY_C)

    # Both rules must still be recording passes. A rule that only ever fails is
    # as broken as one that only ever passes.
    assert rni_sva.pass_count.get(PCRD_RETURN_C, 0) >= pcrd_return_pass_before, (
      f"{PCRD_RETURN_C} pass count went backwards")

    # -- Phase C: a RetryAck for a transaction nobody opened. -----------------
    rni_sva.off_check(RETRY_ACK_TXN_ID_C)
    snf_sva.off_check(RETRY_ACK_TXN_ID_C)

    await self._inject_rsp(self._stray_retry_ack())
    await self.wait_clocks(SETTLE_C)

    self._require_provoked(RETRY_ACK_TXN_ID_C)
    # The earlier two must still stand at one each: a RetryAck is an RSP and
    # neither REQ rule has anything to say about it.
    self._require_provoked(ALLOW_RETRY_C)
    self._require_provoked(PCRD_RETURN_C)

    self._require_nothing_else_fired(ALLOW_RETRY_C, PCRD_RETURN_C,
                                     RETRY_ACK_TXN_ID_C)

    self.logger.info(
      f"Test (tc_chi_e_retry_field_negctl) PASS: {ALLOW_RETRY_C}, "
      f"{PCRD_RETURN_C} and {RETRY_ACK_TXN_ID_C} each provoked once at both "
      f"vantages, and nothing else in the registry fired")

    self.drop_objection()
