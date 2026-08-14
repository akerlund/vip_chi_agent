################################################################################
# pyUVM port of tc/chi_coh_line_hazard_base_test.sv.
#
# Same-cache-line hazard rule, both halves in one test.
#
# Positive half: two coherent reads to the SAME line, issued back to back but
# each allowed to complete before the next is sent. This is the ordinary,
# entirely legal pattern the rule must not object to, and it is what proves the
# rule is discriminating rather than simply allergic to repeated addresses.
#
# Negative half: two overlapping same-line requests, published straight into the
# checker's REQ observation port.
#
# That is deliberate, and it is worth being explicit about why it is not driven
# on the wire like the other coherency negative controls. This VIP's own RN-F
# cannot commit this violation: its coherent issue path is serial, and its
# multi-outstanding pipeline refuses coherent opcodes outright ("mixed pipeline
# supports ReadNoSnp / WriteNoSnp / atomics / persist only"). So there is no
# requester configuration that produces an overlapping coherent pair, and the
# alternative would be adding a driver knob whose only purpose is to make this
# VIP violate a rule it is otherwise structurally incapable of violating.
#
# The checker is a pure observer of the link, so handing it the two observations
# exercises exactly the code path that a real DUT overlapping two requests would
# exercise. What the negative control proves is that the RULE fires -- which is
# the thing that could rot -- rather than that this VIP can be made to misbehave.
################################################################################

from __future__ import annotations

from chi_coherent_base_test import chi_coherent_base_test
from chi_coherency_negctl_catcher import chi_coherency_negctl_catcher
from vip_chi_item import vip_chi_item, defer_field_model
from vip_chi_types_pkg import ReqOpcode, Role
from vip_chi_readshared_seq import vip_chi_readshared_seq
from chi_tb_pkg import WRITE_READ_ADDR_C

_HAZARD_ADDR_C = WRITE_READ_ADDR_C + 0x200


class chi_coh_line_hazard_base_test(chi_coherent_base_test):

  def _observed_req(self, addr, txn_id):
    """Build the REQ observation a monitor would publish for a coherent read."""
    with defer_field_model():
      item = vip_chi_item("hazard_req", cfg=self.chi_cfg)
    item.role = Role.RNF
    item.is_snoop = 0
    item.opcode = int(ReqOpcode.READ_SHARED)
    item.addr = addr
    item.txn_id = txn_id
    item.excl = 0
    return item

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    ck = self.tb_env.coh_checker

    # -- Positive half: same line twice, but strictly one at a time. -----------
    for i in range(2):
      seq = vip_chi_readshared_seq(f"serial_rs_{i}", cfg=self.chi_cfg)
      self.cfg_read_seq(seq, _HAZARD_ADDR_C)
      await seq.start(self.tb_env.hrnf0_agent.sequencer)

    await self.wait_clocks(20)

    assert ck.get_line_hazard_count() == 0, (
      f"{ck.get_line_hazard_count()} hazard(s) reported for two NON-overlapping "
      f"reads to one line -- the rule is firing on address reuse rather than on "
      f"overlap")
    serial_clears = ck.get_line_clear_count()
    assert serial_clears >= 2, (
      f"only {serial_clears} line claim(s) were opened and closed for two reads "
      f"-- the hazard shadow did not see this traffic")

    # -- Negative half: two overlapping same-line requests (see header). -------
    catcher = chi_coherency_negctl_catcher("line_hazard_catcher")
    ck.logger.addFilter(catcher)
    try:
      # Distinct TxnIDs, one line, neither completed in between. Same TxnID
      # would be a retry re-issue, which the rule correctly does NOT flag --
      # the next assertion covers that.
      ck.rnf0_req_cc.write(self._observed_req(_HAZARD_ADDR_C, 0x51))
      ck.rnf0_req_cc.write(self._observed_req(_HAZARD_ADDR_C, 0x52))
      hazards_after_overlap = ck.get_line_hazard_count()

      # A RetryAck'd request re-issued on the same TxnID must not be mistaken
      # for a second request: obeying the retry protocol is not a hazard.
      ck.rnf0_req_cc.write(self._observed_req(_HAZARD_ADDR_C + 0x40, 0x53))
      ck.rnf0_req_cc.write(self._observed_req(_HAZARD_ADDR_C + 0x40, 0x53))
      hazards_after_reissue = ck.get_line_hazard_count()

      await self.wait_clocks(20)
    finally:
      # A failed assertion below must not leave the filter on a logger that
      # outlives this test.
      ck.logger.removeFilter(catcher)

    assert hazards_after_overlap == 1, (
      f"the overlapping same-line pair produced {hazards_after_overlap} "
      f"hazard report(s), expected exactly 1")
    assert hazards_after_reissue == hazards_after_overlap, (
      f"a re-issue on the SAME TxnID was reported as a hazard "
      f"({hazards_after_reissue - hazards_after_overlap} extra) -- the rule "
      f"cannot tell a retry re-issue from a second request")

    assert catcher.saw_coherency_error, (
      "the hazard rule bumped its counter without reporting -- a silent check "
      "cannot be acted on")

    self.logger.info(
      f"Test (coh_line_hazard) PASS: {serial_clears} non-overlapping claims "
      f"accepted, overlapping same-line pair flagged once, same-TxnID re-issue "
      f"not flagged")
    self.drop_objection()
