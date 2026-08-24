################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM/cocotb port of tc/tc_chi_e_write_unique_zero_negctl.sv.
#
# Two identifier rules, asked to do their job on the one opcode no classifier
# used to claim. IHI 0050 E section 2.3 gives a requester one live transaction per
# TxnID; section 2.6 says an accepted request is completed. Both rules are gated
# on a classifier that answers "does this opcode have a modeled completion", so an
# opcode the classifier does not name is walked past in silence by both -- and
# silence reads as success.
#
#   phase A  a WriteUniqueZero that COMPLETES, so CHI_COMPLETION_FOLLOWS_REQ
#            records a pass. A rule that cannot arm cannot time out either, so
#            without this its quiet is not evidence of anything.
#   phase B  a WriteUniqueZero that REUSES a live TxnID, so CHI_TXNID_REUSE_*
#            reports exactly once at each end. This is the rule the classifier fix
#            switched on, so it is the one that has to be proved to fire.
#
# Phase B completes its duplicate as well. Leaving it outstanding would time the
# completion rule out and mix the verdicts, leaving no way to tell which rule the
# reports came from.
#
# Raw injection, because no SN-F services WriteUniqueZero and correctly so: a
# snoopable store is Home business and an SN-F cannot snoop. The opcode's real
# completer is the HN-F on the coherent topology, where request and completion are
# not both visible on one link and the completion timeout is off by construction.
# This is the only link where the timeout is live, so the flits go on it verbatim.
#
# The rules are turned down to OFF rather than disabled: OFF still evaluates and
# still counts, and only suppresses the report, which is what a negative control
# needs.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import ReqOpcode, Resp, RespErr, RspOpcode
from chi_e_base_test import chi_e_base_test
from vip_chi_raw_seq import vip_chi_raw_seq
from chi_tb_pkg import (E_WUZ_NEGCTL_ADDR_C, E_WUZ_NEGCTL_RNI_NODE_ID_C,
                        E_WUZ_NEGCTL_SNF_NODE_ID_C, E_WUZ_NEGCTL_TXN_ID_DUP_C,
                        E_WUZ_NEGCTL_TXN_ID_PASS_C)

NON_SECURE_C = 1
SETTLE_C = 40
# How long the requester holds TXSACTIVE past the close of its last window.
#
# The raw-inject path scopes a REQ's outstanding window to the flit itself -- "a
# raw flit is a single injected packet with no completion to wait for" -- which was
# sound while every raw-injectable REQ opcode had no modeled completion. It is not
# sound for this one: the checker tracks the request as outstanding until its
# completion arrives, so the sideband would go low with a transaction still live
# and CHI_TXSACTIVE_COVERS_OUTSTANDING would report it, correctly and about the
# wrong thing.
#
# Holding the sideband is the honest fix rather than a waiver. TXSACTIVE is
# permissive -- it says the node MAY have outstanding transactions -- so
# over-assertion is legal and under-assertion is the violation, and this knob
# exists to model a node that speculates on more traffic.
TXSACTIVE_EXTEND_C = 32
COMPLETION_C = "CHI_COMPLETION_FOLLOWS_REQ"
REUSE_REQUESTER_C = "CHI_TXNID_REUSE_REQUESTER"
REUSE_COMPLETER_C = "CHI_TXNID_REUSE_COMPLETER"
# One report, on the second of the two flits. Not "at least one": more would mean
# the rule is also firing on the compliant traffic that brought the link up.
EXPECTED_REUSE_C = 1


class tc_chi_e_write_unique_zero_negctl(chi_e_base_test):

  # The injected requests are completed by this test, not by the responder, so the
  # scoreboard sees flits it never paired. That is correct of the scoreboard and
  # beside the point here: this test is a guard on two SVA rules.
  def configure_tb_cfg(self):
    super().configure_tb_cfg()
    self.tb_cfg.scoreboard_enable = False
    self.tb_cfg.txsactive_extend_max_cycles = TXSACTIVE_EXTEND_C

  # The driver half of the same hold. tb_cfg reaches the checkers; the agent cfg
  # reaches the RN-I that drives the wire, and both have to agree or the checker
  # would judge a window the driver never drove.
  def configure(self, rni_cfg, snf_cfg):
    super().configure(rni_cfg, snf_cfg)
    rni_cfg.txsactive_extend_max_cycles = TXSACTIVE_EXTEND_C
    # The SN-F needs the same hold, and for a reason this testbench creates
    # rather than the VIP: a raw-injected request is one the SN-F does not
    # service, so it opens its window at capture and closes it again with
    # nothing to send, while the completion this test supplies arrives cycles
    # later. Section 14.7.2 requires the sideband to cover the gap, and the
    # checker is right to report it -- there is simply no completer here to be
    # wrong, because the test is driving both ends. Over-assertion is legal;
    # under-assertion is the violation.
    snf_cfg.txsactive_extend_max_cycles = TXSACTIVE_EXTEND_C

  # Table 2-9 marks WriteUniqueZero's ExpCompAck prohibited, so the field stays
  # zero and the flit does not trip the CompAck rules on its way past.
  def _write_unique_zero(self, txn_id: int) -> dict:
    return {
      "txnid": txn_id,
      "srcid": E_WUZ_NEGCTL_RNI_NODE_ID_C,
      "tgtid": E_WUZ_NEGCTL_SNF_NODE_ID_C,
      "opcode": int(ReqOpcode.WRITE_UNIQUE_ZERO),
      "addr": E_WUZ_NEGCTL_ADDR_C,
      "size": 6,
      # WriteUniqueZero is Snoopable only (Table 2-14), and Table 2-12 lists no
      # Snoopable row without Cacheable and EWA. A raw flit bypasses the
      # sequence's per-opcode defaults, so both fields are set here or this
      # testcase injects the exact non-conformance the two rules exist to catch.
      "snpattr": 1,
      "memattr": 0b0101,
      "ns": NON_SECURE_C,
      "allowretry": 1,
      "qos": 0x7,
    }

  # The completion the opcode takes: a combined CompDBIDResp carrying the
  # request's own TxnID. The buffer it grants goes unused because the request
  # carries no data -- the completion form is normative regardless.
  def _comp_dbid_resp(self, txn_id: int) -> dict:
    return {
      "opcode": int(RspOpcode.COMP_DBID_RESP),
      "txnid": txn_id,
      "dbid": txn_id,
      "resp": int(Resp.I),
      "resperr": int(RespErr.OKAY),
      "srcid": E_WUZ_NEGCTL_SNF_NODE_ID_C,
      "tgtid": E_WUZ_NEGCTL_RNI_NODE_ID_C,
      "qos": 0x7,
    }

  def _require_silent(self, rule: str) -> None:
    """Neither rule may have reported yet, or the counts below prove nothing."""
    rni = self.tb_env.rni_sva.fail_count.get(rule, 0)
    snf = self.tb_env.snf_sva.fail_count.get(rule, 0)
    assert rni == 0 and snf == 0, (
      f"{rule} already reported rni_e={rni} snf_e={snf} time(s) on compliant "
      f"traffic; the counts below would prove nothing")

  async def _inject_req(self, *txn_ids: int) -> None:
    seq = vip_chi_raw_seq("rni_raw_seq", cfg=self.chi_cfg)
    seq.reset()
    for txn_id in txn_ids:
      seq.add_raw_req(self._write_unique_zero(txn_id))
    await seq.start(self.tb_env.rni_agent.sequencer)

  async def _inject_completion(self, txn_id: int) -> None:
    seq = vip_chi_raw_seq("snf_raw_seq", cfg=self.chi_cfg)
    seq.reset()
    seq.add_raw_rsp(self._comp_dbid_resp(txn_id))
    await seq.start(self.tb_env.snf_agent.sequencer)

  async def run_phase(self):
    self.raise_objection()

    rni_sva, snf_sva = self.tb_env.rni_sva, self.tb_env.snf_sva

    # Compliant traffic first: it brings the link to RUN and puts a request and
    # its completion past both rules, so the silence asserted below is a statement
    # about compliant flits rather than about an idle link.
    wr = self.rni_wr_seq
    wr.reset()
    wr.set_requests(1)
    wr.set_initial_addr(E_WUZ_NEGCTL_ADDR_C)
    wr.set_size(6)
    wr.set_get_response(True)
    wr.set_verbose(False)
    await wr.start(self.tb_env.rni_agent.sequencer)

    await self.wait_clocks(4)
    self.drain_observation_fifos()

    for rule in (REUSE_REQUESTER_C, REUSE_COMPLETER_C, COMPLETION_C):
      self._require_silent(rule)

    completion_pass_before = (rni_sva.pass_count.get(COMPLETION_C, 0),
                              snf_sva.pass_count.get(COMPLETION_C, 0))

    # -- Phase A: a WriteUniqueZero that completes. ---------------------------
    await self._inject_req(E_WUZ_NEGCTL_TXN_ID_PASS_C)
    await self.wait_clocks(4)
    await self._inject_completion(E_WUZ_NEGCTL_TXN_ID_PASS_C)
    await self.wait_clocks(SETTLE_C)

    completion_pass_after = (rni_sva.pass_count.get(COMPLETION_C, 0),
                             snf_sva.pass_count.get(COMPLETION_C, 0))

    # Both ends. The rule is asserted twice under one name -- the requester's own
    # txreq against the rxrsp it receives, and the completer's rxreq against the
    # txrsp it drives -- and a link may carry a bind at only one end.
    assert (completion_pass_after[0] > completion_pass_before[0] and
            completion_pass_after[1] > completion_pass_before[1]), (
      f"{COMPLETION_C} did not record a pass for WriteUniqueZero: "
      f"rni_e {completion_pass_before[0]} -> {completion_pass_after[0]}, "
      f"snf_e {completion_pass_before[1]} -> {completion_pass_after[1]}. "
      f"The opcode is not reaching the rule")

    for rule in (COMPLETION_C, REUSE_REQUESTER_C, REUSE_COMPLETER_C):
      self._require_silent(rule)

    # -- Phase B: a WriteUniqueZero that reuses a live TxnID. -----------------
    #
    # Suppress the report, keep the count, at both ends, because both are about to
    # be made to fail.
    rni_sva.off_check(REUSE_REQUESTER_C)
    snf_sva.off_check(REUSE_COMPLETER_C)

    await self._inject_req(E_WUZ_NEGCTL_TXN_ID_DUP_C, E_WUZ_NEGCTL_TXN_ID_DUP_C)
    await self.wait_clocks(4)

    # One completion retires both, since both name the same TxnID -- which is the
    # violation. The completion rule stays quiet either way, and that is asserted
    # below so a timeout cannot be mistaken for the reuse report.
    await self._inject_completion(E_WUZ_NEGCTL_TXN_ID_DUP_C)
    await self.wait_clocks(SETTLE_C)

    reuse_rni = rni_sva.fail_count.get(REUSE_REQUESTER_C, 0)
    reuse_snf = snf_sva.fail_count.get(REUSE_COMPLETER_C, 0)

    assert reuse_rni == EXPECTED_REUSE_C, (
      f"{REUSE_REQUESTER_C} reported {reuse_rni} time(s) at the RN-I against "
      f"exactly {EXPECTED_REUSE_C} duplicate WriteUniqueZero; below means the "
      f"opcode is not reaching the rule, above means it is firing on compliant "
      f"traffic")
    assert reuse_snf == EXPECTED_REUSE_C, (
      f"{REUSE_COMPLETER_C} reported {reuse_snf} time(s) at the SN-F against "
      f"exactly {EXPECTED_REUSE_C} duplicate WriteUniqueZero; the receiving "
      f"vantage of the rule is not doing its half")

    self._require_silent(COMPLETION_C)

    self.logger.info(
      f"Test (tc_chi_e_write_unique_zero_negctl) PASS: WriteUniqueZero completed "
      f"once under {COMPLETION_C} and reused a live TxnID once under "
      f"{REUSE_REQUESTER_C} / {REUSE_COMPLETER_C}, reported {reuse_rni} time(s) "
      f"at each end")

    self.drop_objection()
