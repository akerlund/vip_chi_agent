################################################################################
# pyUVM port of tc/vip_chi_coh_make_unique_dct_base_test.sv.
#
# Same as the make_unique scenario but with DCT snoop forwarding enabled, so the
# read-after-MakeUnique is served via a forwarding snoop of RN-F1's freshly-made
# (all-zero materialized) line. Reuses the make_unique body verbatim.
################################################################################

from __future__ import annotations

from vip_chi_coh_make_unique_base_test import vip_chi_coh_make_unique_base_test


class vip_chi_coh_make_unique_dct_base_test(vip_chi_coh_make_unique_base_test):

  def configure_agent_cfgs(self):
    self.hnf_cfg.hnf_enable_snoop_fwd = True
