// ===========================================================================
// tc_chi_coh_e_comp_ack_read
//
// Wide CHI-E (CHI_E_WIDE_CFG_C / chi_e_wide_types_t) runnable
// specialization of chi_coh_comp_ack_read_base_test; the scenario body and its
// documentation live in that file.
// ===========================================================================
class tc_chi_coh_e_comp_ack_read extends
  chi_coh_comp_ack_read_base_test #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t);
  `uvm_component_utils(tc_chi_coh_e_comp_ack_read)
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction
endclass
