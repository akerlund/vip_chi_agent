################################################################################
# pyUVM port of tc/chi_coh_combined_write_cmo_base_test.sv.
#
# The COHERENT half of the combined Write + CMO family: one request carrying a
# write to a Home and a cache-maintenance operation on the same address, applied
# in that order.
#
# The WriteNoSnp half of this family reaches a memory node and was built first.
# These reach the HN-F, so the write half runs on the coherent completer path --
# service_writeback for the CopyBacks, service_write_unique for the rest -- and
# the CMO acts on the state that write leaves behind.
#
# What is asserted, per form:
#
#   * the second completion arrives. CompCMO is what says the CMO half happened;
#     without it a completer that ignored the CMO entirely would produce a run
#     indistinguishable from a correct one, because the write completes exactly
#     as an ordinary write does. The requester's combined_completion_log is read
#     rather than the wire, because the log is what the requester ACCEPTED --
#     a response left in the stream would be a wrong-opcode error on the next
#     transaction rather than a missing entry here.
#   * a persistent form draws a Persist after it, and a non-persistent one draws
#     none. Both directions, so the check cannot pass by always expecting one.
#   * the requester's cache state ends where the WRITE half puts it, which is the
#     thing that distinguishes the three write classes: a CopyBack ends Invalid,
#     a WriteClean keeps a clean copy, a WriteUnique is non-allocating.
#   * no coherency violation, and -- for CleanInvalid -- the other holder really
#     lost its copy, which is the one CMO of the three with work left to do
#     after the write half has run.
#
# Used by:
#   tc_chi_coh_e_combined_write_cmo   (wide CHI-E)
#
# CHI-E only: every combined form sits in the Opcode[6] = 1 half of Table 13-14
# and does not fit CHI-D's 6-bit REQ opcode field, so there is no CHI-D twin.
#
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Resp, RspOpcode, pgroup_id_from_req
from chi_coherent_base_test import chi_coherent_base_test
from chi_tb_pkg import WRITE_READ_ADDR_C
from vip_chi_write_cmo_seq import (
  vip_chi_write_cmo_seq, CMO_CLEAN_SH, CMO_CLEAN_INV, CMO_CLEAN_SH_PER_SEP,
  CWRITE_BACK_FULL, CWRITE_CLEAN_FULL, CWRITE_UNIQUE,
)

_SETTLE_C = 12

# The group the requester asks for, and the answer 13.10.8 obliges the home to
# put on the Persist: PGroupID[7:0] = {GroupIDExt[2:0], LPID[4:0]}. Both halves
# non-zero and different, so a completer that built the field out of one half
# alone fails -- and neither is zero, which is what a home that never read the
# field reports and therefore the one value that cannot tell a working link from
# a silent one.
_PGROUP_EXT_C = 0b101
_PGROUP_LPID_C = 0x13


class chi_coh_combined_write_cmo_base_test(chi_coherent_base_test):

  async def _combined_write(self, write_class, cmo, partial=False):
    """One combined write from RN-F0, and the completions it drew."""
    rnf = self.tb_env.hrnf0_agent.rnf_driver
    rnf.combined_completion_log = []

    seq = vip_chi_write_cmo_seq("hrnf0_cmo_seq", cfg=self.chi_cfg)
    self.cfg_read_seq(seq)
    seq.set_write_class(write_class)
    seq.set_cmo(cmo)
    seq.set_partial(partial)
    seq.set_group_id_ext(_PGROUP_EXT_C)
    seq.set_lp_id(_PGROUP_LPID_C)

    while self.tb_env.hrnf0_rsp_fifo.try_get()[0]:
      pass

    await seq.start(self.tb_env.hrnf0_agent.sequencer)
    seq.get_responses()

    await self.wait_clocks(_SETTLE_C)
    return list(rnf.combined_completion_log)

  async def _own_the_line(self):
    """RN-F0 takes the line Unique-Dirty, so a CopyBack has something to write."""
    self.cfg_read_seq(self.hrnf0_rdunique_seq)
    await self.hrnf0_rdunique_seq.start(self.tb_env.hrnf0_agent.sequencer)
    self.hrnf0_rdunique_seq.get_responses()
    await self.wait_clocks(4)

  def _check_completions(self, log, cmo, what):
    assert int(RspOpcode.COMP_CMO) in log, (
      f"{what}: no CompCMO among the completions the requester accepted "
      f"({[hex(o) for o in log]}). Section 2.8 owes one, and without it a "
      f"completer that ignored the CMO half looks correct from here")
    saw_persist = int(RspOpcode.PERSIST) in log
    if cmo == CMO_CLEAN_SH_PER_SEP:
      assert saw_persist, (
        f"{what}: a persistent CMO drew no Persist ({[hex(o) for o in log]})")
    else:
      assert not saw_persist, (
        f"{what}: a non-persistent CMO drew a Persist "
        f"({[hex(o) for o in log]}); the two must be distinguishable")

    if cmo == CMO_CLEAN_SH_PER_SEP:
      self._check_persist_pgroup(what)

  def _check_persist_pgroup(self, what):
    """The Persist's PGroupID, read off the wire rather than out of the driver.

    13.10.7 puts the group in the bits Table 13-7 otherwise calls DBID -- a
    persist response has no data buffer for a real DBID to displace -- and
    13.10.8 builds it as {GroupIDExt[2:0], LPID[4:0]}. So this asserts a value
    that had to survive a round trip: out of the sequence, onto the REQ flit,
    back off it at the home, and onto the RSP flit.

    Worth asserting BECAUSE the failure is quiet. Both ends of a link that never
    carried GroupIDExt agree on group zero, and no parity check, no counter and
    no scoreboard rule can see the difference -- they are consistent, and
    consistently wrong. That is what the SystemVerilog coherent link did until
    its `_e` drivers landed.
    """
    expected = pgroup_id_from_req(_PGROUP_EXT_C, _PGROUP_LPID_C)
    got = None
    while True:
      ok, item = self.tb_env.hrnf0_rsp_fifo.try_get()
      if not ok:
        break
      if int(item.rsp_opcode) == int(RspOpcode.PERSIST):
        got = int(item.dbid)

    assert got is not None, (
      f"{what}: no Persist reached the monitor, so its PGroupID was judged "
      f"against nothing")
    assert got == expected, (
      f"{what}: Persist carried PGroupID 0x{got:x}, expected 0x{expected:x} "
      f"from GroupIDExt 0x{_PGROUP_EXT_C:x} and LPID 0x{_PGROUP_LPID_C:x} "
      f"(13.10.8)")

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    rnf0 = self.tb_env.hrnf0_agent.rnf_driver
    coh = self.tb_env.coh_checker

    # --- CopyBack + CleanShared: the requester gives the line up -------------
    await self._own_the_line()
    log = await self._combined_write(CWRITE_BACK_FULL, CMO_CLEAN_SH)
    self._check_completions(log, CMO_CLEAN_SH, "WriteBackFullCleanSh")
    assert rnf0.get_cache_state(WRITE_READ_ADDR_C) == int(Resp.I), \
      "RN-F0 still holds the line after a WriteBackFull + CMO"

    # --- CopyBack + CleanSharedPersistSep: the Persist half ------------------
    await self._own_the_line()
    log = await self._combined_write(CWRITE_BACK_FULL, CMO_CLEAN_SH_PER_SEP)
    self._check_completions(log, CMO_CLEAN_SH_PER_SEP,
                            "WriteBackFullCleanShPerSep")

    # --- CopyBack + CleanInvalid: the one CMO with work left to do -----------
    # RN-F1 takes a shared copy first, so the CleanInvalid half has a holder to
    # invalidate. Without it the phase would pass against a home that skipped
    # the CMO entirely.
    await self._own_the_line()
    self.cfg_read_seq(self.hrnf1_rdshared_seq)
    await self.hrnf1_rdshared_seq.start(self.tb_env.hrnf1_agent.sequencer)
    self.hrnf1_rdshared_seq.get_responses()
    await self.wait_clocks(4)
    rnf1 = self.tb_env.hrnf1_agent.rnf_driver
    assert rnf1.get_cache_state(WRITE_READ_ADDR_C) != int(Resp.I), \
      "RN-F1 holds nothing before the CleanInvalid phase, so it proves nothing"

    log = await self._combined_write(CWRITE_BACK_FULL, CMO_CLEAN_INV)
    self._check_completions(log, CMO_CLEAN_INV, "WriteBackFullCleanInv")
    assert rnf1.get_cache_state(WRITE_READ_ADDR_C) == int(Resp.I), \
      ("RN-F1 kept its copy through a combined CleanInvalid: the CMO half did "
       "not run, and the write half alone would leave it exactly here")

    # --- WriteClean + CleanShared: the requester KEEPS a clean copy ----------
    await self._own_the_line()
    log = await self._combined_write(CWRITE_CLEAN_FULL, CMO_CLEAN_SH)
    self._check_completions(log, CMO_CLEAN_SH, "WriteCleanFullCleanSh")

    # --- WriteUnique, full and partial --------------------------------------
    log = await self._combined_write(CWRITE_UNIQUE, CMO_CLEAN_SH)
    self._check_completions(log, CMO_CLEAN_SH, "WriteUniqueFullCleanSh")

    log = await self._combined_write(CWRITE_UNIQUE, CMO_CLEAN_SH_PER_SEP,
                                     partial=True)
    self._check_completions(log, CMO_CLEAN_SH_PER_SEP,
                            "WriteUniquePtlCleanShPerSep")

    assert coh.get_multi_owner_count() == 0, \
      "combined Write + CMO produced a multi-owner violation"
    assert coh.get_coherent_data_mismatch_count() == 0, \
      "combined Write + CMO produced a data mismatch"

    self.logger.info("Test (coh_combined_write_cmo) PASS: six coherent "
                     "combined forms, each answered with CompCMO")
    self.drop_objection()
