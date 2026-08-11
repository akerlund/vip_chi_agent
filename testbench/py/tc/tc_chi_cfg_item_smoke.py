################################################################################
# pyUVM/cocotb port of tc/tc_chi_cfg_item_smoke.sv.
#
# Object-level smoke for VipChiCfgItem: the constructed defaults, and reset()
# restoring every knob EXCEPT direction, which the owning concrete sequence pins
# and reset() must preserve. No link topology is built.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from pyuvm import uvm_test

from vip_chi_types_pkg import Dir, DataType
from vip_chi_cfg_item import VipChiCfgItem


class tc_chi_cfg_item_smoke(uvm_test):

  async def run_phase(self):
    self.raise_objection()

    cfg_item = VipChiCfgItem("cfg_item")

    assert cfg_item.direction == Dir.READ, "default direction mismatch"
    assert cfg_item.data_type == DataType.RANDOM, "default data_type mismatch"
    assert cfg_item.min_size == 0, "default min_size mismatch"
    assert cfg_item.max_size == 6, "default max_size mismatch"
    assert cfg_item.enforce_addr_alignment is True, \
      "default enforce_addr_alignment mismatch"
    assert cfg_item.get_response is False, "default get_response mismatch"
    assert cfg_item.atomic_strict_size is False, \
      "default atomic_strict_size mismatch"

    cfg_item.direction = Dir.WRITE
    cfg_item.data_type = DataType.COUNTER
    cfg_item.min_size = 2
    cfg_item.max_size = 4
    cfg_item.enforce_addr_alignment = False
    cfg_item.atomic_strict_size = True
    cfg_item.get_response = True
    cfg_item.reset()

    # Direction is pinned by the concrete sequence, so reset() keeps it.
    assert cfg_item.direction == Dir.WRITE, \
      "reset() did not preserve direction"
    assert cfg_item.data_type == DataType.RANDOM, \
      "reset() did not restore data_type"
    assert cfg_item.min_size == 0, "reset() did not restore min_size"
    assert cfg_item.max_size == 6, "reset() did not restore max_size"
    assert cfg_item.enforce_addr_alignment is True, \
      "reset() did not restore enforce_addr_alignment"
    assert cfg_item.get_response is False, \
      "reset() did not restore get_response"
    assert cfg_item.atomic_strict_size is False, \
      "reset() did not restore atomic_strict_size"

    self.logger.info("Test (tc_chi_cfg_item_smoke) PASS")
    self.drop_objection()
