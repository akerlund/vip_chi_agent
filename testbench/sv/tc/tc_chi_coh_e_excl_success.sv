// ===========================================================================
// tc_chi_coh_e_excl_success
//
// Wide CHI-E (CHI_E_WIDE_CFG_C / chi_e_wide_types_t) runnable
// specialization of chi_coh_excl_success_base_test; the scenario body and its
// documentation live in that file.
// ===========================================================================
class tc_chi_coh_e_excl_success extends
  chi_coh_excl_success_base_test #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t);
  `uvm_component_utils(tc_chi_coh_e_excl_success)
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction
endclass
