// ===========================================================================
// tc_chi_coh_e_combined_write_cmo
//
// Wide CHI-E (CHI_E_WIDE_CFG_C / chi_e_wide_types_t) runnable
// specialization of chi_coh_combined_write_cmo_base_test; the scenario body and
// its documentation live in that file.
//
// There is no CHI-D twin: every combined form sits in the Opcode[6] = 1 half of
// Table 13-14 and does not fit CHI-D's 6-bit REQ opcode field at all.
// ===========================================================================
class tc_chi_coh_e_combined_write_cmo extends
  chi_coh_combined_write_cmo_base_test #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t);
  `uvm_component_utils(tc_chi_coh_e_combined_write_cmo)
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction
endclass
