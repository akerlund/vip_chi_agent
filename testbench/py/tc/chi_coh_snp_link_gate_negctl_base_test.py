################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of tc/chi_coh_snp_link_gate_negctl_base_test.sv.
#
# Wire negative control for CHI_SNP_FLITV_REQUIRES_LINK, which had never been
# reachable outside a unit test.
#
# IHI 0050 E section 14.6.1 / D section 13.6.1 give an interface TWO link state
# machines, one per direction, and a channel's payload belongs to the machine
# that carries it. A snoop is the home's OUTPUT, so txsnpflitv is judged against
# the home's TRANSMIT link, which reaches RUN only when the SNOOPEE
# acknowledges. Nothing produced a home whose transmit link was anything but RUN
# while it had a snoop to send, because the two machines at a coherent endpoint
# moved together.
#
# Separating them is the whole setup, and only one lever does it.
# cfg.lasm_ack_delay_cycles holds the SNOOPEE's acknowledge down for a counted
# number of cycles after it sees the home's request. That is a CONFORMANT peer:
# Table 14-2 has the transmitter "waiting for the receiver to acknowledge" as an
# ordinary dwell in ACTIVATE, and 14.6.3 bans only the acknowledge moving BEFORE
# the request. Delaying the home's REQUEST instead cannot work -- 14.6.3 forbids
# the acknowledge to lead the request, so a home that holds its request back
# holds its acknowledge back with it and the snoopee's two machines move
# together again.
#
# What the delay exposes is a defect at the OTHER end, which is why the fix and
# the control are separate things. The home used to start transmitting on the
# strength of the peer's REQUEST rather than its own transmit link reaching RUN,
# and that is invisible while the peer acknowledges promptly -- the two events
# are two cycles apart. rn_activate now waits for the acknowledge before it
# opens the transmit gate, and cfg.hnf_send_before_tx_link_negctl stands that
# gate down so the control has the old behaviour to report.
#
# COLLATERAL, declared rather than waived: the gate is the one every RN-facing
# flit passes, so the read data that belongs to the request being serviced goes
# out early too and CHI_DAT_FLITV_REQUIRES_LINK reports on both of the home's
# ports. That is the same defect seen on a different channel, not a second one,
# and asserting it is what shows the gate covers the whole transmit link rather
# than the snoop channel alone.
#
# PHASE 2 is the OTHER rule of the same pair, and it needs a different setup for
# a reason worth stating. CHI_SNP_LCRDV_REQUIRES_LINK wants the snoopee's RECEIVE
# link in STOP while the snoopee advertises SNP credits, and no delay reaches
# that during a first bring-up: the snoopee advertises once its own transmit link
# is acknowledged, by which time the home's request is necessarily already up,
# because 14.6.3 forbids the home's acknowledge to lead it. So the receive
# machine is at least ACTIVATE and the rule permits that.
#
# cfg.rnf_snp_credit_before_link_negctl moves some of the initial advertisement
# ahead of the link instead, drawn OUT of the budget rather than added to it so
# only the timing changes. That alone is still not enough, and the reason is a
# deliberate scoping decision rather than an accident: the rule is gated on
# _link_ever_active, so a link that has never been up cannot report at all. A
# RESET is what closes the gap -- it returns an already-active link to STOP,
# leaving the gate satisfied and the state reachable. Measured, not assumed: the
# same knob before the first activation reports nothing.
#
################################################################################

from __future__ import annotations

from chi_coherent_base_test import chi_coherent_base_test
from chi_tb_pkg import WRITE_READ_ADDR_C

_SNP_C = "CHI_SNP_FLITV_REQUIRES_LINK"
_DAT_C = "CHI_DAT_FLITV_REQUIRES_LINK"
_LCRDV_C = "CHI_SNP_LCRDV_REQUIRES_LINK"
_LINE_C = WRITE_READ_ADDR_C
_SETTLE_C = 40
# Long enough that the home has a snoop to send while its transmit link is still
# in ACTIVATE, and short enough to stay clear of any activation timeout a test
# might enable.
ACK_DELAY_C = 120
# One snoop goes out in the window, so one report at the port it goes out on.
EXPECTED_SNP_FAILS_C = 1
# One report per credit the control puts out ahead of the link.
EARLY_SNP_CREDITS_C = 2
EXPECTED_LCRDV_FAILS_C = EARLY_SNP_CREDITS_C
# Long enough that the credits are still draining while the link is in STOP.
REQ_DELAY_C = 12


class chi_coh_snp_link_gate_negctl_base_test(chi_coherent_base_test):

  # Both snoopees hold their acknowledge, so the window is open on both of the
  # home's ports and a report on only one of them would be a routing accident.
  def configure_agent_cfgs(self):
    self.hrnf0_cfg.lasm_ack_delay_cycles = ACK_DELAY_C
    self.hrnf1_cfg.lasm_ack_delay_cycles = ACK_DELAY_C
    self.hnf_cfg.hnf_send_before_tx_link_negctl = True

    # Phase 2, on the snoopee only: some of its initial SNP advertisement goes
    # out ahead of the link, and its own request is held back so the link is
    # still in STOP while they drain.
    self.hrnf0_cfg.rnf_snp_credit_before_link_negctl = EARLY_SNP_CREDITS_C
    self.hrnf0_cfg.lasm_req_delay_by_state = [REQ_DELAY_C, 0, 0, 0]

  # Judged at the home's own binds, because that is where the transmit link
  # being tested is driven.
  def connect_phase(self):
    super().connect_phase()
    for sva in self.tb_env.snp_sva:
      sva.expect_failure(_SNP_C)
    for sva in self.tb_env.hnfr_sva:
      sva.expect_failure(_DAT_C)
    for sva in self.tb_env.snp_sva:
      sva.expect_failure(_LCRDV_C)

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    self.cfg_read_seq(self.hrnf0_rdunique_seq, _LINE_C)
    await self.hrnf0_rdunique_seq.start(self.tb_env.hrnf0_agent.sequencer)
    assert len(self.hrnf0_rdunique_seq.get_responses()) == 1, (
      "RN-F0 did not acquire the line; a link held in ACTIVATE must still carry "
      "traffic once it comes up")

    await self.wait_clocks(_SETTLE_C)

    self.cfg_read_seq(self.hrnf1_rdshared_seq, _LINE_C)
    await self.hrnf1_rdshared_seq.start(self.tb_env.hrnf1_agent.sequencer)
    assert len(self.hrnf1_rdshared_seq.get_responses()) == 1, \
      "RN-F1's read never completed"

    await self.wait_clocks(_SETTLE_C)

    assert self.tb_env.hrnf0_snp_fifo.can_get(), (
      "RN-F0 was never snooped, so the home answered from its directory and the "
      "snoop this control times was never sent")

    # snp_sva is ordered hnfr0, hnfr1, hrnf0, hrnf1 -- the home's two ports
    # first, then the two snoopees.
    home_snp = self.tb_env.snp_sva[:2]
    snoopee_snp = self.tb_env.snp_sva[2:]

    snp_fails = home_snp[0].fail_count.get(_SNP_C, 0)
    dat_fails = [c.fail_count.get(_DAT_C, 0) for c in self.tb_env.hnfr_sva]

    assert snp_fails == EXPECTED_SNP_FAILS_C, (
      f"{_SNP_C} reported {snp_fails} time(s) at the home's port 0, expected "
      f"exactly {EXPECTED_SNP_FAILS_C}; zero means the snoop went out after the "
      f"transmit link had reached RUN and the rule is still unreachable on the "
      f"wire")

    assert all(dat_fails), (
      f"{_DAT_C} reported {dat_fails[0]} time(s) at port 0 and {dat_fails[1]} "
      f"at port 1, expected both non-zero; the gate this control removes covers "
      f"the whole transmit link, not the snoop channel alone")

    # The snoopees' own outputs are untouched: it is the peer whose slow
    # acknowledge opens the window, not the component in breach.
    snoopee_fails = sum(c.fail_count.get(_SNP_C, 0) for c in snoopee_snp)
    assert snoopee_fails == 0, (
      f"the snoopees' own binds reported {snoopee_fails} time(s): a conformant "
      f"peer that acknowledges slowly is not itself in breach")

    # See the header: unreachable during bring-up against a conformant home, so
    # a report here would mean the sideband had gone somewhere 14.6.3 forbids.
    # Nothing may have reported yet: before the first activation the rule's own
    # gate stands it down, so the early credits that went out then are silent.
    early = sum(c.fail_count.get(_LCRDV_C, 0) for c in self.tb_env.snp_sva)
    assert early == 0, (
      f"{_LCRDV_C} reported {early} time(s) before any reset; the rule is gated "
      f"on the link having been active, so a link that has never come up must "
      f"not report")

    # -- Phase 2: a reset returns an already-active link to STOP. -------------
    await self.pulse_reset(4)
    await self.wait_clocks(_SETTLE_C)

    lcrdv_fails = [c.fail_count.get(_LCRDV_C, 0) for c in self.tb_env.snp_sva]
    assert lcrdv_fails[2] == EXPECTED_LCRDV_FAILS_C, (
      f"{_LCRDV_C} reported {lcrdv_fails[2]} time(s) at the snoopee, expected "
      f"exactly {EXPECTED_LCRDV_FAILS_C} -- one per credit the control put out "
      f"ahead of the link; zero means the advertisement waited for the link "
      f"after all")

    assert sum(lcrdv_fails) == EXPECTED_LCRDV_FAILS_C, (
      f"{_LCRDV_C} reported {lcrdv_fails} across the four SNP binds; only the "
      f"snoopee this control is set on advertises SNP credits, so a report "
      f"anywhere else is a different defect")

    self.logger.info(
      f"Test (coh_snp_link_gate_negctl) PASS: with the snoopees acknowledging "
      f"{ACK_DELAY_C} cycle(s) late, the home snooped into a transmit link "
      f"still in ACTIVATE and {_SNP_C} reported it once, with "
      f"{dat_fails[0]}/{dat_fails[1]} data beats reported on the same gate and "
      f"both reads still completing; a reset then returned the link to STOP and "
      f"{_LCRDV_C} reported the {EXPECTED_LCRDV_FAILS_C} credit(s) advertised "
      f"ahead of it")
    self.drop_objection()
