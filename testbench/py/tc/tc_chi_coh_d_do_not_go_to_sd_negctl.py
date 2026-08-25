################################################################################
# pyUVM/cocotb port of tc/tc_chi_coh_d_do_not_go_to_sd_negctl.sv.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from chi_coh_do_not_go_to_sd_negctl_base_test import (
  chi_coh_do_not_go_to_sd_negctl_base_test)


class tc_chi_coh_d_do_not_go_to_sd_negctl(chi_coh_do_not_go_to_sd_negctl_base_test):

  # D 12.9.32 lets DoNotGoToSD take any value, so the home leaves it clear and
  # SD is a conformant answer on this cut: the rule must stay SILENT. See the
  # base test for why both answers are asserted.
  EXPECT_REPORT_C = False
