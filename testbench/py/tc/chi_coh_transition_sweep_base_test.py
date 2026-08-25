################################################################################
# pyUVM port of tc/chi_coh_transition_sweep_base_test.sv.
#
# Sweep (from-state x snoop-op) cache transitions: for each initial state {SC, UC,
# UD} on a fresh line, prime RN-F0 into it then run each of 7 coherent ops on
# RN-F1, driving many distinct snoop transitions. Asserts the sweep actually
# originated snoops (>= 10). Functional coverage is observational (0.0 here).
#
# A SECOND sweep primes the REQUESTING node and issues on the SAME line, which is
# the axis this test did not have. Priming only the snoopee leaves the requester
# Invalid for every combination, and a Requester that holds nothing cannot tell
# "final state = the granted Resp" apart from "final state = what the grant adds
# to what was held" -- the two agree on every from-Invalid row of Table 4-14.
# That is what let the held-state half of the table go missing with a fully green
# regression behind it. The rows that separate the two are the ones
# where the grant is WEAKER than what the Requester already had: a UD holder
# issuing ReadClean is granted CompData_SC and must stay UD.
################################################################################

from __future__ import annotations

from chi_coherent_base_test import chi_coherent_base_test
from vip_chi_readshared_seq import vip_chi_readshared_seq
from vip_chi_readclean_seq import vip_chi_readclean_seq
from vip_chi_readunique_seq import vip_chi_readunique_seq
from vip_chi_readonce_seq import vip_chi_readonce_seq
from vip_chi_cleaninvalid_seq import vip_chi_cleaninvalid_seq
from vip_chi_makeinvalid_seq import vip_chi_makeinvalid_seq
from vip_chi_makeunique_seq import vip_chi_makeunique_seq
from chi_tb_pkg import WRITE_READ_ADDR_C

_LINE_STRIDE = 0x40
_N_STATES = 3
_N_OPS = 7
_MIN_SNOOPS = 10
# Only the UD priming leaves a dirty holder, and two of the seven opcodes
# (MakeInvalid, MakeUnique) make the Home send SnpMakeInvalid, so the sweep
# provokes the no-data-snoop rule exactly twice.
_MIN_NO_DATA_SNOOPS_ON_DIRTY = 2
# The sweep drives 3 initial states x 7 opcodes, and every snoop it provokes is
# answered, so D5 has plenty to judge. Ten is a floor well under that, chosen so
# the assertion catches the rule going dark rather than tracking the exact count.
_MIN_SNP_RESP_JUDGED = 10
# Distinct (snoop opcode, resp state, with-data) triples the cross should reach.
_MIN_SNP_RESP_TRIPLES = 3
# The requester-priming sweep: 3 primed states {SC, UC, UD} x 4 requests
# {ReadShared, ReadClean, ReadUnique, MakeUnique}.
_N_REQ_STATES = 3
_N_REQ_OPS = 4
# Of those 12, the held state changes the answer in exactly 5 -- the rows where
# the grant is weaker than what was held. Enumerated rather than approximated,
# because this count IS the evidence that the rule was exercised:
#   UC + ReadShared -> UC (granted SC)    UD + ReadShared -> UD (granted SC)
#   UC + ReadClean  -> UC (granted SC)    UD + ReadClean  -> UD (granted SC)
#                                         UD + ReadUnique -> UD (granted UC)
# The from-SC row retains nothing (SC is the weakest state that holds anything),
# and MakeUnique reaches UD from its opcode rather than from the held state, so
# it is correctly not counted -- see resolve_req_final_state.
_MIN_REQ_FINAL_RETAINED = 5
# Requester-sweep request kinds, indexing _SEQ_BY_KIND.
_REQ_SWEEP_KINDS = (0, 1, 2, 6)
_SEQ_BY_KIND = (
  vip_chi_readshared_seq, vip_chi_readclean_seq, vip_chi_readunique_seq,
  vip_chi_readonce_seq, vip_chi_cleaninvalid_seq, vip_chi_makeinvalid_seq,
  vip_chi_makeunique_seq,
)


class chi_coh_transition_sweep_base_test(chi_coherent_base_test):

  async def _run_op(self, node, line, kind):
    seq = _SEQ_BY_KIND[kind](f"sw_{kind}", cfg=self.chi_cfg)
    self.cfg_read_seq(seq, line)
    sequencer = (self.tb_env.hrnf0_agent.sequencer if node == 0
                 else self.tb_env.hrnf1_agent.sequencer)
    await seq.start(sequencer)
    seq.get_responses()

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    idx = 0
    for st in range(_N_STATES):
      for op in range(_N_OPS):
        line = WRITE_READ_ADDR_C + idx * _LINE_STRIDE
        idx += 1
        # Prime RN-F0 into the initial state: ReadShared->SC, ReadUnique->UC,
        # MakeUnique->UD.
        prime_kind = {0: 0, 1: 2}.get(st, 6)
        await self._run_op(0, line, prime_kind)
        await self._run_op(1, line, op)

    # Requester axis. Same shape, but the node that is primed is the node that
    # then issues, and it issues on the line it already holds -- so the
    # completion arrives at a Requester in a known non-Invalid state and Table
    # 4-14 has to combine the two. The sweep above can never produce this: it
    # issues from RN-F1 on lines only RN-F0 ever touched.
    for st in range(_N_REQ_STATES):
      for op in _REQ_SWEEP_KINDS:
        line = WRITE_READ_ADDR_C + idx * _LINE_STRIDE
        idx += 1
        # Prime RN-F1 -- the requester this time -- exactly as above: UD comes
        # from MakeUnique so the state is observable rather than silently local.
        await self._run_op(1, line, {0: 0, 1: 2}.get(st, 6))
        # ...and now issue again, on the SAME line, from the SAME node.
        await self._run_op(1, line, op)

    await self.wait_clocks(16)

    snoops = self.tb_env.coh_checker.get_snoop_count()
    cov = self.tb_env.coh_checker.get_cache_transition_coverage()
    self.logger.info(
      f"[coh_transition_sweep] {idx} directed combinations, {snoops} snoops "
      f"observed; cg_cache_transition = {cov:.1f}% (observational)")
    assert snoops >= _MIN_SNOOPS, \
      f"transition sweep drove only {snoops} snoops (< {_MIN_SNOOPS})"
    assert not (0.0 < cov < 99.0), \
      f"transition sweep left cg_cache_transition at {cov:.1f}%"

    # Two of the seven opcodes make the Home send SnpMakeInvalid to a UD holder
    # (MakeInvalid and MakeUnique), so this sweep is where a snoopee answering a
    # no-data snoop on DAT shows up. Asserted here and not only in the checker
    # because the to-state of that transition is correct either way -- which is
    # exactly why cg_cache_transition recorded the tuple as covered while the
    # response beside it was wrong.
    bad_form = self.tb_env.coh_checker.get_bad_snp_resp_form_count()
    assert bad_form == 0, \
      f"transition sweep saw {bad_form} snoop response(s) carrying data for a " \
      f"snoop that returns none"

    # ...and that the rule had something to judge. A zero above means nothing on
    # its own: a clean holder answers on RSP whatever the opcode says, so only a
    # no-data snoop reaching a dirty holder can distinguish the fixed behaviour
    # from the broken one. Without this the check goes silently vacuous the day
    # the Home stops sending SnpMakeInvalid here.
    provoked = self.tb_env.coh_checker.get_snp_no_data_on_dirty_count()
    assert provoked >= _MIN_NO_DATA_SNOOPS_ON_DIRTY, \
      f"transition sweep drove only {provoked} no-data snoop(s) to a dirty " \
      f"holder (< {_MIN_NO_DATA_SNOOPS_ON_DIRTY}) -- the response-form rule was " \
      f"never provoked"

    # Catalogue rule D5: the response STATE against the snoop opcode. Both halves
    # again -- no violation, and evidence the rule had responses to judge. This
    # sweep is where D5 gets its stimulus: every snoop opcode the home originates
    # against a primed cache state.
    bad_state = self.tb_env.coh_checker.get_bad_snp_resp_state_count()
    assert bad_state == 0, \
      f"transition sweep saw {bad_state} snoop response(s) reporting a state " \
      f"Chapter 4 does not permit for the snoop that asked"

    judged = self.tb_env.coh_checker.get_snp_resp_judged_count()
    assert judged >= _MIN_SNP_RESP_JUDGED, \
      f"D5 judged only {judged} snoop response(s) (< {_MIN_SNP_RESP_JUDGED}); a " \
      f"zero violation count above means nothing if nothing reached the rule"

    # Catalogue rule D6, and the adoption it guards. The snooped node's next
    # state is now taken FROM the response rather than derived from the opcode,
    # so three things have to hold together.
    #
    # No response reported a state the snoopee could not have reached:
    gains = self.tb_env.coh_checker.get_snp_resp_gains_permission_count()
    assert gains == 0, \
      f"transition sweep saw {gains} snoop response(s) reporting a permission " \
      f"the snoopee did not hold when the snoop arrived"

    # ...every judged response was adopted. With D5 and D6 both clean this is an
    # identity, and that is exactly why it is worth asserting: if it ever parts, a
    # response was judged legal and still failed to reach the shadow, which is the
    # desynchronization this rule exists to prevent -- silent, and visible only as
    # later checks failing somewhere else.
    adopted = self.tb_env.coh_checker.get_snp_resp_adopted_count()
    assert adopted == judged, \
      f"{judged} snoop response(s) judged but only {adopted} adopted into the " \
      f"shadow, with no violation reported for the difference"

    # ...and the adoption path actually ran. Same non-vacuity discipline as the
    # counts above: adopted=0 would satisfy both assertions.
    assert adopted >= _MIN_SNP_RESP_JUDGED, \
      f"only {adopted} snoop response(s) reached the shadow " \
      f"(< {_MIN_SNP_RESP_JUDGED}); the adoption path was never exercised"

    # Reported, not asserted. This VIP's own RN-F implements exactly the mapping
    # snoop_result() encodes, so the expected value here is 0 -- and a 0 is only
    # meaningful because the counts above prove responses were adopted at all. It
    # is the first number to read against a DUT: non-zero says the peer resolved a
    # snoop somewhere the derived model did not predict, which is the whole reason
    # the state is taken from the response.
    self.logger.info(
      f"snoop responses adopted={adopted}, of which "
      f"{self.tb_env.coh_checker.get_snp_resp_state_differs_count()} differed "
      f"from the derived prediction")

    # ...and that the cross actually spread. One triple repeated N times would
    # satisfy the count above while covering a single point of the surface.
    triples = self.tb_env.coh_checker.get_snp_resp_legality_tuples()
    assert len(triples) >= _MIN_SNP_RESP_TRIPLES, \
      f"the snoop-response legality cross reached only {len(triples)} distinct " \
      f"(opcode, state, with-data) triple(s) (< {_MIN_SNP_RESP_TRIPLES})"

    # The requester axis. Same three-part discipline as D5/D6
    # above: the rule ran, it ran on the inputs that distinguish it, and nothing
    # it judged was illegal.
    #
    # req_final_retained is the load-bearing count. It rises only where the
    # Requester's held state changed the answer -- which is nothing at all unless
    # the stimulus primes the requesting node, and priming the requesting node is
    # exactly what no test in either port did before. A regression can be green
    # end to end with this at 0 and the whole held-state half of Table 4-14
    # missing, which is how the defect survived.
    req_judged = self.tb_env.coh_checker.get_req_final_judged_count()
    assert req_judged > 0, \
      "the requester final-state rule judged nothing -- no coherent read completed"

    retained = self.tb_env.coh_checker.get_req_final_retained_count()
    assert retained >= _MIN_REQ_FINAL_RETAINED, \
      f"only {retained} completion(s) had their final state decided by the held " \
      f"state (< {_MIN_REQ_FINAL_RETAINED}); the requester was Invalid " \
      f"throughout, so Table 4-14's held-state half was never exercised"

    # A data-less completion must carry a Resp encoding its request's table
    # permits. MakeUnique is the case the sweep drives: Table 4-19 (D Table 4-13)
    # gives it Comp_UC, and issue D does not define UD_PD for a data-less
    # completion at all.
    bad_dataless = self.tb_env.coh_checker.get_bad_dataless_resp_count()
    assert bad_dataless == 0, \
      f"transition sweep saw {bad_dataless} data-less completion(s) carrying a " \
      f"Resp encoding the request's table does not permit"

    self.logger.info(
      f"requester final state: judged={req_judged}, of which {retained} were "
      f"decided by the state the requester already held")

    self.logger.info("Test (coh_transition_sweep) PASS")
    self.drop_objection()
