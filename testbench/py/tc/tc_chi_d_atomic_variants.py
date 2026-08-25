################################################################################
# pyUVM/cocotb port of tc/tc_chi_d_atomic_variants.sv.
#
# Sweep every AtomicStore/AtomicLoad arithmetic variant (add / clr / eor / set /
# smax / smin / umax / umin) plus AtomicSwap and AtomicCompare (hit + miss)
# through the integrated RN-I/SN-F path. Each op RMWs a fresh untouched row (whose
# seed value is its own address); an independent reference model predicts the
# post-op value and a readback confirms it. Returning-data ops (load/swap/compare)
# also return the pre-op value.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import (
  AtomicOp, ReqOpcode, RspOpcode, DatOpcode, atomic_op_to_req_opcode, mask, clog2,
)
from chi_base_test import chi_base_test
import chi_atomic_size_stress as atomic_size_stress
from vip_chi_atomic_seq import (
  vip_chi_atomic_store_seq, vip_chi_atomic_load_seq,
  vip_chi_atomic_swap_seq, vip_chi_atomic_compare_seq,
)
from chi_tb_pkg import ATOMIC_VARIANT_BASE_ADDR_C, ATOMIC_VARIANT_ADDR_STRIDE_C


class tc_chi_d_atomic_variants(chi_base_test):

  def _variant_addr(self, index):
    return ATOMIC_VARIANT_BASE_ADDR_C + index * ATOMIC_VARIANT_ADDR_STRIDE_C

  def _variant_operand(self, variant):
    dw = self.chi_cfg.data_bytes * 8
    return [0x10, 0x0F, 0x55, 0xA0, mask(dw), mask(dw), mask(dw), 0][variant]

  def _apply_variant(self, variant, current, operand):
    dw = self.chi_cfg.data_bytes * 8
    m = mask(dw)
    cur = current & m
    opd = operand & m
    sign = 1 << (dw - 1)
    cur_s = cur - (1 << dw) if cur & sign else cur
    opd_s = opd - (1 << dw) if opd & sign else opd
    if variant == 0:
      return (cur + opd) & m
    if variant == 1:
      return cur & (~opd & m)
    if variant == 2:
      return cur ^ opd
    if variant == 3:
      return cur | opd
    if variant == 4:
      return cur if cur_s > opd_s else opd
    if variant == 5:
      return cur if cur_s < opd_s else opd
    if variant == 6:
      return cur if cur > opd else opd
    return cur if cur < opd else opd

  async def _readback_expect(self, addr, beat_size, expected, label):
    rd = self.rni0_rd_seq
    rd.reset()
    rd.set_requests(1)
    rd.set_initial_addr(addr)
    rd.set_size(beat_size)
    rd.set_get_response(True)
    rd.set_verbose(False)
    await rd.start(self.v_sqr.rni_sequencer)
    resp = rd.get_responses()
    got = int(resp[0].data[0]) if resp and len(resp[0].data) else None
    assert len(resp) == 1 and len(resp[0].data) == 1 and got == (expected & mask(self.chi_cfg.data_bytes * 8)), \
      f"{label} readback mismatch expected 0x{expected:x} got {got if got is None else hex(got)}"

  async def _run_store_variant(self, variant, addr, beat_size):
    operand = self._variant_operand(variant)
    expected = self._apply_variant(variant, addr, operand)

    seq = vip_chi_atomic_store_seq("atomic_store_seq", cfg=self.chi_cfg)
    seq.reset()
    seq.set_variant(variant)
    seq.set_atomic_oversized_operands(True)
    seq.set_requests(1)
    seq.set_initial_addr(addr)
    seq.set_size(beat_size)
    seq.set_get_response(True)
    seq.set_verbose(False)

    preview = seq.preview_next_request()
    exp_op = atomic_op_to_req_opcode(int(AtomicOp.STORE_0) + variant)
    assert int(preview.opcode) == exp_op, \
      f"AtomicStore{variant} preview opcode 0x{int(preview.opcode):x} unexpected"

    seq.set_data([operand])
    await seq.start(self.v_sqr.rni_sequencer)
    resp = seq.get_responses()
    assert len(resp) == 1 and int(resp[0].rsp_opcode) == int(RspOpcode.COMP_DBID_RESP), \
      f"AtomicStore{variant} completion was not CompDBIDResp"

    await self._readback_expect(addr, beat_size, expected, f"AtomicStore{variant}")

  async def _run_load_variant(self, variant, addr, beat_size):
    operand = self._variant_operand(variant)
    expected = self._apply_variant(variant, addr, operand)

    seq = vip_chi_atomic_load_seq("atomic_load_seq", cfg=self.chi_cfg)
    seq.reset()
    seq.set_variant(variant)
    seq.set_atomic_oversized_operands(True)
    seq.set_requests(1)
    seq.set_initial_addr(addr)
    seq.set_size(beat_size)
    seq.set_get_response(True)
    seq.set_verbose(False)

    preview = seq.preview_next_request()
    exp_op = atomic_op_to_req_opcode(int(AtomicOp.LOAD_0) + variant)
    assert int(preview.opcode) == exp_op, \
      f"AtomicLoad{variant} preview opcode 0x{int(preview.opcode):x} unexpected"

    seq.set_data([operand])
    await seq.start(self.v_sqr.rni_sequencer)
    resp = seq.get_responses()
    assert (len(resp) == 1 and int(resp[0].dat_opcode) == int(DatOpcode.COMP_DATA) and
            len(resp[0].data) == 1 and int(resp[0].data[0]) == (addr & mask(self.chi_cfg.data_bytes * 8))), \
      f"AtomicLoad{variant} did not return the expected pre-op value"

    await self._readback_expect(addr, beat_size, expected, f"AtomicLoad{variant}")

  async def _run_swap_case(self, addr, beat_size, operand):
    seq = vip_chi_atomic_swap_seq("atomic_swap_seq", cfg=self.chi_cfg)
    seq.reset()
    seq.set_requests(1)
    seq.set_initial_addr(addr)
    seq.set_atomic_oversized_operands(True)
    seq.set_size(beat_size)
    seq.set_get_response(True)
    seq.set_verbose(False)

    preview = seq.preview_next_request()
    assert int(preview.opcode) == int(ReqOpcode.ATOMIC_SWAP), \
      f"AtomicSwap preview opcode 0x{int(preview.opcode):x} unexpected"

    seq.set_data([operand])
    await seq.start(self.v_sqr.rni_sequencer)
    resp = seq.get_responses()
    assert (len(resp) == 1 and len(resp[0].data) == 1 and
            int(resp[0].data[0]) == (addr & mask(self.chi_cfg.data_bytes * 8))), \
      "AtomicSwap did not return the expected pre-swap value"

    await self._readback_expect(addr, beat_size, operand, "AtomicSwap")

  async def _run_compare_case(self, addr, beat_size, compare_value, swap_value,
                              expect_match, label):
    expected = swap_value if expect_match else addr

    seq = vip_chi_atomic_compare_seq("atomic_compare_seq", cfg=self.chi_cfg)
    seq.reset()
    seq.set_requests(1)
    seq.set_initial_addr(addr)
    # AtomicCompare Size is the COMBINED compare+swap size: two beat_size operands
    # span Size = beat_size + 1. readback reads the per-operand granule (beat_size).
    seq.set_size(beat_size + 1)
    seq.set_get_response(True)
    seq.set_verbose(False)

    preview = seq.preview_next_request()
    assert int(preview.opcode) == int(ReqOpcode.ATOMIC_COMPARE) and len(preview.data) == 2, \
      f"{label} preview request did not carry the expected compare/swap payload"

    seq.set_data([compare_value, swap_value])
    await seq.start(self.v_sqr.rni_sequencer)
    resp = seq.get_responses()
    assert (len(resp) == 1 and len(resp[0].data) == 1 and
            int(resp[0].data[0]) == (addr & mask(self.chi_cfg.data_bytes * 8))), \
      f"{label} did not return the expected pre-compare value"

    await self._readback_expect(addr, beat_size, expected, label)

  async def run_phase(self):
    self.raise_objection()
    # The wide-operand stress profile is out of spec by Table 2-17, on purpose.
    # arm() silences the rule and keeps its tally; assert_reported() below turns
    # the waiver into its own control. See chi_atomic_size_stress.
    _checkers = (self.tb_env.rni_sva, self.tb_env.snf_sva)
    atomic_size_stress.arm(_checkers)

    beat_size = clog2(self.chi_cfg.data_bytes)

    for variant in range(8):
      await self._run_store_variant(variant, self._variant_addr(variant), beat_size)

    for variant in range(8):
      await self._run_load_variant(variant, self._variant_addr(8 + variant), beat_size)

    await self._run_swap_case(self._variant_addr(16), beat_size, 0x4455)

    await self._run_compare_case(
      self._variant_addr(17), beat_size, self._variant_addr(17), 0x99AA, True,
      "AtomicCompareHit")

    await self._run_compare_case(
      self._variant_addr(18), beat_size, self._variant_addr(18) ^ 0x1, 0x55AA, False,
      "AtomicCompareMiss")

    self.logger.info(
      "Test (tc_chi_d_atomic_variants) PASS: all atomic store/load variants + "
      "swap + compare (hit/miss) RMW'd and read back correctly")
    atomic_size_stress.assert_reported(_checkers, "the atomic operands above")
    self.drop_objection()
