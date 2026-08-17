################################################################################
# pyUVM/cocotb port of tc/tc_chi_e_write_unique_zero.sv.
#
# WriteUniqueZero (Issue E): a snoopable full-line store of ZERO that puts NO
# data on the wire.
#
# The whole opcode exists to avoid a data transfer, so the assertion that matters
# is the ABSENCE of one. A WriteUniqueFull carrying a line of zeros would leave
# the memory in exactly the same state and would pass any readback check, so a
# test that only read the line back would pass just as loudly on the wrong
# opcode. What separates them is the DAT channel: this transaction must complete
# without the requester ever sending a beat.
#
# What is asserted:
#
#   * the REQ that reached the wire carries WriteUniqueZero, not something the
#     solver substituted.
#   * the requester sent NO DAT flit. This is the point of the opcode.
#   * the line reads back as zero. A home that answered correctly and never
#     zeroed anything would satisfy both assertions above.
#   * the other RN-F, which held the line before the write, was snoop-invalidated
#     -- the "Unique" half. Its cache and its directory entry must both be I.
#
# A second RN-F is given the line first, on purpose: without a holder there is
# nothing to snoop, and the snoop leg would be untested while looking tested.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Resp, ReqOpcode
from chi_coherent_e_base_test import chi_coherent_e_base_test
from vip_chi_write_unique_zero_seq import vip_chi_write_unique_zero_seq
from chi_tb_pkg import WRITE_READ_ADDR_C

SETTLE_C = 8


class tc_chi_e_write_unique_zero(chi_coherent_e_base_test):

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    hnf = self.tb_env.hnf_agent.hnf_driver

    # Give RN-F1 the line first, so the snoop leg has a holder to invalidate.
    # Without this the home has nothing to snoop and the "Unique" half of the
    # opcode would go untested while appearing tested.
    self.cfg_read_seq(self.hrnf1_rdshared_seq)
    await self.hrnf1_rdshared_seq.start(self.tb_env.hrnf1_agent.sequencer)
    self.hrnf1_rdshared_seq.get_responses()
    await self.wait_clocks(SETTLE_C)

    assert self.tb_env.hrnf1_agent.rnf_driver.get_cache_state(
      WRITE_READ_ADDR_C) != int(Resp.I), (
      "RN-F1 does not hold the line, so the snoop leg would not be exercised")

    # Nothing left over from the read may be mistaken for the write's traffic.
    self.drain_observation_fifos()

    wuz = vip_chi_write_unique_zero_seq("hrnf0_wuz_seq", cfg=self.chi_cfg)
    self.cfg_read_seq(wuz)
    await wuz.start(self.tb_env.hrnf0_agent.sequencer)
    rsp = wuz.get_responses()

    await self.wait_clocks(SETTLE_C)

    assert len(rsp) == 1, f"expected 1 WriteUniqueZero response, got {len(rsp)}"

    # ---- REQ: the opcode that actually reached the wire ---------------------
    ok, req_item = self.tb_env.hrnf0_req_fifo.try_get()
    assert ok, "WriteUniqueZero produced no REQ flit"
    assert int(req_item.opcode) == int(ReqOpcode.WRITE_UNIQUE_ZERO), (
      f"REQ opcode 0x{int(req_item.opcode):x}, expected "
      f"0x{int(ReqOpcode.WRITE_UNIQUE_ZERO):x}")

    # ---- DAT: there must be none. This is the opcode's whole purpose --------
    ok, dat_item = self.tb_env.hrnf0_dat_fifo.try_get()
    assert not ok, (
      f"WriteUniqueZero sent a DAT flit (opcode 0x{int(dat_item.dat_opcode):x}) "
      f"-- a zero write must complete with no data on the wire")

    # ---- The Unique half: the other holder was invalidated -------------------
    # Checked BEFORE the readback below, which would legitimately give RN-F1 the
    # line back and erase the evidence.
    assert self.tb_env.hrnf1_agent.rnf_driver.get_cache_state(
      WRITE_READ_ADDR_C) == int(Resp.I), (
      "RN-F1 still holds the line after WriteUniqueZero: it was not snooped out")
    assert hnf.get_directory_port_state(WRITE_READ_ADDR_C, 1) == int(Resp.I), (
      "directory port1 not Invalid after WriteUniqueZero")
    assert hnf.get_directory_port_state(WRITE_READ_ADDR_C, 0) == int(Resp.I), (
      "directory port0 not Invalid after WriteUniqueZero: the non-allocating "
      "writer must not end up owning the line")

    # ---- The line really was zeroed, read back through the protocol ---------
    # A coherent read rather than a peek into the home's memory model: the value
    # has to be observable the way a real requester would see it, and the same
    # check then means the same thing in both ports.
    self.cfg_read_seq(self.hrnf1_rdshared_seq)
    await self.hrnf1_rdshared_seq.start(self.tb_env.hrnf1_agent.sequencer)
    rd = self.hrnf1_rdshared_seq.get_responses()
    assert len(rd) == 1, f"expected 1 readback response, got {len(rd)}"

    for beat, value in enumerate(rd[0].data):
      assert int(value) == 0, (
        f"beat {beat} of the line reads back 0x{int(value):x} after "
        f"WriteUniqueZero, expected zero: the home answered but never zeroed it")

    assert self.tb_env.coh_checker.get_multi_owner_count() == 0, \
      "multi-owner violations on WriteUniqueZero traffic"

    self.logger.info(
      "Test (tc_chi_e_write_unique_zero) PASS: WriteUniqueZero completed with no "
      "DAT flit, zeroed the line, and invalidated the other holder")
    self.drop_objection()
