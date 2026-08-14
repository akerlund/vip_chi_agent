################################################################################
# pyUVM/cocotb port of tc/tc_chi_flitpend_without_valid.sv.
#
# Negative control for the two FLITPEND rules, which no other test could reach.
#
# CHI_REQ_PEND_REQUIRES_VALID and CHI_RSP_PEND_REQUIRES_VALID were never
# exercised anywhere in either regression, and the reason was simply that
# nothing ever raised FLITPEND on those two channels: the drivers pair it with
# the flit it belongs to, and only the DAT burst has a use for it (raised on
# every beat but the last, meaning "more beats coming"), which is why the DAT
# twin of this rule was the only one of the three ever evaluated.
#
# So this is a rule that had never once run. That is indistinguishable from a
# rule that does not work, and the whole point of the vacuity report is to say
# so rather than let a clean regression imply otherwise.
#
# What the rule polices is a VIP EMISSION CONVENTION, not a CHI mandate, and the
# distinction is worth stating because it changes what a failure means. CHI's
# FLITPEND is a one-cycle-ahead hint that a flit MIGHT follow, and a transmitter
# is permitted to assert it and then not send -- discouraged, but legal. This
# VIP emits FLITPEND alongside its flit, so a lone FLITPEND means a driver has
# lost track of its own burst. Same standing as the DataID-ordering rules, which
# hold this VIP's in-order emission convention rather than a CHI requirement.
#
# cfg.flitpend_without_valid pulses FLITPEND on REQ and RSP for one cycle with
# no flit behind it, once, after the link is up. Both halves are asserted:
#   * each rule must report exactly once -- one lone FLITPEND per channel;
#   * ordinary traffic afterwards must complete and must not add reports, or the
#     rules would be firing on well-formed flits too.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from chi_base_test import chi_base_test

_REQ_C = "CHI_REQ_PEND_REQUIRES_VALID"
_RSP_C = "CHI_RSP_PEND_REQUIRES_VALID"

ADDR_C = 0x3E00_0000
SIZE_C = 6                      # 64 B = 4 beats on the CHI-D cut
SETTLE_C = 20


class tc_chi_flitpend_without_valid(chi_base_test):

  def configure(self, rni_cfg, snf_cfg):
    rni_cfg.flitpend_without_valid = True

  # The checkers exist by connect_phase and the pulse happens during link
  # bring-up in run_phase, so this is early enough to declare the waivers and
  # late enough for the checkers to be there.
  def connect_phase(self):
    super().connect_phase()
    for checker in (self.tb_env.rni_sva, self.tb_env.snf_sva):
      checker.expect_failure(_REQ_C)
      checker.expect_failure(_RSP_C)

  async def run_phase(self):
    self.raise_objection()

    rni = self.tb_env.rni_sva

    # A write, not a read: the requester transmits a REQ flit and then the
    # WriteData beats, so the rules see well-formed FLITPEND on two channels
    # after the deliberately malformed pulse. A read would leave the RSP side
    # untouched and the second assertion below would prove nothing.
    wr = self.rni0_wr_seq
    wr.reset()
    wr.set_requests(1)
    wr.set_initial_addr(ADDR_C)
    wr.set_size(SIZE_C)
    wr.set_exp_comp_ack(True)
    wr.set_allow_retry(0)
    wr.set_get_response(True)
    wr.set_verbose(False)
    await wr.start(self.v_sqr.rni_sequencer)

    await self.wait_clocks(SETTLE_C)

    req_fails = rni.fail_count.get(_REQ_C, 0)
    rsp_fails = rni.fail_count.get(_RSP_C, 0)

    # One lone FLITPEND per channel, so exactly one report per channel. Fewer
    # means the rule never fired and is still vacuous; more means it is also
    # firing on the well-formed FLITPEND the write's own flits carry, which
    # would make it useless in an ordinary run.
    assert req_fails == 1, (
      f"{_REQ_C} reported {req_fails} time(s) against exactly one lone "
      f"FLITPEND; it is vacuous at 0 and firing on well-formed flits above 1")
    assert rsp_fails == 1, (
      f"{_RSP_C} reported {rsp_fails} time(s) against exactly one lone "
      f"FLITPEND; it is vacuous at 0 and firing on well-formed flits above 1")

    # And the traffic that followed still has to have gone through, or the
    # control would have broken the link rather than exercised a rule.
    assert rni.pass_count.get("CHI_DAT_PEND_REQUIRES_VALID", 0) > 0, (
      "the write drove no well-formed DAT FLITPEND, so this run says nothing "
      "about the rules holding on ordinary traffic")

    self.logger.info(
      f"Test (tc_chi_flitpend_without_valid) PASS: one lone FLITPEND on each of "
      f"REQ and RSP was reported exactly once per channel, and the write that "
      f"followed completed without adding a report")
    self.drop_objection()
