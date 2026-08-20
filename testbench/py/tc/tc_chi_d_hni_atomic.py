################################################################################
# pyUVM/cocotb port of tc/tc_chi_d_hni_atomic.sv.
#
# An AtomicStore0 through the proxy: exercises the HN-I's atomic/write settle
# path and the RN->SN write-DAT (operand) relay. Confirms the SN-F on the far
# side observed a forwarded atomic opcode at the right address and the RN-I got
# its single completion back.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import AtomicOp, clog2, req_opcode_is_atomic
from chi_hni_base_test import chi_hni_base_test
from vip_chi_atomic_seq import vip_chi_atomic_seq
from chi_tb_pkg import WRITE_READ_ADDR_C
import chi_atomic_size_stress as atomic_size_stress


class tc_chi_d_hni_atomic(chi_hni_base_test):

  async def run_phase(self):
    self.raise_objection()
    # The wide-operand stress profile is out of spec by Table 2-17, on purpose.
    # arm() silences the rule and keeps its tally; assert_reported() below turns
    # the waiver into its own control. Every proxy bind, because an atomic here
    # crosses the RN-facing link, the proxy's own pair and the SN-facing link.
    _checkers = tuple(self.tb_env.hni_sva)
    atomic_size_stress.arm(_checkers)
    beat_size = clog2(self.chi_cfg.data_bytes)

    atomic_seq = vip_chi_atomic_seq("atomic_seq", cfg=self.chi_cfg)
    atomic_seq.reset()
    atomic_seq.set_atomic_op(AtomicOp.STORE_0)
    atomic_seq.set_requests(1)
    atomic_seq.set_initial_addr(WRITE_READ_ADDR_C)
    atomic_seq.set_size(beat_size)
    atomic_seq.set_allow_retry(0)
    atomic_seq.set_get_response(True)
    atomic_seq.set_data([0x10])
    atomic_seq.set_verbose(False)
    await atomic_seq.start(self.v_sqr.hrni0_sequencer)

    responses = atomic_seq.get_responses()
    assert len(responses) == 1, \
      f"expected 1 atomic response through the proxy, got {len(responses)}"

    snf_req = await self.tb_env.hsnf0_req_fifo.get()
    assert req_opcode_is_atomic(int(snf_req.opcode)), \
      f"SN-F did not receive a forwarded atomic opcode (got 0x{int(snf_req.opcode):x})"
    assert int(snf_req.addr) == WRITE_READ_ADDR_C, \
      f"forwarded atomic address 0x{int(snf_req.addr):x} != 0x{WRITE_READ_ADDR_C:x}"

    self.logger.info(
      "Test (tc_chi_d_hni_atomic) PASS: HN-I relayed an AtomicStore end-to-end "
      "(RN-I -> HN-I -> SN-F)")
    atomic_size_stress.assert_reported(_checkers, "the atomic operands above")
    self.drop_objection()
