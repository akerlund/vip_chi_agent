// ===========================================================================
// tc_chi_coh_d_read_no_snoop
//
// CHI-D (CHI_D_CFG_C / chi_d_types_t) runnable
// specialization of chi_coh_read_no_snoop_base_test; the scenario body and its
// documentation live in that file.
// ===========================================================================
class tc_chi_coh_d_read_no_snoop extends
  chi_coh_read_no_snoop_base_test #(CHI_D_CFG_C, chi_d_types_t);
  `uvm_component_utils(tc_chi_coh_d_read_no_snoop)
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction
endclass


