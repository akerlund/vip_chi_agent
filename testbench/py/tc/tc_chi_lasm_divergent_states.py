################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# The two link state machines standing in DIFFERENT states in the same cycle,
# and the transition rule required to stay SILENT through it.
#
# IHI 0050 E section 14.6.1 / D 13.6.1 defines a transmit machine and a receive
# machine per interface -- section 14.5.1: "two signals are used for all the
# transmit channels and two signals are used for all the receive channels" --
# and section 14.6.2 says Figure 14-5 "is formatted so that the independent
# nature of the Tx and Rx state machines can be seen". They activate, run and
# tear down on their own schedules, so a component whose transmit link is RUN
# while its receive link is still ACTIVATE is conformant, not broken.
#
# This is the case the checker could not represent while the four sideband
# signals were OR-collapsed into one state: TxRun/RxAct and TxAct/RxRun both
# computed req=1, ack=1 and aliased onto RUN, and a peer advancing the two
# machines in one cycle could move the collapsed state two places and be
# REPORTED for a legal step. A false failure against conformant hardware.
#
# So this is a control on silence, which needs its provocation asserted or it
# proves nothing. cfg.lasm_stall_activation_cycles holds the completer's own
# request and acknowledge back for a while after the requester has asked, which
# drives the two machines apart at both endpoints: the requester sits with its
# transmit link waiting while its receive link has not been asked for yet, and
# passes through TxRun/RxAct as the stall ends. lasm_divergent_cycles counts the
# cycles where they really did differ, and a run where it stayed zero would mean
# the stimulus never reached the case whatever the rule then said.
#
# The stall is well inside any bound: link_activation_timeout_cycles defaults to
# 0, which disables the timeout, so this test is about the transition rule alone
# and does not smuggle in a timing claim.
#
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from chi_base_test import chi_base_test

_STEP_RULE_C = "CHI_LASM_LEGAL_TRANSITION"
_ACTIVATE_RULE_C = "CHI_LASM_ACTIVATE_OBSERVED"
STALL_C = 12
ADDR_C = 0x3D50_0000
SIZE_C = 6
SETTLE_C = 20


class tc_chi_lasm_divergent_states(chi_base_test):

  def configure(self, rni_cfg, snf_cfg):
    snf_cfg.lasm_stall_activation_cycles = STALL_C

  async def run_phase(self):
    self.raise_objection()

    rni = self.tb_env.rni_sva
    snf = self.tb_env.snf_sva

    # Ordinary traffic over the link the stall delayed. It has to complete: a
    # link that never came up would also report no illegal transitions, and the
    # silence below would be silence about nothing.
    rd = self.rni0_rd_seq
    rd.reset()
    rd.set_requests(1)
    rd.set_initial_addr(ADDR_C)
    rd.set_size(SIZE_C)
    rd.set_get_response(True)
    rd.set_verbose(False)
    await rd.start(self.v_sqr.rni_sequencer)

    await self.wait_clocks(SETTLE_C)

    # The provocation, asserted before the silence it qualifies. Both endpoints,
    # because both own two machines and the stall separates them at each: a
    # divergence at one end only would mean one side is still deriving both
    # machines from the same pair of signals.
    assert rni.lasm_divergent_cycles > 0, (
      f"the requester's two link machines never differed, so the stall did not "
      f"separate them and the transition rule was never asked the question this "
      f"test exists to ask")
    assert snf.lasm_divergent_cycles > 0, (
      f"the completer's two link machines never differed, so the stall did not "
      f"separate them and the transition rule was never asked the question this "
      f"test exists to ask")

    # ...and the silence itself. Each machine walked its own axis, so neither
    # may have been reported -- a report here is the false failure against
    # conformant hardware that the OR-collapse produced.
    for name, checker in (("RN-I", rni), ("SN-F", snf)):
      fails = checker.fail_count.get(_STEP_RULE_C, 0)
      assert fails == 0, (
        f"the {name} checker reported {fails} illegal LASM transition(s) while "
        f"its two machines were legitimately in different states. Each machine "
        f"moves on its own axis; reporting one for the other's step is a false "
        f"failure against a conformant peer")

      # The companion claim, which a divergence must not break either: both
      # machines still went up THROUGH ACTIVATE.
      missed = checker.fail_count.get(_ACTIVATE_RULE_C, 0)
      assert missed == 0, (
        f"the {name} checker reported {missed} activation(s) that skipped "
        f"ACTIVATE while the two machines were apart")

    assert rni.errors == 0 and snf.errors == 0, (
      f"checkers reported {rni.errors} (RN-I) / {snf.errors} (SN-F) violation(s) "
      f"on a stalled but entirely legal bring-up")

    # The rule was live, not merely quiet: it recorded legal steps on the same run.
    assert rni.pass_count.get(_STEP_RULE_C, 0) > 0, (
      "the transition rule recorded no legal steps at all, so its zero above is "
      "the zero of a rule that never ran")

    self.logger.info(
      f"Test (tc_chi_lasm_divergent_states) PASS: the two machines stood apart "
      f"for {rni.lasm_divergent_cycles} (RN-I) / {snf.lasm_divergent_cycles} "
      f"(SN-F) cycle(s), no step was reported, and a read completed over the "
      f"link")

    self.drop_objection()
