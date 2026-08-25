################################################################################
# pyUVM/cocotb port of tc/tc_chi_coh_e_comp_resp_negctl.sv.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from chi_coh_comp_resp_negctl_base_test import chi_coh_comp_resp_negctl_base_test


class tc_chi_coh_e_comp_resp_negctl(chi_coh_comp_resp_negctl_base_test):
  # E Table 4-7 lists Comp_UD_PD, so the encoding rule must stay silent here and
  # the injected flit is judged only by the request-correlated rule.
  EXPECT_SVA_REPORT_C = False
