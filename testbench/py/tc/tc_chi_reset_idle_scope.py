################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full Apache-2.0 notice.
#
################################################################################
#
# pyUVM/cocotb port of tc/tc_chi_reset_idle_scope.sv.
#
# Both sides of a CLOSED list. E section 14.1.3 / D section 13.1.3:
#
#   "During reset the following interface signals must be deasserted by the
#    component:  TX***LCRDV.  TX***FLITV.  TXLINKACTIVEREQ and
#    RXLINKACTIVEACK. [...] All other signals can be any value."
#
# Four items, then a sentence that closes the set. A closed list needs two
# controls or it is not verified at all: one that drives what the closing
# sentence permits and requires SILENCE, and one that drives what the list names
# and requires a REPORT. The four rules had passes in the hundreds and ZERO
# fails across the whole regression before this testcase -- never once asked to
# fail, and two of the things they rejected were legal.
#
#   phase 1  traffic, so the reset rules arm at both binds. An unarmed rule
#            reports nothing, and nothing is indistinguishable from a pass.
#   phase 2  reset with FLITPEND on every transmitted channel and TXSACTIVE held
#            HIGH -- both outside the list and both permitted high by name
#            (section 14.4 / D 13.4 "permitted to keep the signal permanently
#            asserted"; section 14.7.2 / D 13.7.2 permits TXSACTIVE to be driven
#            straight from the RXSACTIVE input, which the closing sentence
#            leaves free during reset). Nothing may be reported, and every rule
#            must still have EVALUATED.
#   phase 3  reset with txrsplcrdv held HIGH. TX***LCRDV is the first item on
#            the list, so this must be reported, at both vantages.
#
# The RSP credit is the violation because every role here drives it, so one knob
# arms both ends.
#
# It has COLLATERAL, and that is a fact about the protocol rather than a flaw in
# the control: a credit driven through reset can still be a credit when reset
# releases, and the link is in STOP for a cycle or two before the activation
# handshake completes. So CHI_RSP_LCRDV_REQUIRES_LINK and
# CHI_LCRD_QUIESCENT_IN_STOP can see it too, and they are RIGHT to. The first
# attempt here assumed those two were gated on rst_n and invisible; they are not.
#
# WHETHER they fire is a timing detail of the flow, not a property of the
# protocol, and the two ports differ: this flow re-spawns its driver a cycle or
# two after release and both fire, while the SV flow does not trip them. So they
# are suppressed and BOUNDED ABOVE rather than required -- a stuck credit shows
# as a count that keeps climbing, which is the regression worth catching.
# Requiring them to fire would be asserting when the agent happens to re-spawn
# its driver, the same mistake as demanding an exact count in phase 3.
#
# The SV flow ALSO reports CHI_LASM_LEGAL_TRANSITION once here, and that one is a
# defect this control found rather than collateral: the completer's acknowledge
# lands on the same edge as the requester's request, so the activation handshake
# skips ACTIVATE and steps STOP -> RUN. A receiver cannot acknowledge a request
# in the cycle it first appears, so the checker is right and the driver is wrong.
# Isolated by bisection in the SV flow -- knob-free pulses either side of it walk
# STOP -> ACTIVATE -> RUN cleanly and only the pulse carrying the credit collapses
# it. This flow does not exhibit it, which is itself evidence that the bring-up
# timing is pinned down in neither port. It is suppressed and bounded in both so
# the two ports keep one shape, and it belongs to its own commit and finding.
#
# Every item on section 14.1.3's list is a signal that MEANS something, so there
# is no member of it that can be driven without collateral. A control for a
# closed list has to own that instead of choosing a signal that hides it.
#
# Phase 3's count is bounded rather than exact: the check needs rst_n low in
# this cycle and the previous one, so it cannot evaluate on the first low cycle,
# and the driver's reset hook runs an implementation-defined number of cycles
# into the window. An exact number here would be asserting when the agent's
# reset handler happens to run.
#
# The SNP twin of these rules lives only on the coherent snoop binds, so its
# control needs the HN-F/RN-F drivers rather than these two. The host already
# exists -- tc_chi_coh_{d,e}_reset_mid_snoop are the only two runs that exercise
# CHI_SNP_IDLE_IN_RESET at all -- so the work is the knobs, not the testbench.
# Open, not overlooked.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from chi_base_test import chi_base_test
from chi_tb_pkg import RESET_IDLE_ADDR_C

SIZE_C = 6
SETTLE_C = 40
# Long enough that phase 3 has several evaluations to report and phase 2 several
# to pass, short enough not to stretch the run.
RESET_CYCLES_C = 8
MAX_FAILS_C = RESET_CYCLES_C - 1

SIDEBAND_C = "CHI_LINK_SIDEBAND_IDLE_IN_RESET"
REQ_C = "CHI_REQ_IDLE_IN_RESET"
RSP_C = "CHI_RSP_IDLE_IN_RESET"
DAT_C = "CHI_DAT_IDLE_IN_RESET"
ALL_C = (SIDEBAND_C, REQ_C, RSP_C, DAT_C)
# The two rules the phase-3 credit can also trip once reset releases.
COLLATERAL_C = ("CHI_RSP_LCRDV_REQUIRES_LINK", "CHI_LCRD_QUIESCENT_IN_STOP")
# Not collateral: the collapsed activation handshake described in the header. At
# most one per release, and zero in this flow.
LASM_C = "CHI_LASM_LEGAL_TRANSITION"
LASM_CEILING_C = 1


class tc_chi_reset_idle_scope(chi_base_test):

  async def _one_write(self) -> None:
    wr = self.rni0_wr_seq
    wr.reset()
    wr.set_requests(1)
    wr.set_initial_addr(RESET_IDLE_ADDR_C)
    wr.set_size(SIZE_C)
    wr.set_get_response(True)
    wr.set_verbose(False)
    await wr.start(self.v_sqr.rni_sequencer)

  async def _one_reset_pulse(self) -> None:
    # pulse_reset, not tb_cfg.request_reset_pulse: the countdown that knob feeds
    # is consumed by the SV top's always_ff, and this flow drives rst_n from the
    # testcase instead. Same window either way -- rst_n low for
    # RESET_CYCLES_C rising edges, so the check, which needs rst_n low in this
    # sample AND the previous one, gets RESET_CYCLES_C - 1 evaluations.
    await self.pulse_reset(low_cycles=RESET_CYCLES_C)
    await self.wait_clocks(SETTLE_C)

  def _require_silent(self, rule: str, why: str) -> None:
    """Nothing may be reported, at either end."""
    rni = self.tb_env.rni_sva.fail_count.get(rule, 0)
    snf = self.tb_env.snf_sva.fail_count.get(rule, 0)
    assert rni == 0 and snf == 0, (
      f"{rule} reported rni_e={rni} snf_e={snf} time(s) on {why}, which the "
      f"specification permits")

  def _require_evaluated(self, rule: str, before: tuple) -> None:
    """The rule must have EVALUATED. Silence from a stood-down rule is not
    evidence that the traffic was accepted."""
    rni = self.tb_env.rni_sva.pass_count.get(rule, 0)
    snf = self.tb_env.snf_sva.pass_count.get(rule, 0)
    assert rni > before[0] and snf > before[1], (
      f"{rule} recorded no new evaluation across the reset window: "
      f"rni_e {before[0]} -> {rni}, snf_e {before[1]} -> {snf}. Its silence "
      f"says nothing")

  def _require_bounded(self, rule: str) -> None:
    """Collateral: bounded ABOVE only. Zero is a legitimate answer -- it means
    the credit did not outlive the release in this flow."""
    rni = self.tb_env.rni_sva.fail_count.get(rule, 0)
    snf = self.tb_env.snf_sva.fail_count.get(rule, 0)
    assert rni <= MAX_FAILS_C and snf <= MAX_FAILS_C, (
      f"{rule} reported rni_e={rni} snf_e={snf} time(s), above the "
      f"{MAX_FAILS_C} the reset window can explain. The injected credit is "
      f"outliving the release rather than being cleared when the driver "
      f"restarts")

  def _require_reported(self, rule: str) -> None:
    rni = self.tb_env.rni_sva.fail_count.get(rule, 0)
    snf = self.tb_env.snf_sva.fail_count.get(rule, 0)
    assert 1 <= rni <= MAX_FAILS_C, (
      f"{rule} reported {rni} time(s) at the RN-I against a credit driven "
      f"through reset, expected 1..{MAX_FAILS_C}; zero means TX***LCRDV is no "
      f"longer checked at all, above the bound means it is firing outside the "
      f"reset window")
    assert 1 <= snf <= MAX_FAILS_C, (
      f"{rule} reported {snf} time(s) at the SN-F, expected 1..{MAX_FAILS_C}; "
      f"the completer vantage is not judging its own outputs")

  async def run_phase(self):
    self.raise_objection()

    await self.wait_clocks(4)

    # -- Phase 1: arm the rules. ----------------------------------------------
    await self._one_write()
    await self.wait_clocks(SETTLE_C)

    before = {
      r: (self.tb_env.rni_sva.pass_count.get(r, 0),
          self.tb_env.snf_sva.pass_count.get(r, 0)) for r in ALL_C
    }

    # -- Phase 2: what the closing sentence permits. --------------------------
    #
    # Set on the cfg objects the drivers already hold: the window this arms is
    # the NEXT reset and the drivers are already built.
    self.rni_cfg.reset_permitted_high = True
    self.snf_cfg.reset_permitted_high = True

    await self._one_reset_pulse()

    self.rni_cfg.reset_permitted_high = False
    self.snf_cfg.reset_permitted_high = False

    self._require_silent(SIDEBAND_C, "TXSACTIVE held high through reset")
    self._require_silent(REQ_C, "txreqflitpend held high through reset")
    self._require_silent(RSP_C, "txrspflitpend held high through reset")
    self._require_silent(DAT_C, "txdatflitpend held high through reset")

    for rule in ALL_C:
      self._require_evaluated(rule, before[rule])

    # -- Phase 3: what the list names. ---------------------------------------
    #
    # Suppress the report, keep the count, at both ends: both are about to be
    # made to fail by the same credit.
    self.tb_env.rni_sva.off_check(RSP_C)
    self.tb_env.snf_sva.off_check(RSP_C)
    # And the two rules the same credit reaches after release. Suppressed rather
    # than tolerated, and asserted below rather than ignored.
    for rule in COLLATERAL_C + (LASM_C,):
      self.tb_env.rni_sva.off_check(rule)
      self.tb_env.snf_sva.off_check(rule)

    # The link has to carry traffic again before the second pulse: the write in
    # phase 1 is what armed the rules, and a reset takes its subject down with
    # it. This also proves the link survived phase 2.
    await self._one_write()
    await self.wait_clocks(SETTLE_C)

    self.rni_cfg.reset_idle_violation = True
    self.snf_cfg.reset_idle_violation = True

    await self._one_reset_pulse()

    self.rni_cfg.reset_idle_violation = False
    self.snf_cfg.reset_idle_violation = False

    self._require_reported(RSP_C)

    for rule in COLLATERAL_C:
      self._require_bounded(rule)

    rni = self.tb_env.rni_sva.fail_count.get(LASM_C, 0)
    snf = self.tb_env.snf_sva.fail_count.get(LASM_C, 0)
    assert rni <= LASM_CEILING_C and snf <= LASM_CEILING_C, (
      f"{LASM_C} reported rni_e={rni} snf_e={snf} time(s), above the "
      f"{LASM_CEILING_C} this testcase accounts for. The activation handshake "
      f"has broken further than the one collapsed step already recorded "
      f"against it")

    # The other three saw a conformant reset window in phase 3 and must still be
    # silent. A rule reading the RSP credit off the DAT channel would pass
    # phase 3 on its own.
    for rule in (SIDEBAND_C, REQ_C, DAT_C):
      self._require_silent(
        rule, "a reset window whose only offending signal was the RSP credit")

    # The link must still work after both pulses. A control that leaves the
    # interface broken has proved the stimulus, not the rule.
    rd = self.rni0_rd_seq
    rd.reset()
    rd.set_requests(1)
    rd.set_initial_addr(RESET_IDLE_ADDR_C)
    rd.set_size(SIZE_C)
    rd.set_get_response(True)
    rd.set_verbose(False)
    await rd.start(self.v_sqr.rni_sequencer)

    await self.wait_clocks(SETTLE_C)

    self.logger.info(
      f"Test (tc_chi_reset_idle_scope) PASS: the closing sentence of section "
      f"14.1.3 was driven and reported nowhere (all four rules re-evaluated), "
      f"the list's TX***LCRDV was driven and reported "
      f"{self.tb_env.rni_sva.fail_count.get(RSP_C, 0)}/"
      f"{self.tb_env.snf_sva.fail_count.get(RSP_C, 0)} time(s) at the "
      f"RN-I/SN-F, its two post-release rules "
      f"{self.tb_env.rni_sva.fail_count.get(COLLATERAL_C[0], 0)}/"
      f"{self.tb_env.snf_sva.fail_count.get(COLLATERAL_C[0], 0)} and "
      f"{self.tb_env.rni_sva.fail_count.get(COLLATERAL_C[1], 0)}/"
      f"{self.tb_env.snf_sva.fail_count.get(COLLATERAL_C[1], 0)}, and the link "
      f"carried a read afterwards")

    self.drop_objection()
