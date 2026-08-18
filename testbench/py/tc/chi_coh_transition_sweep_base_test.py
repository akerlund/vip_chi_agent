################################################################################
# pyUVM port of tc/chi_coh_transition_sweep_base_test.sv.
#
# Sweep (from-state x snoop-op) cache transitions: for each initial state {SC, UC,
# UD} on a fresh line, prime RN-F0 into it then run each of 7 coherent ops on
# RN-F1, driving many distinct snoop transitions. Asserts the sweep actually
# originated snoops (>= 10). Functional coverage is observational (0.0 here).
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

    # ...and that the cross actually spread. One triple repeated N times would
    # satisfy the count above while covering a single point of the surface.
    triples = self.tb_env.coh_checker.get_snp_resp_legality_tuples()
    assert len(triples) >= _MIN_SNP_RESP_TRIPLES, \
      f"the snoop-response legality cross reached only {len(triples)} distinct " \
      f"(opcode, state, with-data) triple(s) (< {_MIN_SNP_RESP_TRIPLES})"

    self.logger.info("Test (coh_transition_sweep) PASS")
    self.drop_objection()
