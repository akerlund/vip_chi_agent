// ===========================================================================
// tc_chi_coh_d_write_unique_ptl
//
// CHI-D runnable specialization of vip_chi_coh_write_unique_ptl_base_test.
// ===========================================================================
class tc_chi_coh_d_write_unique_ptl extends
  vip_chi_coh_write_unique_ptl_base_test #(CHI_D_CFG_C, chi_d_types_t);
  `uvm_component_utils(tc_chi_coh_d_write_unique_ptl)
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction
endclass

