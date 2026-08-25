################################################################################
# pyUVM port of tc/chi_coh_expcompack_negctl_base_test.sv.
#
# Negative control for CHI_EXPCOMPACK_REQUIRED_BUT_ZERO.
#
# IHI 0050 E Table 2-9 / D Table 2-8 mark six RN-F request types "Yes" in the
# CompAck column, and section 2.8.3 states it without a table: "An RN-F must
# include a CompAck response in all Read transactions except ReadNoSnp and
# ReadOnce*." A ReadShared with ExpCompAck = 0 is therefore a non-conformant
# request -- and it is the request this VIP issued, on every coherent read, for
# the whole life of the model, because the item's legality constraint forced the
# bit to zero on every read direction.
#
# The converse has been checked since the first cut: COMPACK_WITHOUT_EXPCOMPACK
# catches a CompAck for a request that never asked for one. Nobody wrote the
# other direction, and the reason is instructive -- the constraint made it
# unreachable, so a rule against it would have been dead code in every run.
#
# cfg.rn_drop_required_exp_comp_ack clears the bit on the ITEM, not just on the
# outgoing flit. That keeps the requester self-consistent: it sends a zero and
# then does not send a CompAck, so exactly one rule can fire. Clearing only the
# flit field would leave the driver acking a request the wire says wanted no ack,
# which trips COMPACK_WITHOUT_EXPCOMPACK as well -- and a control that breaks two
# rules at once cannot show which of them is being exercised.
#
# Only the requester vantage is asserted, and that is a fact about this testbench
# rather than about the rule: the coherent link carries the main bind at the RN-F
# ends only, so there is no completer-side counter here to read.
################################################################################

from __future__ import annotations

from chi_coherent_base_test import chi_coherent_base_test

_CHK_C = "CHI_EXPCOMPACK_REQUIRED_BUT_ZERO"
_ACK_CHK_C = "CHI_COMPACK_WITHOUT_EXPCOMPACK"
_SETTLE_C = 20


class chi_coh_expcompack_negctl_base_test(chi_coherent_base_test):

  def configure_agent_cfgs(self):
    self.hrnf0_cfg.rn_drop_required_exp_comp_ack = True

  # The checkers exist by connect_phase and the violating flit goes out in
  # run_phase, so this is early enough to declare the waiver and late enough for
  # the checker to be there.
  def connect_phase(self):
    super().connect_phase()
    # Both ends of the link. The deliberate ExpCompAck = 0 travels from the RN-F
    # to the HN-F, so it is judged twice under one rule name: once where it is
    # sent and once where it arrives. Waiving it only at the sender left the
    # receiving vantage reporting a violation this test asked for, the moment
    # gave the HN-F endpoint a main-range bind.
    self.tb_env.rnf_sva[0].expect_failure(_CHK_C)
    for checker in self.tb_env.hnfr_sva:
      checker.expect_failure(_CHK_C)

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    rnf = self.tb_env.rnf_sva[0]

    self.cfg_read_seq(self.hrnf0_rdshared_seq)
    await self.hrnf0_rdshared_seq.start(self.tb_env.hrnf0_agent.sequencer)
    self.hrnf0_rdshared_seq.get_responses()

    await self.wait_clocks(_SETTLE_C)

    rnf_fails = rnf.fail_count.get(_CHK_C, 0)
    assert rnf_fails > 0, (
      f"{_CHK_C} did not report a ReadShared issued with ExpCompAck = 0 -- "
      f"Table 2-9 marks it required")

    # The requester stayed consistent with the zero it sent, so the CompAck rules
    # must be silent. This is what separates "the bit was wrong" from "the whole
    # handshake fell apart", and it is the half that keeps this control pointed at
    # one rule.
    assert rnf.fail_count.get(_ACK_CHK_C, 0) == 0, (
      f"{_ACK_CHK_C} also reported: the requester acked a request whose wire bit "
      f"it had cleared, so this control is exercising two rules at once")

    assert self.tb_env.coh_checker.get_comp_ack_window_count() == 0, (
      "a CompAck window opened for a request that carried no ExpCompAck; rule D9 "
      "is arming off something other than the wire bit")

    self.logger.info(
      f"Test (coh_expcompack_negctl) PASS: {_CHK_C} reported {rnf_fails} time(s) "
      f"at the requester, and no CompAck rule fired alongside it")
    self.drop_objection()
