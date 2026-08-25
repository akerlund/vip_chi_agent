// ===========================================================================
// CHI-D runnable specialization of chi_coh_do_not_go_to_sd_negctl_base_test;
// the scenario body and its documentation live in that file.
//
// D 12.9.32 lets DoNotGoToSD take any value, so the home leaves it clear and SD
// is a conformant answer on this cut: the rule must stay SILENT. See the base
// test for why both answers are asserted.
// ===========================================================================
class tc_chi_coh_d_do_not_go_to_sd_negctl extends
  chi_coh_do_not_go_to_sd_negctl_base_test #(CHI_D_CFG_C, chi_d_types_t);
  `uvm_component_utils(tc_chi_coh_d_do_not_go_to_sd_negctl)
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
    this.expect_report = 1'b0;
  endfunction
endclass
