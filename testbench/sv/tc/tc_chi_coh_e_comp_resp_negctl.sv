// ===========================================================================
// tc_chi_coh_e_comp_resp_negctl
//
// Wide CHI-E (CHI_E_WIDE_CFG_C / chi_e_wide_types_t) runnable
// specialization of chi_coh_comp_resp_negctl_base_test; the scenario body and its
// documentation live in that file.
// ===========================================================================
class tc_chi_coh_e_comp_resp_negctl extends
  chi_coh_comp_resp_negctl_base_test #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t);
  `uvm_component_utils(tc_chi_coh_e_comp_resp_negctl)
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
    // E Table 4-7 lists Comp_UD_PD, so the encoding rule must stay silent here
    // and the injected flit is judged only by the request-correlated rule.
    super.expect_sva_report_c = 1'b0;
  endfunction
endclass
