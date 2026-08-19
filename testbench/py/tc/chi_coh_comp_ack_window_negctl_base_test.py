################################################################################
# pyUVM port of tc/chi_coh_comp_ack_window_negctl_base_test.sv.
#
# Negative control for catalogue rule D9, the CompAck ordering window.
#
# IHI 0050 E section 2.8.3 / D section 2.8.3, rule 2 of the completion sequence:
# "An HN-F, except in the case of ReadOnce*, waits for CompAck before sending a
# subsequent snoop to the same address." The same section states the guarantee
# the requester is owed: "it is guaranteed not to receive a Snoop request to the
# same address between the point that it receives Comp and the point that it
# sends CompAck."
#
# cfg.hnf_snoop_before_comp_ack makes the home send exactly one snoop into that
# window. SnpOnce is chosen deliberately: it leaves the snoopee's state and its
# data untouched, and section 4.4 permits a home to snoop spontaneously, so
# nothing about the flit is wrong except WHEN it was sent. Any other opcode would
# also perturb the shadow, and a failure could then be blamed on D5, D6 or the
# single-writer rule instead of on the one property under test.
#
# The window is widened on purpose. cfg.rsp_valid_delay_* holds RN-F0's RSP flits
# for a fixed count of cycles, so the CompAck lands well after the injected snoop
# rather than racing it.
################################################################################

from __future__ import annotations

from chi_coherent_base_test import chi_coherent_base_test
from chi_coherency_negctl_catcher import chi_coherency_negctl_catcher

# Long enough that the acknowledgement cannot beat a snoop the home sends the
# moment its last CompData beat is on the wire.
_ACK_DELAY_C = 8
_SETTLE_C = 40


class chi_coh_comp_ack_window_negctl_base_test(chi_coherent_base_test):

  # The home snoops inside the window; the requester answers late so the window
  # is unambiguously open when it does.
  def configure_agent_cfgs(self):
    self.hnf_cfg.hnf_snoop_before_comp_ack = True
    self.hrnf0_cfg.rsp_valid_delay_enabled = True
    self.hrnf0_cfg.rsp_valid_delay_min = _ACK_DELAY_C
    self.hrnf0_cfg.rsp_valid_delay_max = _ACK_DELAY_C

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    catcher = chi_coherency_negctl_catcher("coh_violation_catcher")
    self.tb_env.coh_checker.logger.addFilter(catcher)

    self.cfg_read_seq(self.hrnf0_rdshared_seq)
    await self.hrnf0_rdshared_seq.start(self.tb_env.hrnf0_agent.sequencer)
    self.hrnf0_rdshared_seq.get_responses()

    await self.wait_clocks(_SETTLE_C)

    self.tb_env.coh_checker.logger.removeFilter(catcher)

    # A window must have opened, or the snoop had nothing to fall inside of.
    assert self.tb_env.coh_checker.get_comp_ack_window_count() > 0, \
      "no CompAck window opened, so the injected snoop was judged against nothing"

    assert catcher.saw_coherency_error, (
      "the checker did NOT flag a snoop sent inside the CompAck window -- "
      "catalogue rule D9 may be vacuous")

    in_window = self.tb_env.coh_checker.get_comp_ack_window_snoop_count()
    assert in_window > 0, (
      "D9 counted no in-window snoop, so the coherency error above came from a "
      "different rule")

    self.logger.info(
      f"Test (coh_comp_ack_window_negctl) PASS: D9 reported {in_window} snoop(s) "
      f"inside a CompAck window, as the negative control intended")
    self.drop_objection()
