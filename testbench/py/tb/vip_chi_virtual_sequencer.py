################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of tb/vip_chi_virtual_sequencer.sv -- holds the per-agent sequencer
# handles the tests start their sequences on.
#
################################################################################

from __future__ import annotations

from pyuvm import uvm_sequencer


class vip_chi_virtual_sequencer(uvm_sequencer):

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.rni_sequencer = None
    self.snf_sequencer = None
    # HN-I proxy topology (Wave 6): two RN-facing requester sequencers and two
    # SN-facing responder sequencers.
    self.hrni0_sequencer = None
    self.hrni1_sequencer = None
    self.hsnf0_sequencer = None
    self.hsnf1_sequencer = None
