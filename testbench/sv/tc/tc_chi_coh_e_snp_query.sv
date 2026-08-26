// ===========================================================================
// tc_chi_coh_e_snp_query
//
// Wide CHI-E (CHI_E_WIDE_CFG_C / chi_e_wide_types_t) runnable specialization of
// chi_coh_snp_query_base_test; the scenario body and its documentation live in
// that file. There is no CHI-D twin: SnpQuery has no encoding before Issue E.
// ===========================================================================
class tc_chi_coh_e_snp_query extends
  chi_coh_snp_query_base_test #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t);
  `uvm_component_utils(tc_chi_coh_e_snp_query)
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction
endclass
