################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of tc/chi_coh_partial_dirty_merge_base_test.sv.
#
# The MERGE half of IHI 0050 E Table 4-14 footnote c: "Data received from memory
# must be dropped if the cache state is UD or SD, or merged if the cache state is
# UDP."
#
# UDP is a state the WIRE cannot express. Table 4-6 gives UD and UDP the same
# Resp encoding, UD_PD, so nothing on the link says which bytes of a dirty line
# are dirty -- and until the requester kept a per-beat dirty byte mask, the VIP
# could not represent the difference either. Every dirty line was fully dirty, so
# the footnote's drop half was the whole of it and the merge case could not
# arise.
#
# The scenario is the one place a UDP line comes from cleanly, and each step is
# load-bearing:
#
#   MakeUnique grants Unique-Dirty with NO data transfer. The line is now owned
#   and its contents are whatever the requester makes them -- this model
#   materializes zeros -- so no byte of it is real memory content.
#
#   A PARTIAL local store dirties some of those bytes. Now the line is genuinely
#   UDP: the stored bytes are the newest copy in the system, and the rest are
#   filler this cache was never given.
#
#   A read then fetches the line from memory. This is the moment the footnote is
#   about, and all three outcomes are wrong except one.
#
# What the two assertions below separate:
#
#   TAKE  -- the fetch over the top -- loses the store. The dirty bytes would
#            read back as memory.
#   DROP  -- keep everything held -- loses the clean bytes, which were never
#            real. They would read back as the MakeUnique zeros.
#   MERGE -- dirty bytes from the store, everything else from the fetch.
#
# DROP is not a hypothetical: it is exactly what this VIP did before the mask
# existed, because the held state was UD_PD and that was the whole question. So
# the clean-byte assertion is the mutation proof as well as the requirement.
#
# The precondition is asserted rather than assumed: if memory happened to hold
# zeros under the clean bytes, MERGE and DROP would agree and the test would pass
# without testing anything.
#
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Resp
from chi_coherent_base_test import chi_coherent_base_test
from vip_chi_readclean_seq import vip_chi_readclean_seq
from vip_chi_makeunique_seq import vip_chi_makeunique_seq
from chi_tb_pkg import WRITE_READ_ADDR_C

_LINE_C = WRITE_READ_ADDR_C


class chi_coh_partial_dirty_merge_base_test(chi_coherent_base_test):

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    drv = self.tb_env.hrnf1_agent.rnf_driver
    data_bytes = self.chi_cfg.data_bytes

    # Every other byte, so both halves of every beat have something to say.
    dirty_be = sum(1 << b for b in range(0, data_bytes, 2))
    dirty_bits = drv.be_to_bitmask(dirty_be)
    store_pattern = int("5A" * data_bytes, 16)

    mu_seq = vip_chi_makeunique_seq("hrnf1_mu_seq", cfg=self.chi_cfg)
    self.cfg_read_seq(mu_seq)
    await mu_seq.start(self.tb_env.hrnf1_agent.sequencer)
    mu_seq.get_responses()

    drv.make_line_dirty_partial(_LINE_C, store_pattern, dirty_be)

    held, mask = drv.get_cache_line(_LINE_C)
    assert mask and any(m != (1 << data_bytes) - 1 for m in mask), (
      "the partial store did not leave a partial dirty mask, so the line is not "
      "UDP and the merge case is not the one being exercised")
    assert drv.get_cache_state(_LINE_C) == int(Resp.UD_PD), \
      "a local store must leave the line Unique-Dirty"

    rc_seq = vip_chi_readclean_seq("hrnf1_rdclean_seq", cfg=self.chi_cfg)
    self.cfg_read_seq(rc_seq)
    await rc_seq.start(self.tb_env.hrnf1_agent.sequencer)
    rsp = rc_seq.get_responses()
    assert len(rsp) == 1, "RN-F1's read never completed"
    fetched = [int(x) for x in rsp[0].data]

    await self.wait_clocks(8)

    merged, _ = drv.get_cache_line(_LINE_C)
    assert len(merged) == len(fetched), (
      f"the line holds {len(merged)} beat(s) against {len(fetched)} fetched")

    # Without this the test would pass on a memory image of zeros, where merging
    # and dropping cannot be told apart.
    assert any(f & ~dirty_bits for f in fetched), (
      "memory holds zeros under every clean byte of this line, so a merge and a "
      "drop produce the same image and this test proves nothing")

    for i, (got, fetch) in enumerate(zip(merged, fetched)):
      want_dirty = store_pattern & dirty_bits
      assert (got & dirty_bits) == want_dirty, (
        f"beat {i}: the locally stored bytes read back as "
        f"0x{got & dirty_bits:x}, expected 0x{want_dirty:x}; the fetch was "
        f"taken over the top of the store and the newest copy in the system is "
        f"gone")
      assert (got & ~dirty_bits) == (fetch & ~dirty_bits), (
        f"beat {i}: the clean bytes read back as 0x{got & ~dirty_bits:x}, "
        f"expected the fetched 0x{fetch & ~dirty_bits:x}; the fetch was dropped "
        f"whole, which keeps bytes this cache was never given")

    # The line is still Unique and still dirty in those bytes: only the clean
    # ones changed hands, and the requester still owes the dirty ones on.
    assert drv.get_cache_state(_LINE_C) == int(Resp.UD_PD), \
      "the merge left the line no longer Unique-Dirty"
    _, after = drv.get_cache_line(_LINE_C)
    assert after == mask, \
      "the merge changed the dirty mask; a merge moves bytes, not ownership"

    self.logger.info(
      f"Test (coh_partial_dirty_merge) PASS: a UDP line took a fill and kept "
      f"its {bin(dirty_be).count('1')} stored byte(s) per beat while the "
      f"remainder came from memory")
    self.drop_objection()
