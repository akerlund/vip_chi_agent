################################################################################
# pyUVM port of tc/chi_coh_req_retain_base_test.sv.
#
# The Requester's final cache state is a function of what it HELD as well as what
# the completion GRANTED -- IHI 0050 E Table 4-14 (D Table 4-12). Directed
# positive test for the row that separates that rule from taking the granted Resp
# verbatim: a Unique-Dirty holder issuing ReadClean receives CompData_SC and must
# stay UD, keeping its locally-modified beats (Table 4-14 footnote c).
#
# RN-F0's read at the end is what makes the data half observable: a local store
# leaves no trace on the wire, so the only way to ask whether the dirtied bytes
# survived the ReadClean is to make someone else read the line back.
#
# The line is acquired with MakeUnique rather than ReadUnique + make_line_dirty
# so the CHECKER's shadow holds Dirty too. A local store is silent to the checker
# as well as to the home, so ReadUnique priming would leave the shadow at UC and
# catalogue rule D7 would have nothing to judge at the snoop -- the assertion
# below would then pass without the rule having run. MakeUnique is the one path
# in this VIP that grants an OBSERVABLE Unique-Dirty. It also makes this test and
# its negative control differ in exactly one thing, the knob.
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Resp
from chi_coherent_base_test import chi_coherent_base_test
from vip_chi_readclean_seq import vip_chi_readclean_seq
from vip_chi_makeunique_seq import vip_chi_makeunique_seq
from chi_tb_pkg import WRITE_READ_ADDR_C


class chi_coh_req_retain_base_test(chi_coherent_base_test):

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    dirty_pattern = int("5A" * self.chi_cfg.data_bytes, 16)

    # 1) RN-F1 acquires the line Unique-Dirty, observably: MakeUnique transfers
    #    no data, so the driver materializes an all-zero image of the line.
    mu_seq = vip_chi_makeunique_seq("hrnf1_mu_seq", cfg=self.chi_cfg)
    self.cfg_read_seq(mu_seq)
    await mu_seq.start(self.tb_env.hrnf1_agent.sequencer)
    mu_rsp = mu_seq.get_responses()

    # 2) Model a local store on top of it. Nothing on the wire says so -- which
    #    is why the checker must not try to derive the data, and why the read-back
    #    in step 4 is the only way to test it. Zeros XOR the pattern is the
    #    pattern, so the expected beats below are known exactly.
    self.tb_env.hrnf1_agent.rnf_driver.make_line_dirty(WRITE_READ_ADDR_C, dirty_pattern)

    retained_before = self.tb_env.coh_checker.get_req_final_retained_count()

    # 3) The row under test: the SAME node reads the SAME line it already holds
    #    Unique-Dirty, with a request whose grant is weaker than what it holds.
    rc_seq = vip_chi_readclean_seq("hrnf1_rdclean_seq", cfg=self.chi_cfg)
    self.cfg_read_seq(rc_seq)
    await rc_seq.start(self.tb_env.hrnf1_agent.sequencer)
    clean_rsp = rc_seq.get_responses()

    assert len(mu_rsp) == 1 and len(clean_rsp) == 1, \
      f"expected 1+1 responses, got {len(mu_rsp)}/{len(clean_rsp)}"
    # The grant really is the weaker one -- without this the test could pass by
    # the home happening to return UC, and the retention rule would never have
    # been asked anything.
    assert int(clean_rsp[0].rsp_resp) == int(Resp.SC), \
      f"ReadClean granted 0x{int(clean_rsp[0].rsp_resp):x}, expected SC -- the " \
      f"scenario needs a grant weaker than the held state"

    await self.wait_clocks(8)

    # 4a) The state limb. Table 4-14: UD + CompData_SC -> UD.
    rnf1_state = self.tb_env.hrnf1_agent.rnf_driver.get_cache_state(WRITE_READ_ADDR_C)
    assert rnf1_state == int(Resp.UD_PD), \
      f"RN-F1 cache 0x{rnf1_state:x} after ReadClean from Unique-Dirty, expected " \
      f"UD: the granted SC was taken verbatim and a writeback obligation dropped"

    # ...and the home did not DOWNGRADE its snoop filter on the back of its own
    # response. Table 4-14 footnote b: "a Home that uses a Snoop filter ... must
    # not downgrade the state of the cache line in the Snoop filter based on the
    # state in the response to the Requester." Here the home CAN track the dirty
    # -- MakeUnique granted it observably in step 1 -- so the entry must still
    # read UD after the home itself answered CompData_SC. A filter that wrote the
    # grant verbatim would believe the only modified copy in the system is clean
    # and could serve the next reader from memory without asking for it.
    dir_state = self.tb_env.hnf_agent.hnf_driver.get_directory_port_state(
      WRITE_READ_ADDR_C, 1)
    assert dir_state == int(Resp.UD_PD), \
      f"HN-F directory port1 0x{dir_state:x} after granting SC to a " \
      f"Unique-Dirty holder, expected the retained UD"

    # ...and the checker judged this completion as one the held state decided.
    assert self.tb_env.coh_checker.get_req_final_retained_count() > retained_before, \
      "the coherency checker did not record the ReadClean as held-state-decided " \
      "-- its shadow took the granted Resp verbatim"

    # 4b) The data limb. RN-F0 reads the line, so the home must snoop RN-F1 --
    #     which is still dirty and must forward its MODIFIED beats. If the
    #     ReadClean had overwritten them with the fetched copy, what comes back
    #     here is the undirtied line and nothing else would ever have noticed.
    self.cfg_read_seq(self.hrnf0_rdshared_seq)
    await self.hrnf0_rdshared_seq.start(self.tb_env.hrnf0_agent.sequencer)
    shared_rsp = self.hrnf0_rdshared_seq.get_responses()

    assert len(shared_rsp) == 1, f"expected 1 ReadShared response, got {len(shared_rsp)}"
    # MakeUnique materialized zeros, so the dirtied line is exactly the pattern.
    for i in range(len(shared_rsp[0].data)):
      assert int(shared_rsp[0].data[i]) == dirty_pattern, \
        f"beat {i} read back 0x{int(shared_rsp[0].data[i]):x}, expected the " \
        f"dirtied 0x{dirty_pattern:x}: the ReadClean overwrote the " \
        f"locally-modified beats"

    # The forwarding snoop above is a Dirty snoopee answering a data-returning
    # snoop, which is catalogue rule D7's provoking case, and the shadow really
    # does hold Dirty here (step 1 made it observable) -- so the rule evaluated
    # rather than being skipped. Its negative control drives the same snoop with
    # the verbatim knob set and requires this count to RISE.
    assert self.tb_env.coh_checker.get_snp_dirty_lost_count() == 0, \
      "a snoop response dropped a dirty copy instead of passing it on"
    assert self.tb_env.coh_checker.get_multi_owner_count() == 0, \
      "multi-owner violations on a legal retention"

    self.logger.info("Test (coh_req_retain) PASS")
    self.drop_objection()
