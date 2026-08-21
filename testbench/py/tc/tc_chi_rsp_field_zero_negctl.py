################################################################################
# pyUVM/cocotb port of tc/tc_chi_rsp_field_zero_negctl.sv.
#
# A negative control for CHI_RSP_FIELD_ZERO, the Appendix A Table A-4 rule that
# says a field the table marks `0` or `0 a` must be driven zero.
#
# The rule was written AFTER the two defects it would have caught were already
# fixed -- Persist carrying the request's TxnID, and a bare DBIDResp carrying the
# completion's RespErr. So it passes on every existing testcase, and a rule that
# only ever passes is indistinguishable from a rule that cannot fail. This test
# supplies the missing half: three flits that violate it, one per field.
#
# PCrdGrant is the vehicle for all four because Table A-4 marks all four of its
# fields zero at once -- TxnID `0 a`, RespErr `0`, Resp `0 a`, and a `0 a`
# centred across the shared DBID field -- so one opcode exercises the whole
# predicate, and the raw-inject path already used by
# tc_chi_pcrd_leak and tc_chi_pcrd_return can put an arbitrary flit on the wire
# without teaching a driver to misbehave.
#
# What is asserted, in order of what would otherwise go unnoticed:
#
#   * the count is zero BEFORE the injection. Without this the test proves only
#     that the rule fires somewhere, not that these flits are what moved it.
#   * exactly four reports, not "at least four". Fewer means a field is not
#     covered; more means the rule is also firing on the well-formed traffic that
#     brought the link up, which would make it useless in an ordinary run.
#   * four at BOTH ends of the link. The rule is checked in both directions
#     under one ID, txrsp at the SN-F that drove the flits and rxrsp at the RN-I
#     that received them, and a link may carry a checker at only one end.
#     Checking one vantage would leave the other silently untested -- which is
#     the shape of defect this whole family of rules exists to stop.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Resp, RespErr, RspOpcode
from chi_base_test import chi_base_test, WRITE_READ_ADDR_C
from vip_chi_raw_seq import vip_chi_raw_seq
from chi_tb_pkg import RNI_NODE_ID_C, SNF_NODE_ID_C

_CHK_C = "CHI_RSP_FIELD_ZERO"

PCRD_TYPE_C = 0x3
SETTLE_C = 20
# One violating flit per zero-marked field of PCrdGrant.
EXPECTED_C = 4


def _legal_pcrd_grant() -> dict:
  """One well-formed PCrdGrant field set, to be corrupted one field at a time."""
  return {
    "dbid": 0, "fwdstate": 0,
    "resp": int(Resp.I), "resperr": int(RespErr.OKAY),
    "opcode": int(RspOpcode.PCRD_GRANT), "txnid": 0,
    "pcrdtype": PCRD_TYPE_C,
    "srcid": SNF_NODE_ID_C, "tgtid": RNI_NODE_ID_C, "qos": 0x0,
  }


class tc_chi_rsp_field_zero_negctl(chi_base_test):

  def configure_tb_cfg(self):
    # The injected grants bounce nothing, so the scoreboard opens a context for
    # each that never completes and reports the stray flits as incomplete
    # transactions. That is correct of the scoreboard and beside the point here:
    # this test is a guard on one checker rule.
    self.tb_cfg.scoreboard_enable = False

  def configure(self, rni_cfg, snf_cfg):
    # The four injected grants bounce nothing, so without this they sit in the
    # requester's bank and the RN-I driver reports four leaked P-credits at end
    # of test -- a correct report about a real leak, and nothing to do with the
    # rule under test. Handing them back is the honest way to silence it:
    # tc_chi_pcrd_leak already covers the leak itself, and only the pipelined
    # path banks a credit at all.
    rni_cfg.multi_outstanding = True
    rni_cfg.return_unused_pcrd = True

  # The checkers exist by connect_phase and the violating flits go out in
  # run_phase, so this is early enough to declare the waivers and late enough for
  # the checkers to be there. Both ends: the rule runs at both and both are about
  # to be made to fail.
  def connect_phase(self):
    super().connect_phase()
    for checker in (self.tb_env.rni_sva, self.tb_env.snf_sva):
      checker.expect_failure(_CHK_C)

  async def run_phase(self):
    self.raise_objection()

    rni = self.tb_env.rni_sva
    snf = self.tb_env.snf_sva

    # Ordinary traffic first, to bring the link to RUN and to put a good
    # CompDBIDResp and DBIDResp past the rule. Those opcodes are in its opcode
    # set too, so this is also what proves the rule does not fire on compliant
    # flits -- the zero-before assertion below is exactly that statement.
    wr = self.rni0_wr_seq
    wr.reset()
    wr.set_requests(1)
    wr.set_initial_addr(WRITE_READ_ADDR_C)
    wr.set_size(6)
    wr.set_get_response(True)
    wr.set_verbose(False)
    await wr.start(self.v_sqr.rni_sequencer)

    await self.wait_clocks(4)
    self.drain_observation_fifos()

    rni_before = rni.fail_count.get(_CHK_C, 0)
    snf_before = snf.fail_count.get(_CHK_C, 0)
    assert (rni_before == 0) and (snf_before == 0), (
      f"{_CHK_C} already reported {rni_before}/{snf_before} time(s) on "
      f"compliant traffic; the counts below would prove nothing")

    # Table A-4 PCrdGrant: TxnID = 0 a.
    bad_txnid = _legal_pcrd_grant()
    bad_txnid["txnid"] = 0x5A

    # Table A-4 PCrdGrant: RespErr = 0. DERR is a legal RespErr encoding on the
    # responses that carry one, which is the point -- the field is well-formed
    # and still illegal here, so this fails on applicability, not on encoding.
    bad_resperr = _legal_pcrd_grant()
    bad_resperr["resperr"] = int(RespErr.DERR)

    # Table A-4 PCrdGrant: Resp = 0 a.
    bad_resp = _legal_pcrd_grant()
    bad_resp["resp"] = int(Resp.UC)

    # Table A-4 PCrdGrant: the shared DBID/TagGroupID/StashGroupID/PGroupID
    # field is 0 a. A grant that names a buffer is the mistake this catches --
    # PCrdGrant reserves a retry slot, not a write buffer.
    bad_dbid = _legal_pcrd_grant()
    bad_dbid["dbid"] = 0x1D

    snf_raw_seq = vip_chi_raw_seq("snf_raw_seq", cfg=self.chi_cfg)
    snf_raw_seq.reset()
    snf_raw_seq.add_raw_rsp(bad_txnid)
    snf_raw_seq.add_raw_rsp(bad_resperr)
    snf_raw_seq.add_raw_rsp(bad_resp)
    snf_raw_seq.add_raw_rsp(bad_dbid)
    await snf_raw_seq.start(self.v_sqr.snf_sequencer)

    await self.wait_clocks(SETTLE_C)

    snf_fails = snf.fail_count.get(_CHK_C, 0)
    rni_fails = rni.fail_count.get(_CHK_C, 0)

    assert snf_fails == EXPECTED_C, (
      f"{_CHK_C} reported {snf_fails} time(s) at the SN-F (txrsp) against "
      f"exactly {EXPECTED_C} violating flits; below means a field is "
      f"uncovered, above means it is firing on compliant traffic")
    assert rni_fails == EXPECTED_C, (
      f"{_CHK_C} reported {rni_fails} time(s) at the RN-I (rxrsp) against "
      f"exactly {EXPECTED_C} violating flits; the receiving vantage of the "
      f"rule is not doing its half")

    self.logger.info(
      f"Test (tc_chi_rsp_field_zero_negctl) PASS: {_CHK_C} fired "
      f"{rni_fails} time(s) at each end of the link, as intended")
    self.drop_objection()
