################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM analog of the SV `uvm_analysis_imp_decl(_suffix)` macro.
#
# A uvm_analysis_export whose write() forwards to a bound callback, so a single
# component (perf counters, scoreboard) can subscribe to several monitor analysis
# streams and route each to its own handler -- exactly the pattern pyUVM's
# uvm_subscriber uses internally for its lone analysis_export, generalized to N.
#
################################################################################

from __future__ import annotations

from pyuvm import uvm_analysis_export


class vip_chi_analysis_imp(uvm_analysis_export):

  def __init__(self, name, parent, write_fn):
    super().__init__(name, parent)
    self._write_fn = write_fn

  def write(self, item):
    self._write_fn(item)
