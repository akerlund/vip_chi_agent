################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM/cocotb port of tc/tc_chi_comp_dbid_negctl.sv.
#
# IHI 0050 E section 2.5 / D section 2.5:
#
#   "A Comp response message sent separate from a DBIDResp or DBIDRespOrd
#    message for a Write transaction must include the same DBID field value."
#
# and, two lines later, the exemption that has to be built in rather than
# retrofitted: for Atomic transactions the same equality is "permitted, but is
# not required". A rule written for writes and applied to atomics would
# false-fail a conformant completer, so the exemption gets a phase of its own.
#
#   phase A  a split response whose Comp CARRIES the granted DBID. Must pass,
#            and must RECORD a pass -- the rule arms only on a separate grant,
#            so silence here would mean it never evaluated.
#   phase B  a split response whose Comp carries a different DBID. Must report
#            exactly once at each end.
#   phase C  a real ATOMIC, serviced by the SN-F's own responder, which splits
#            its response exactly as a conformant completer does. The rule must
#            neither FAIL nor PASS: the exemption means it does not evaluate,
#            and a rule that evaluated and held would record a pass.
#
# Phase C is why this test is three phases rather than two. A rule can be
# perfectly right about writes and still be wrong, and the wrongness only shows
# on traffic a conformant completer is allowed to produce.
#
# The PASS count is what makes phase C discriminating, and it is worth being
# explicit about why. The SN-F's own atomic completion carries MATCHING DBIDs,
# because the SN-F is conformant. So with the exemption removed the rule would
# not fail there -- it would quietly record a pass. Asserting only "no new
# failure" would therefore pass with the exemption deleted, and prove nothing.
#
# Phases A and B use raw injection, because no completer here splits a response
# with a renumbered DBID and correctly so -- that is the point of a negative
# control. Phase C uses the real responder, because what it needs is a
# CONFORMANT atomic and the SN-F already drives one.
#
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import ReqOpcode, Resp, RespErr, RspOpcode
from chi_e_base_test import chi_e_base_test
from vip_chi_atomic_seq import vip_chi_atomic_seq
from vip_chi_raw_seq import vip_chi_raw_seq
from chi_tb_pkg import (ATOMIC_ADDR_C, COMP_DBID_GRANTED_C, COMP_DBID_OTHER_C,
                        COMP_DBID_TXN_ID_FAIL_C, COMP_DBID_TXN_ID_PASS_C,
                        E_WUZ_NEGCTL_ADDR_C, E_WUZ_NEGCTL_RNI_NODE_ID_C,
                        E_WUZ_NEGCTL_SNF_NODE_ID_C)

NON_SECURE_C = 1
SETTLE_C = 40
TXSACTIVE_EXTEND_C = 48
RULE_C = "CHI_COMP_DBID_MATCHES_GRANT"
# AtomicStore returns no data, so phase C does not also have to satisfy
# CHI_ATOMIC_RETURN_USES_DAT_COMPLETION.
ATOMIC_OP_C = 0
# One report, on phase B alone.
EXPECTED_FAIL_C = 1


class tc_chi_comp_dbid_negctl(chi_e_base_test):

  def configure_tb_cfg(self):
    super().configure_tb_cfg()
    # The injected transactions are completed by this test, not by the
    # responder, so the scoreboard sees flits it never paired.
    self.tb_cfg.scoreboard_enable = False
    self.tb_cfg.txsactive_extend_max_cycles = TXSACTIVE_EXTEND_C

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
    # Phase C needs the SN-F to SPLIT its atomic response, because a combined
    # CompDBIDResp carries the only DBID the transaction has and cannot
    # disagree with anything -- the rule would never arm and the phase would
    # prove nothing. With this set the SN-F drives DBIDResp then Comp, both
    # carrying the request's TxnID as DBID, which is exactly the conformant
    # split the exemption has to stay quiet about.
    snf_cfg.split_write_rsp = True

  def _req(self, opcode: int, txn_id: int, size: int, snpattr: int,
           memattr: int) -> dict:
    return {
      "txnid": txn_id,
      "srcid": E_WUZ_NEGCTL_RNI_NODE_ID_C,
      "tgtid": E_WUZ_NEGCTL_SNF_NODE_ID_C,
      "opcode": opcode,
      "addr": E_WUZ_NEGCTL_ADDR_C,
      "size": size,
      "snpattr": snpattr,
      "memattr": memattr,
      "ns": NON_SECURE_C,
      "allowretry": 1,
      "qos": 0x7,
    }

  def _write_unique_zero(self, txn_id: int) -> dict:
    # Snoopable only (Table 2-14), and Table 2-12 lists no Snoopable row without
    # Cacheable and EWA.
    return self._req(int(ReqOpcode.WRITE_UNIQUE_ZERO), txn_id, 6, 1, 0b0101)

  def _rsp(self, opcode: int, txn_id: int, dbid: int) -> dict:
    return {
      "opcode": opcode,
      "txnid": txn_id,
      "dbid": dbid,
      "resp": int(Resp.I),
      "resperr": int(RespErr.OKAY),
      "srcid": E_WUZ_NEGCTL_SNF_NODE_ID_C,
      "tgtid": E_WUZ_NEGCTL_RNI_NODE_ID_C,
      "qos": 0x7,
    }

  def _counts(self) -> tuple[int, int]:
    return (self.tb_env.rni_sva.fail_count.get(RULE_C, 0),
            self.tb_env.snf_sva.fail_count.get(RULE_C, 0))

  def _passes(self) -> tuple[int, int]:
    return (self.tb_env.rni_sva.pass_count.get(RULE_C, 0),
            self.tb_env.snf_sva.pass_count.get(RULE_C, 0))

  async def _inject_req(self, flit: dict) -> None:
    seq = vip_chi_raw_seq("rni_raw_seq", cfg=self.chi_cfg)
    seq.reset()
    seq.add_raw_req(flit)
    await seq.start(self.tb_env.rni_agent.sequencer)
    await self.wait_clocks(4)

  async def _inject_rsp(self, flit: dict) -> None:
    seq = vip_chi_raw_seq("snf_raw_seq", cfg=self.chi_cfg)
    seq.reset()
    seq.add_raw_rsp(flit)
    await seq.start(self.tb_env.snf_agent.sequencer)
    await self.wait_clocks(4)

  # A split response: the grant first, then the completion, which is the only
  # shape in which two messages carry a DBID that could disagree.
  async def _split_response(self, txn_id: int, comp_dbid: int) -> None:
    await self._inject_rsp(
      self._rsp(int(RspOpcode.DBID_RESP), txn_id, COMP_DBID_GRANTED_C))
    await self._inject_rsp(
      self._rsp(int(RspOpcode.COMP), txn_id, comp_dbid))

  async def run_phase(self):
    self.raise_objection()

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

    fails = self._counts()
    assert fails == (0, 0), (
      f"{RULE_C} already reported rni_e={fails[0]} snf_e={fails[1]} time(s) on "
      f"compliant traffic; the counts below would prove nothing")

    # -- Phase A: the Comp carries the granted DBID. Must pass. ---------------
    pass_before = self._passes()
    await self._inject_req(self._write_unique_zero(COMP_DBID_TXN_ID_PASS_C))
    await self._split_response(COMP_DBID_TXN_ID_PASS_C, COMP_DBID_GRANTED_C)
    await self.wait_clocks(SETTLE_C)

    pass_after = self._passes()
    assert (pass_after[0] > pass_before[0] and pass_after[1] > pass_before[1]), (
      f"{RULE_C} recorded no pass for a conformant split response: "
      f"rni_e {pass_before[0]} -> {pass_after[0]}, "
      f"snf_e {pass_before[1]} -> {pass_after[1]}. The rule arms only on a "
      f"SEPARATE grant, so silence here means the grant is not reaching it")

    fails = self._counts()
    assert fails == (0, 0), (
      f"{RULE_C} reported rni_e={fails[0]} snf_e={fails[1]} on a Comp that "
      f"carried exactly the granted DBID")

    # -- Phase B: the Comp carries a different DBID. Must report. -------------
    self.tb_env.rni_sva.off_check(RULE_C)
    self.tb_env.snf_sva.off_check(RULE_C)

    await self._inject_req(self._write_unique_zero(COMP_DBID_TXN_ID_FAIL_C))
    await self._split_response(COMP_DBID_TXN_ID_FAIL_C, COMP_DBID_OTHER_C)
    await self.wait_clocks(SETTLE_C)

    fail_rni, fail_snf = self._counts()
    assert fail_rni == EXPECTED_FAIL_C, (
      f"{RULE_C} reported {fail_rni} time(s) at the RN-I against exactly "
      f"{EXPECTED_FAIL_C}; below means the mismatch is not reaching the rule, "
      f"above means it is firing on phase A as well")
    assert fail_snf == EXPECTED_FAIL_C, (
      f"{RULE_C} reported {fail_snf} time(s) at the SN-F against exactly "
      f"{EXPECTED_FAIL_C}; the sending vantage is not doing its half")

    # -- Phase C: a real ATOMIC. The rule must not evaluate at all. -----------
    pass_before = self._passes()

    atomic = vip_chi_atomic_seq("atomic_seq", cfg=self.chi_cfg)
    atomic.reset()
    atomic.set_atomic_op(ATOMIC_OP_C)
    atomic.set_requests(1)
    atomic.set_initial_addr(ATOMIC_ADDR_C)
    atomic.set_size(3)
    atomic.set_get_response(True)
    atomic.set_verbose(False)
    atomic.set_data([0x10])
    await atomic.start(self.tb_env.rni_agent.sequencer)
    await self.wait_clocks(SETTLE_C)

    after_rni, after_snf = self._counts()
    assert (after_rni == fail_rni and after_snf == fail_snf), (
      f"{RULE_C} reported on an ATOMIC transaction: rni_e {fail_rni} -> "
      f"{after_rni}, snf_e {fail_snf} -> {after_snf}. Section 2.5 makes the "
      f"DBID equality 'permitted, but is not required' for atomics, so a "
      f"completer that renumbers one is conformant and this rule is inventing "
      f"a requirement")

    pass_after = self._passes()
    assert pass_after == pass_before, (
      f"{RULE_C} EVALUATED on an ATOMIC transaction: rni_e {pass_before[0]} -> "
      f"{pass_after[0]}, snf_e {pass_before[1]} -> {pass_after[1]}. The SN-F's "
      f"own atomic completion carries matching DBIDs, so a rule without the "
      f"exemption records a pass here rather than a failure -- which is why "
      f"this assertion, and not the failure count above, is what proves the "
      f"exemption is in place")

    self.logger.info(
      f"Test (tc_chi_comp_dbid_negctl) PASS: {RULE_C} passed a matching split "
      f"response, reported {fail_rni} time(s) at each end on a mismatched one, "
      f"and neither failed nor evaluated on a conformant Atomic")

    self.drop_objection()
