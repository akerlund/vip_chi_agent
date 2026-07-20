// ===========================================================================
// tc_chi_coh_e_write_unique_ptl
//
// Wide CHI-E runnable specialization of vip_chi_coh_write_unique_ptl_base_test.
// ===========================================================================
class tc_chi_coh_e_write_unique_ptl extends
  vip_chi_coh_write_unique_ptl_base_test #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t);
  `uvm_component_utils(tc_chi_coh_e_write_unique_ptl)
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction
endclass

