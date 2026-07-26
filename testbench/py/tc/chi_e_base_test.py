################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of tc/chi_e_base_test.sv (CHI-E integrated pair). Reuses the
# issue-agnostic chi_base_test scaffolding (the ChiCfg is taken from the
# ChiBus, which is CHI-E here) and exposes the rni_wr_seq / rni_rd_seq handles
# the CHI-E tests drive.
#
################################################################################

from __future__ import annotations

from chi_base_test import chi_base_test


class chi_e_base_test(chi_base_test):

  def build_phase(self):
    super().build_phase()
    self.rni_wr_seq = self.rni0_wr_seq
    self.rni_rd_seq = self.rni0_rd_seq
