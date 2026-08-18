################################################################################
# pyUVM/cocotb port of tc/tc_chi_e_write_cmo.sv.
#
# Combined Write + CMO (Issue E): one request carrying both a write and a cache
# maintenance operation to the same address.
#
# All six forms in one run -- Full and Ptl, each with CleanSh, CleanInv and
# CleanShPerSep -- because the six differ only in two independent choices and
# testing one of them would leave the other five as opcodes nothing has ever put
# on a wire.
#
# What is actually asserted, in order of what would otherwise go unnoticed:
#
#   * the CMO half is COMPLETED. The write half of a combined request completes
#     exactly like an ordinary write, so a completer that ignored the CMO
#     entirely would still produce a run that looks clean from the requester's
#     side. CompCMO is the separate response that says the CMO happened, and it
#     is checked here as an observed flit rather than as an absence of errors.
#   * the CMO responses arrive AFTER the write's own completion, and the persist
#     leg after CompCMO, for the two persistent forms. That is the ordering the
#     whole family turns on -- the CMO acts on the state the write leaves behind
#     -- and it is the one thing here a completer can get wrong while still
#     answering every flit. RSP fifo order is RSP channel order, so this is the
#     real observation, not a restatement of what the driver enforces.
#   * CompAck, on the three Ptl forms, which set ExpCompAck. The spec permits
#     ExpCompAck on a Non-CopyBack Combined Write and requires the CompAck to be
#     sent AFTER the write's completion response -- a lower bound, with no upper
#     bound, so the requester is free to send it any time later. This test
#     checks the bound that exists rather than the placement this RN-I happens
#     to pick: CompAck after the write completion, present exactly when
#     ExpCompAck was set and absent when it was not. The three Full forms leave
#     ExpCompAck clear, so both populations run in the same test.
#   * the data landed, read back and compared byte by byte afterwards. A
#     completer that answered correctly and dropped the write would satisfy both
#     assertions above.
#
# The scoreboard is watching all of this independently: the combined forms carry
# a completion contract that requires CompCMO (and Persist for the persistent
# forms), so an incomplete transaction fails the run at check_phase whether or
# not this test looks for it.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import ReqOpcode, RspOpcode, chi_xfer_dat_beats
from vip_chi_write_cmo_seq import (
  vip_chi_write_cmo_seq, CMO_CLEAN_SH, CMO_CLEAN_INV, CMO_CLEAN_SH_PER_SEP)
from chi_e_base_test import chi_e_base_test

ADDR_C = 0x4A00_0000
ADDR_STRIDE_C = 0x1000
SIZE_C = 6                      # 64 B, one beat on the wide CHI-E link
SETTLE_C = 20

_FORMS_C = [
  (False, CMO_CLEAN_SH), (False, CMO_CLEAN_INV), (False, CMO_CLEAN_SH_PER_SEP),
  (True, CMO_CLEAN_SH), (True, CMO_CLEAN_INV), (True, CMO_CLEAN_SH_PER_SEP),
]

# ExpCompAck on the Ptl half only. Splitting it this way rather than setting it
# everywhere keeps both populations in one run: every CMO kind is covered with a
# CompAck and without one, so "no CompAck appeared" is a failure on one half and
# the expected outcome on the other.
_FORM_ACK_C = [False, False, False, True, True, True]

# The REQ opcode each form must put on the wire. Spelled out rather than
# recomputed from the sequence's own mapping: a test that asked the thing under
# test what it intended to send would agree with itself no matter what came out.
_EXPECTED_OPCODE_C = {
  (False, CMO_CLEAN_SH): ReqOpcode.WRITE_NO_SNP_FULL_CLEAN_SH,
  (False, CMO_CLEAN_INV): ReqOpcode.WRITE_NO_SNP_FULL_CLEAN_INV,
  (False, CMO_CLEAN_SH_PER_SEP): ReqOpcode.WRITE_NO_SNP_FULL_CLEAN_SH_PER_SEP,
  (True, CMO_CLEAN_SH): ReqOpcode.WRITE_NO_SNP_PTL_CLEAN_SH,
  (True, CMO_CLEAN_INV): ReqOpcode.WRITE_NO_SNP_PTL_CLEAN_INV,
  (True, CMO_CLEAN_SH_PER_SEP): ReqOpcode.WRITE_NO_SNP_PTL_CLEAN_SH_PER_SEP,
}


class tc_chi_e_write_cmo(chi_e_base_test):

  async def run_phase(self):
    self.raise_objection()

    data_bytes = self.chi_cfg.data_bytes
    expected_beats = chi_xfer_dat_beats(SIZE_C, data_bytes)

    written = []                 # [(data beats, be beats)] per form

    # Nothing left over from bring-up may be mistaken for a response to the
    # first form.
    self.drain_observation_fifos()

    for index, (partial, cmo) in enumerate(_FORMS_C):
      addr = ADDR_C + index * ADDR_STRIDE_C

      seq = vip_chi_write_cmo_seq(f"write_cmo_{index}", cfg=self.chi_cfg)
      seq.set_partial(partial)
      seq.set_cmo(cmo)
      seq.reset()
      seq.set_exp_comp_ack(_FORM_ACK_C[index])
      seq.set_requests(1)
      seq.set_initial_addr(addr)
      seq.set_size(SIZE_C)
      seq.set_allow_retry(0)
      seq.set_get_response(True)
      seq.set_verbose(False)
      await seq.start(self.v_sqr.rni_sequencer)

      responses = seq.get_responses()
      assert len(responses) == 1, (
        f"form {index} returned {len(responses)} responses, expected 1")

      # Keep the payload for the readback below: the sequence randomizes it, so
      # the only record of what this form wrote is the request itself. The byte
      # enables come with it because the three Ptl forms only land the enabled
      # lanes -- comparing whole beats there would fail on bytes the write was
      # never asked to write.
      written.append((list(responses[0].data), list(responses[0].be)))

      await self.wait_clocks(SETTLE_C)

      # ---- REQ: the opcode that actually reached the wire -------------------
      ok, req_item = self.tb_env.rni_req_fifo.try_get()
      assert ok, f"form {index} produced no REQ flit"
      assert int(req_item.opcode) == int(_EXPECTED_OPCODE_C[(partial, cmo)]), (
        f"form {index} REQ opcode 0x{int(req_item.opcode):x}, expected "
        f"0x{int(_EXPECTED_OPCODE_C[(partial, cmo)]):x}")

      ok, _stray = self.tb_env.rni_req_fifo.try_get()
      assert not ok, f"form {index} produced more than one REQ flit"

      # ---- DAT: the write half still carries its data burst -----------------
      dat_beats_seen = 0
      while True:
        ok, dat_item = self.tb_env.rni_dat_fifo.try_get()
        if not ok:
          break
        dat_beats_seen += len(dat_item.data)

      assert dat_beats_seen == expected_beats, (
        f"form {index} wrote {dat_beats_seen} DAT beats, expected "
        f"{expected_beats}")

      # ---- RSP: the CMO half, and where it sits in the response order -------
      rsp_index = 0
      write_comp_index = None
      comp_cmo_index = None
      persist_index = None
      comp_ack_index = None

      while True:
        ok, rsp_item = self.tb_env.rni_rsp_fifo.try_get()
        if not ok:
          break

        opcode = int(rsp_item.rsp_opcode)
        if opcode == int(RspOpcode.PERSIST):
          assert int(rsp_item.txn_id) == 0, (
            f"form {index} Persist TxnID 0x{int(rsp_item.txn_id):x} was not zero")
        else:
          assert int(rsp_item.txn_id) == int(req_item.txn_id), (
            f"form {index} RSP TxnID 0x{int(rsp_item.txn_id):x} did not match "
            f"the request 0x{int(req_item.txn_id):x}")

        if opcode == int(RspOpcode.DBID_RESP):
          pass                   # buffer grant only; the completion is below
        elif opcode in (int(RspOpcode.COMP), int(RspOpcode.COMP_DBID_RESP)):
          write_comp_index = rsp_index
        elif opcode == int(RspOpcode.COMP_CMO):
          comp_cmo_index = rsp_index
        elif opcode == int(RspOpcode.PERSIST):
          persist_index = rsp_index
        elif opcode == int(RspOpcode.COMP_ACK):
          # The RN-I's own TX response. The monitor publishes both directions of
          # the RSP channel into this fifo, so its position here is the order the
          # two directions actually appeared on the link.
          comp_ack_index = rsp_index
        else:
          raise AssertionError(
            f"form {index} unexpected RSP opcode 0x{opcode:x}")

        rsp_index += 1

      assert write_comp_index is not None, (
        f"form {index} drew no write completion")

      # The whole point of the family: the CMO half has its own completion.
      assert comp_cmo_index is not None, (
        f"form {index} drew no CompCMO -- the CMO half was never completed")
      assert comp_cmo_index > write_comp_index, (
        f"form {index} sent CompCMO (RSP {comp_cmo_index}) before the write "
        f"completion (RSP {write_comp_index})")

      if seq.is_persist():
        assert persist_index is not None, (
          f"form {index} is persistent but drew no Persist")
        assert persist_index > comp_cmo_index, (
          f"form {index} sent Persist (RSP {persist_index}) before CompCMO "
          f"(RSP {comp_cmo_index})")
      else:
        assert persist_index is None, (
          f"form {index} is not persistent but drew a Persist")

      # ---- CompAck: sent when asked for, and never before the completion -----
      #
      # The spec states one bound and only one: with ExpCompAck set, the CompAck
      # must be sent AFTER Comp / DBIDResp / DBIDRespOrd / CompDBIDResp. Nothing
      # caps how late it may be, so where it sits relative to CompCMO and
      # Persist is the requester's choice and is deliberately not asserted --
      # pinning it would fail a legal implementation that acked earlier.
      if _FORM_ACK_C[index]:
        assert comp_ack_index is not None, (
          f"form {index} set ExpCompAck but never sent a CompAck")
        assert comp_ack_index > write_comp_index, (
          f"form {index} sent CompAck (RSP {comp_ack_index}) before the write "
          f"completion (RSP {write_comp_index})")
      else:
        assert comp_ack_index is None, (
          f"form {index} left ExpCompAck clear but sent a CompAck "
          f"(RSP {comp_ack_index})")

    # And the writes actually landed. A completer that answered every response
    # correctly and dropped the data would pass everything above.
    rd = self.rni_rd_seq
    rd.reset()
    rd.set_requests(len(_FORMS_C))
    rd.set_initial_addr(ADDR_C)
    rd.set_addr_stride(ADDR_STRIDE_C)
    rd.set_size(SIZE_C)
    rd.set_allow_retry(0)
    rd.set_get_response(True)
    rd.set_verbose(False)
    await rd.start(self.v_sqr.rni_sequencer)

    read_back = rd.get_responses()
    assert len(read_back) == len(_FORMS_C), (
      f"readback returned {len(read_back)} responses, expected {len(_FORMS_C)}")

    for index, (wr_data, wr_be) in enumerate(written):
      rd_data = list(read_back[index].data)
      assert len(rd_data) == len(wr_data), (
        f"form {index} read back {len(rd_data)} beats, wrote {len(wr_data)}")

      # Byte-wise, gated on the byte enables: a Ptl form leaves the disabled
      # lanes as whatever the backing memory already held, so only the bytes the
      # write actually claimed are evidence of anything.
      for beat, (wrote, be) in enumerate(zip(wr_data, wr_be)):
        for byte_index in range(data_bytes):
          if not ((int(be) >> byte_index) & 1):
            continue
          got_byte = (int(rd_data[beat]) >> (8 * byte_index)) & 0xFF
          wrote_byte = (int(wrote) >> (8 * byte_index)) & 0xFF
          assert got_byte == wrote_byte, (
            f"form {index} beat {beat} byte {byte_index} read back "
            f"0x{got_byte:02x}, wrote 0x{wrote_byte:02x}")

    await self.wait_clocks(SETTLE_C)
    self.drain_observation_fifos()

    self.logger.info(
      f"Test (tc_chi_e_write_cmo) PASS: all {len(_FORMS_C)} combined Write+CMO "
      f"forms completed with CompCMO, both persistent forms drew a Persist "
      f"after it, the 3 ExpCompAck forms acked after the write completion, and "
      f"every write read back")
    self.drop_objection()
