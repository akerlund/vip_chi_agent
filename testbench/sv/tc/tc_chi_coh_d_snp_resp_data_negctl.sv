// ===========================================================================
// CHI-D runnable specialization of chi_coh_snp_resp_data_negctl_base_test; the
// scenario body and its documentation live in that file.
//
// SnpMakeInvalid's permitted response set is the same in D §4.3 as in E, so
// both cuts expect the report; the pair exists because the flit widths and the
// response path differ, not the rule.
// ===========================================================================
class tc_chi_coh_d_snp_resp_data_negctl extends
  chi_coh_snp_resp_data_negctl_base_test #(CHI_D_CFG_C, chi_d_types_t);
  `uvm_component_utils(tc_chi_coh_d_snp_resp_data_negctl)
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction
endclass
