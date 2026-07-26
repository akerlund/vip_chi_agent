################################################################################
# pyUVM/cocotb port of tc/tc_chi_d_atomic_predict.sv.
#
# Each variant first seeds its target with a known full-beat WRITE (so the pre-op
# value is a real committed value, not an SN-F-synthesized pattern), then issues
# the atomic, then reads the granule back. Covers AtomicStore0(ADD, non-returning)
# and the returning AtomicSwap / AtomicCompare(match): the returning ops return
# the pre-op seed, and the read-back confirms the committed post-op value.
# Runs under: testbench/py/tb/vip_chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import AtomicOp, clog2, mask
from vip_chi_base_test import vip_chi_base_test
from vip_chi_atomic_seq import vip_chi_atomic_seq

STORE_ADDR_C = 0x3A00_0000
SWAP_ADDR_C = 0x3A00_0100
COMPARE_ADDR_C = 0x3A00_0200
SETTLE_C = 8


class tc_chi_d_atomic_predict(vip_chi_base_test):

  async def _seed_write(self, addr, value, beat_size):
    wr = self.rni0_wr_seq
    wr.reset()
    wr.set_requests(1)
    wr.set_initial_addr(addr)
    wr.set_size(beat_size)
    wr.set_allow_retry(0)
    wr.set_data([value])
    wr.set_get_response(True)
    wr.set_verbose(False)
    await wr.start(self.v_sqr.rni_sequencer)
    assert len(wr.get_responses()) == 1, \
      f"seed write to 0x{addr:x} expected 1 response"
    await self.wait_clocks(SETTLE_C)

  async def _read_check(self, addr, expected, beat_size, label):
    rd = self.rni0_rd_seq
    rd.reset()
    rd.set_requests(1)
    rd.set_initial_addr(addr)
    rd.set_size(beat_size)
    rd.set_allow_retry(0)
    rd.set_get_response(True)
    rd.set_verbose(False)
    await rd.start(self.v_sqr.rni_sequencer)
    rsp = rd.get_responses()
    got = int(rsp[0].data[0]) if rsp and len(rsp[0].data) else None
    assert len(rsp) == 1 and len(rsp[0].data) == 1 and got == (expected & mask(self.chi_cfg.data_bytes * 8)), \
      f"{label} read-back {got if got is None else hex(got)} != expected 0x{expected:x}"

  async def run_phase(self):
    self.raise_objection()

    beat_size = clog2(self.chi_cfg.data_bytes)
    dw_mask = mask(self.chi_cfg.data_bytes * 8)
    store_seed, store_op = 0x0000_1000, 0x0000_0025
    swap_seed, swap_op = 0xCAFE_0001, 0x0BAD_F00D
    cmp_seed, cmp_swap = 0x1234_5678, 0x9999_AAAA

    # -- AtomicStore0 (ADD), non-returning: commit resolves on the Comp. --------
    await self._seed_write(STORE_ADDR_C, store_seed, beat_size)
    seq = vip_chi_atomic_seq("atomic_seq", cfg=self.chi_cfg)
    seq.reset()
    seq.set_atomic_op(AtomicOp.STORE_0)
    seq.set_requests(1)
    seq.set_initial_addr(STORE_ADDR_C)
    seq.set_size(beat_size)
    seq.set_allow_retry(0)
    seq.set_get_response(True)
    seq.set_verbose(False)
    seq.set_data([store_op])
    await seq.start(self.v_sqr.rni_sequencer)
    assert len(seq.get_responses()) == 1, "AtomicStore0 expected 1 response"
    await self.wait_clocks(SETTLE_C)
    await self._read_check(STORE_ADDR_C, (store_seed + store_op) & dw_mask,
                           beat_size, "AtomicStore0(ADD)")

    # -- AtomicSwap, returning: return == pre-op seed, store == operand. --------
    await self._seed_write(SWAP_ADDR_C, swap_seed, beat_size)
    seq = vip_chi_atomic_seq("atomic_seq", cfg=self.chi_cfg)
    seq.reset()
    seq.set_atomic_op(AtomicOp.SWAP)
    seq.set_requests(1)
    seq.set_initial_addr(SWAP_ADDR_C)
    seq.set_size(beat_size)
    seq.set_allow_retry(0)
    seq.set_get_response(True)
    seq.set_verbose(False)
    seq.set_data([swap_op])
    await seq.start(self.v_sqr.rni_sequencer)
    rsp = seq.get_responses()
    assert len(rsp) == 1 and len(rsp[0].data) == 1 and int(rsp[0].data[0]) == swap_seed, \
      "AtomicSwap did not return the pre-op seed"
    await self.wait_clocks(SETTLE_C)
    await self._read_check(SWAP_ADDR_C, swap_op, beat_size, "AtomicSwap")

    # -- AtomicCompare (match): return == pre-op seed, store == swap value. -----
    await self._seed_write(COMPARE_ADDR_C, cmp_seed, beat_size)
    seq = vip_chi_atomic_seq("atomic_seq", cfg=self.chi_cfg)
    seq.reset()
    seq.set_atomic_op(AtomicOp.COMPARE)
    seq.set_requests(1)
    seq.set_initial_addr(COMPARE_ADDR_C)
    seq.set_size(beat_size + 1)
    seq.set_allow_retry(0)
    seq.set_get_response(True)
    seq.set_verbose(False)
    seq.set_data([cmp_seed, cmp_swap])  # compare == seed => match, swap stored
    await seq.start(self.v_sqr.rni_sequencer)
    rsp = seq.get_responses()
    assert len(rsp) == 1 and len(rsp[0].data) == 1 and int(rsp[0].data[0]) == cmp_seed, \
      "AtomicCompare did not return the pre-op seed"
    await self.wait_clocks(SETTLE_C)
    await self._read_check(COMPARE_ADDR_C, cmp_swap, beat_size, "AtomicCompare(match)")

    self.logger.info(
      "Test (tc_chi_d_atomic_predict) PASS: atomic RMW prediction exercised "
      "(Store0 ADD, Swap, Compare match) seeded, applied, read back")
    self.drop_objection()
