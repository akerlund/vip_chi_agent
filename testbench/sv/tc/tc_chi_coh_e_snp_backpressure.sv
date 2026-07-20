// ===========================================================================
// tc_chi_coh_e_snp_backpressure
//
// Wide CHI-E (CHI_E_WIDE_CFG_C / chi_e_wide_types_t) runnable
// specialization of vip_chi_coh_snp_backpressure_base_test; the scenario body and its
// documentation live in that file.
// ===========================================================================
class tc_chi_coh_e_snp_backpressure extends
  vip_chi_coh_snp_backpressure_base_test #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t);
  `uvm_component_utils(tc_chi_coh_e_snp_backpressure)
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction
endclass
