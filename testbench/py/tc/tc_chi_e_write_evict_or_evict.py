################################################################################
# pyUVM/cocotb port of tc/tc_chi_e_write_evict_or_evict.sv.
#
# WriteEvictOrEvict (Issue E): the one CopyBack whose SHAPE the completer picks.
#
# The RN-F offers a clean line back and the home decides, on its own heuristics,
# whether it wants the data:
#
#   CompDBIDResp -> yes. The requester sends CopyBackWrData, and that message is
#                   itself the implicit CompAck. No explicit CompAck follows.
#   Comp         -> no. The requester sends an explicit CompAck and no data. The
#                   transaction degenerates into an Evict.
#
# Both legs run here, because a test that only drove one would leave the other as
# a branch nothing has ever taken -- and the two legs differ in the two things
# easiest to get wrong: whether data moves, and which acknowledgement closes the
# transaction. "Its own heuristics" is not predictable, so the home's choice is
# cfg.hnf_write_evict_request_data and each leg is driven deliberately.
#
# What separates the legs on the wire, and so what is asserted:
#
#   * data leg: exactly one CopyBackWrData burst from the requester, and NO
#     CompAck. An implementation that sent the ack anyway would be sending one
#     the home never expects.
#   * no-data leg: NO DAT flit at all, and exactly one CompAck.
#
# Either way the line leaves the requester's cache and its directory entry goes
# Invalid -- that is the "Evict" in the name, and it holds on both branches.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Resp, ReqOpcode, RspOpcode, DatOpcode
from chi_coherent_e_base_test import chi_coherent_e_base_test
from vip_chi_write_evict_or_evict_seq import vip_chi_write_evict_or_evict_seq
from chi_tb_pkg import WRITE_READ_ADDR_C

SETTLE_C = 8


class tc_chi_e_write_evict_or_evict(chi_coherent_e_base_test):

  async def drive_leg(self, request_data):
    """One WriteEvictOrEvict from RN-F0, with the home's choice forced.

    Returns (dat_beats, comp_acks) observed on the requester's own link.
    """
    hnf = self.tb_env.hnf_agent.hnf_driver

    # The requester must actually hold a clean line to offer back, or the
    # transaction would be reporting on a line it never had.
    self.cfg_read_seq(self.hrnf0_rdshared_seq)
    await self.hrnf0_rdshared_seq.start(self.tb_env.hrnf0_agent.sequencer)
    self.hrnf0_rdshared_seq.get_responses()
    await self.wait_clocks(SETTLE_C)

    assert self.tb_env.hrnf0_agent.rnf_driver.get_cache_state(
      WRITE_READ_ADDR_C) != int(Resp.I), (
      "RN-F0 holds no line, so there is nothing to evict")

    self.drain_observation_fifos()
    self.hrnf0_cfg.hnf_write_evict_request_data = request_data
    self.hnf_cfg.hnf_write_evict_request_data = request_data

    seq = vip_chi_write_evict_or_evict_seq("hrnf0_weoe_seq", cfg=self.chi_cfg)
    self.cfg_read_seq(seq)
    await seq.start(self.tb_env.hrnf0_agent.sequencer)
    rsp = seq.get_responses()
    await self.wait_clocks(SETTLE_C)

    assert len(rsp) == 1, f"expected 1 response, got {len(rsp)}"

    ok, req_item = self.tb_env.hrnf0_req_fifo.try_get()
    assert ok, "WriteEvictOrEvict produced no REQ flit"
    assert int(req_item.opcode) == int(ReqOpcode.WRITE_EVICT_OR_EVICT), (
      f"REQ opcode 0x{int(req_item.opcode):x}, expected "
      f"0x{int(ReqOpcode.WRITE_EVICT_OR_EVICT):x}")
    assert int(req_item.exp_comp_ack) == 1, (
      "WriteEvictOrEvict must set ExpCompAck: the no-data leg completes only on "
      "the acknowledgement")

    dat_beats = 0
    while True:
      ok, dat_item = self.tb_env.hrnf0_dat_fifo.try_get()
      if not ok:
        break
      assert int(dat_item.dat_opcode) == int(DatOpcode.COPY_BACK_WR_DATA), (
        f"WriteEvictOrEvict data was 0x{int(dat_item.dat_opcode):x}, expected "
        f"CopyBackWrData: it is a CopyBack, and that message is also the "
        f"implicit CompAck")
      dat_beats += len(dat_item.data)

    comp_acks = 0
    while True:
      ok, rsp_item = self.tb_env.hrnf0_rsp_fifo.try_get()
      if not ok:
        break
      if int(rsp_item.rsp_opcode) == int(RspOpcode.COMP_ACK):
        comp_acks += 1

    # Either way the line leaves the requester -- the "Evict" in the name.
    assert self.tb_env.hrnf0_agent.rnf_driver.get_cache_state(
      WRITE_READ_ADDR_C) == int(Resp.I), (
      "RN-F0 still holds the line after WriteEvictOrEvict")
    assert hnf.get_directory_port_state(WRITE_READ_ADDR_C, 0) == int(Resp.I), (
      "directory port0 not Invalid after WriteEvictOrEvict")

    return dat_beats, comp_acks

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    # ---- Leg 1: the home asks for the data ---------------------------------
    dat_beats, comp_acks = await self.drive_leg(True)

    assert dat_beats > 0, (
      "the home answered CompDBIDResp but no CopyBackWrData was sent: the data "
      "leg never moved any data")
    assert comp_acks == 0, (
      f"the data leg sent {comp_acks} explicit CompAck(s): CopyBackWrData is "
      f"itself the implicit acknowledgement, so an explicit one is a response "
      f"the home never expects")

    # ---- Leg 2: the home declines it ---------------------------------------
    dat_beats, comp_acks = await self.drive_leg(False)

    assert dat_beats == 0, (
      f"the home answered Comp but the requester still sent {dat_beats} data "
      f"beat(s): the no-data leg must not move data")
    assert comp_acks == 1, (
      f"the no-data leg sent {comp_acks} CompAck(s), expected exactly 1: a bare "
      f"Comp completes only when the requester acknowledges it")

    assert self.tb_env.coh_checker.get_multi_owner_count() == 0, \
      "multi-owner violations on WriteEvictOrEvict traffic"

    self.logger.info(
      "Test (tc_chi_e_write_evict_or_evict) PASS: the data leg sent "
      "CopyBackWrData with no explicit CompAck, the no-data leg sent one CompAck "
      "and no data, and the line left the cache on both")
    self.drop_objection()
