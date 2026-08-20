################################################################################
# pyUVM/cocotb port of tc/tc_chi_d_atomic.sv.
#
# Drives AtomicStore0 (ADD), AtomicLoad0 (ADD, returns pre-op), AtomicSwap, and
# AtomicCompare (combined compare+swap Size) at one address and checks the
# operand DAT, the returned pre-op CompData, and that the SN-F backing store is
# updated at each step (final readback == the compare swap value).
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import (
  Role, AtomicOp, ReqOpcode, RspOpcode, DatOpcode, clog2,
)
from chi_base_test import chi_base_test
import chi_atomic_size_stress as atomic_size_stress
from vip_chi_atomic_seq import vip_chi_atomic_seq
from chi_tb_pkg import ATOMIC_ADDR_C


class tc_chi_d_atomic(chi_base_test):

  async def _atomic(self, op, size, operands):
    seq = vip_chi_atomic_seq("atomic_seq", cfg=self.chi_cfg)
    seq.reset()
    seq.set_atomic_op(op)
    seq.set_requests(1)
    seq.set_initial_addr(ATOMIC_ADDR_C)
    seq.set_size(size)
    seq.set_allow_retry(0)
    seq.set_get_response(True)
    seq.set_verbose(False)
    seq.set_data(list(operands))
    await seq.start(self.v_sqr.rni_sequencer)
    return seq.get_responses()

  async def run_phase(self):
    self.raise_objection()
    # The wide-operand stress profile is out of spec by Table 2-17, on purpose.
    # arm() silences the rule and keeps its tally; assert_reported() below turns
    # the waiver into its own control. See chi_atomic_size_stress.
    _checkers = (self.tb_env.rni_sva, self.tb_env.snf_sva)
    atomic_size_stress.arm(_checkers)
    beat_size = clog2(self.chi_cfg.data_bytes)   # 4 -> one 16-byte beat

    initial_value = ATOMIC_ADDR_C
    store_operand = 0x10
    load_operand = 0x03
    swap_operand = 0x4455
    compare_operand = swap_operand
    compare_swap_value = 0x99AA
    expected_after_store = initial_value + store_operand
    expected_after_load = expected_after_store + load_operand

    # -- AtomicStore0 (ADD) ---------------------------------------------------
    resp = await self._atomic(AtomicOp.STORE_0, beat_size, [store_operand])
    assert len(resp) == 1
    req_item = await self.tb_env.rni_req_fifo.get()
    dat0 = await self.tb_env.rni_dat_fifo.get()
    await self.tb_env.rni_rsp_fifo.get()
    assert int(req_item.opcode) == int(ReqOpcode.ATOMIC_STORE_0)
    assert int(dat0.role) == int(Role.RNI) and len(dat0.data) == 1
    assert int(dat0.data[0]) == store_operand
    assert int(resp[0].rsp_opcode) == int(RspOpcode.COMP_DBID_RESP)

    # -- AtomicLoad0 (ADD, returns pre-op) ------------------------------------
    resp = await self._atomic(AtomicOp.LOAD_0, beat_size, [load_operand])
    assert len(resp) == 1
    req_item = await self.tb_env.rni_req_fifo.get()
    rsp_item = await self.tb_env.rni_rsp_fifo.get()
    dats = [await self.tb_env.rni_dat_fifo.get() for _ in range(2)]
    assert int(req_item.opcode) == int(ReqOpcode.ATOMIC_LOAD_0)
    assert int(rsp_item.rsp_opcode) in (int(RspOpcode.DBID_RESP), int(RspOpcode.DBID_RESP_ORD))
    assert int(dats[0].role) == int(Role.RNI) and int(dats[0].data[0]) == load_operand
    assert int(dats[1].role) == int(Role.SNF) and int(dats[1].data[0]) == expected_after_store
    assert int(resp[0].dat_opcode) == int(DatOpcode.COMP_DATA)
    assert len(resp[0].data) == 1 and int(resp[0].data[0]) == expected_after_store

    # -- AtomicSwap -----------------------------------------------------------
    resp = await self._atomic(AtomicOp.SWAP, beat_size, [swap_operand])
    assert len(resp) == 1 and int(resp[0].data[0]) == expected_after_load
    req_item = await self.tb_env.rni_req_fifo.get()
    await self.tb_env.rni_rsp_fifo.get()
    dats = [await self.tb_env.rni_dat_fifo.get() for _ in range(2)]
    assert int(req_item.opcode) == int(ReqOpcode.ATOMIC_SWAP)
    assert int(dats[0].role) == int(Role.RNI) and int(dats[0].data[0]) == swap_operand
    assert int(dats[1].role) == int(Role.SNF) and int(dats[1].data[0]) == expected_after_load

    # -- AtomicCompare (combined compare+swap Size) ---------------------------
    resp = await self._atomic(AtomicOp.COMPARE, beat_size + 1,
                              [compare_operand, compare_swap_value])
    assert len(resp) == 1 and int(resp[0].data[0]) == swap_operand
    req_item = await self.tb_env.rni_req_fifo.get()
    await self.tb_env.rni_rsp_fifo.get()
    dats = [await self.tb_env.rni_dat_fifo.get() for _ in range(2)]
    assert int(req_item.opcode) == int(ReqOpcode.ATOMIC_COMPARE)
    assert int(dats[0].role) == int(Role.RNI) and len(dats[0].data) == 2
    assert int(dats[0].data[0]) == compare_operand
    assert int(dats[0].data[1]) == compare_swap_value
    assert int(dats[1].role) == int(Role.SNF) and int(dats[1].data[0]) == swap_operand

    # -- Final readback confirms the compare committed the swap value ---------
    rd = self.rni0_rd_seq
    rd.reset()
    rd.set_requests(1)
    rd.set_initial_addr(ATOMIC_ADDR_C)
    rd.set_size(beat_size)
    rd.set_allow_retry(0)
    rd.set_get_response(True)
    rd.set_verbose(False)
    await rd.start(self.v_sqr.rni_sequencer)
    read_responses = rd.get_responses()
    assert len(read_responses) == 1 and len(read_responses[0].data) == 1
    assert int(read_responses[0].data[0]) == compare_swap_value

    self.logger.info("Test (tc_chi_d_atomic) PASS")
    atomic_size_stress.assert_reported(_checkers, "the atomic operands above")
    self.drop_objection()
