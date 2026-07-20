// ===========================================================================
// vip_chi_coh_make_unique_dct_base_test
//
// DCT variant of vip_chi_coh_make_unique_base_test (findings.txt F2). Identical
// scenario -- two Shared holders, RN-F1 MakeUnique (no-data Unique-Dirty grant
// with a materialized all-zero image), then RN-F0 reads the line back -- but with
// hnf_enable_snoop_fwd = 1 so the read-after-MakeUnique is served by direct cache
// transfer: the home originates a forwarding snoop to RN-F1, RN-F1 forwards its
// materialized zero image via SnpRespDataFwded, and the home relays it to RN-F0.
//
// The base test proved the NON-DCT snoop path forwards the zero image; this guards
// the SnpRespDataFwded (DCT) leg for a MakeUnique-owned line -- the path that had
// the original hang / stale-data risk (vip_chi_driver_hnf.sv DCT origination). The
// inherited assertions re-run unchanged: RN-F0 must read the defined all-zero image
// (not stale home memory, and no DCT wedge), with a single owner throughout.
//
// Used by:
//   tc_chi_coh_d_make_unique_dct    (CHI-D)
//   tc_chi_coh_e_make_unique_dct  (wide CHI-E)
// ===========================================================================
class vip_chi_coh_make_unique_dct_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends vip_chi_coh_make_unique_base_test #(CFG_P, TYPES_T);

  `uvm_component_param_utils(vip_chi_coh_make_unique_dct_base_test #(CFG_P, TYPES_T))

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // Enable DCT origination on the home; the inherited run_phase then drives the
  // read-after-MakeUnique through the SnpRespDataFwded forward path.
  protected virtual function void configure_agent_cfgs();
    super.hnf_cfg.hnf_enable_snoop_fwd = 1'b1;
  endfunction
endclass
