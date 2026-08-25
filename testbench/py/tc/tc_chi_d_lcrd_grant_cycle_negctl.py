################################################################################
# pyUVM/cocotb port of tc/tc_chi_d_lcrd_grant_cycle_negctl.sv.
#
# Negative control for the grant-cycle L-Credit rule at the WIRE, which no
# configuration alone could reach.
#
# IHI 0050 E 14.2.1 / D 13.2.1, Note: "An L-Credit cannot be used in the cycle it
# is received." The rule judges the pair before the grant is applied and only
# with the send pool at zero, because above zero a same-cycle grant and consume
# is an ordinary pipelined link spending an earlier credit while a new one
# arrives, which the Note does not forbid.
#
# Neither end can produce the case alone: the flit and the grant that authorises
# it are driven by opposite ends of the link. So the two halves are set here on
# one agent each.
#
#   The RN-I steps around its credit manager for exactly one REQ send. That
#   manager refusing at zero is the only thing that keeps the driver off the wire
#   without permission, which is what made the rule unreachable and is also what
#   makes the underflow rule trustworthy -- so the bypass is counted rather than
#   a flag, and the driver goes back to asking immediately afterwards.
#
#   The SN-F withholds its initial REQ advertisement so the peer's pool stays at
#   zero, and draws a single grant off the first inbound REQ FLITPEND. A grant
#   drawn that way lands one cycle later, which is the cycle the announced flit
#   occupies. The withheld advertisement is released behind it, so the total
#   budget handed out over the run is unchanged and the link carries on.
#
# Both vantages must report. One end reporting alone would mean the pairing is
# only being done in one direction -- the RN-I tracks its tx_req pool against the
# inbound grant, the SN-F tracks the same wire as its rx_req pool against the
# grant it emits.
#
# CHI_LCRD_UNDERFLOW must stay SILENT throughout, and that is the sharpest thing
# this test says. A flit sent with the pool at zero looks like an underflow, but
# the shadow applies the grant before the consume, so the count goes 0 -> 1 -> 0
# and never dips. That ordering is right for the counter and is exactly what hid
# this case -- the underflow rule structurally cannot catch it, which is why the
# grant-cycle rule is not redundant with it. Left at its normal severity, so a
# report would fail the run on its own.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from chi_base_test import chi_base_test

_RULE_C = "CHI_LCRD_USED_IN_GRANT_CYCLE"
_UNDER_C = "CHI_LCRD_UNDERFLOW"
ADDR_C = 0x3F10_0000
SIZE_C = 6                      # 64 B = 4 beats on the CHI-D cut
SETTLE_C = 40
EXPECTED_FAILS_C = 1            # one uncredited send, so one report per vantage


class tc_chi_d_lcrd_grant_cycle_negctl(chi_base_test):

  # REQ only, so the other two channels stay conformant and a report from them
  # would be a separate defect rather than this stimulus.
  def configure(self, rni_cfg, snf_cfg):
    rni_cfg.req_send_without_credit_negctl = 1
    snf_cfg.req_lcrd_grant_on_flitpend_negctl = True

  async def run_phase(self):
    self.raise_objection()

    rni, snf = self.tb_env.rni_sva, self.tb_env.snf_sva

    rni.off_check(_RULE_C)
    snf.off_check(_RULE_C)

    await self.wait_clocks(SETTLE_C)

    # Nothing may have fired yet: no REQ flit has been sent, so the withheld
    # advertisement on its own must be silent.
    assert rni.fail_count.get(_RULE_C, 0) == 0, (
      f"{_RULE_C} reported before any REQ flit was sent; withholding an "
      f"advertisement is not the violation")

    rd = self.rni0_rd_seq
    rd.reset()
    rd.set_requests(1)
    rd.set_initial_addr(ADDR_C)
    rd.set_size(SIZE_C)
    rd.set_get_response(True)
    rd.set_verbose(False)
    await rd.start(self.v_sqr.rni_sequencer)

    await self.wait_clocks(SETTLE_C)

    rni_fails = rni.fail_count.get(_RULE_C, 0)
    snf_fails = snf.fail_count.get(_RULE_C, 0)
    rni_under = rni.fail_count.get(_UNDER_C, 0)
    snf_under = snf.fail_count.get(_UNDER_C, 0)
    rni_passes = rni.pass_count.get(_RULE_C, 0)

    assert rni_passes > 0, (
      f"{_RULE_C} recorded no passes at all; the credit accounting is not "
      f"running and the counts below would mean nothing")

    assert rni_fails == EXPECTED_FAILS_C, (
      f"{_RULE_C} reported {rni_fails} time(s) at the RN-I against one "
      f"uncredited send, expected exactly {EXPECTED_FAILS_C}; zero means the "
      f"grant did not land in the flit's own cycle, above means the rule is "
      f"also flagging credited traffic")

    assert snf_fails == EXPECTED_FAILS_C, (
      f"{_RULE_C} reported {snf_fails} time(s) at the SN-F, expected exactly "
      f"{EXPECTED_FAILS_C}; the granting vantage is not pairing its own grant "
      f"with the flit it authorises")

    assert rni_under == 0 and snf_under == 0, (
      f"{_UNDER_C} reported {rni_under} time(s) at the RN-I and {snf_under} at "
      f"the SN-F, expected silence at both; the shadow applies the grant before "
      f"the consume, so the count goes 0 -> 1 -> 0 and never dips -- a report "
      f"here would mean the two rules are judging the same thing twice")

    # The link must still work on the credits it legally has, and the released
    # advertisement must not read as a further violation.
    rd.reset()
    rd.set_requests(4)
    rd.set_initial_addr(ADDR_C)
    rd.set_size(SIZE_C)
    rd.set_get_response(True)
    rd.set_verbose(False)
    await rd.start(self.v_sqr.rni_sequencer)

    await self.wait_clocks(SETTLE_C)

    assert (rni.fail_count.get(_RULE_C, 0) == EXPECTED_FAILS_C and
            snf.fail_count.get(_RULE_C, 0) == EXPECTED_FAILS_C), (
      f"{_RULE_C} kept firing on credited traffic after the uncredited send; "
      f"without its at-zero bound the rule fires on every busy cycle of every "
      f"run")

    assert (rni.fail_count.get(_UNDER_C, 0) == 0 and
            snf.fail_count.get(_UNDER_C, 0) == 0), (
      f"{_UNDER_C} reported on the credited traffic that followed")

    self.logger.info(
      f"Test (tc_chi_d_lcrd_grant_cycle_negctl) PASS: a REQ flit sent in the "
      f"cycle its only L-credit was granted was reported once at each vantage "
      f"({rni_passes} credited pairs passed first) with {_UNDER_C} silent "
      f"throughout, and the link then carried four reads to completion")
    self.drop_objection()
