################################################################################
# pyUVM/cocotb port of tc/tc_chi_coh_e_snp_field_negctl.sv.
#
# Wide CHI-E runnable specialization of chi_coh_snp_field_negctl_base_test; the
# scenario body and its documentation live in that file. There is no CHI-D twin
# on purpose: Issue D has no DoNotGoToSD must-be-one list, so one of the three
# rules has nothing to provoke there.
#
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from chi_coh_snp_field_negctl_base_test import chi_coh_snp_field_negctl_base_test


class tc_chi_coh_e_snp_field_negctl(chi_coh_snp_field_negctl_base_test):
  pass
