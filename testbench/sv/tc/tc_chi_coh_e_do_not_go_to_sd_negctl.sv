// ===========================================================================
// CHI-E runnable specialization of chi_coh_do_not_go_to_sd_negctl_base_test;
// the scenario body and its documentation live in that file.
//
// E 13.10.35 makes DoNotGoToSD must-be-one on the invalidating snoops, so the
// bit IS set here and a snoopee reporting SD violates it: the rule must report.
// ===========================================================================
class tc_chi_coh_e_do_not_go_to_sd_negctl extends
  chi_coh_do_not_go_to_sd_negctl_base_test #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t);
  `uvm_component_utils(tc_chi_coh_e_do_not_go_to_sd_negctl)
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction
endclass
