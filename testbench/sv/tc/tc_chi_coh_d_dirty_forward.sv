// ===========================================================================
// tc_chi_coh_d_dirty_forward
//
// CHI-D (CHI_D_CFG_C / chi_d_types_t) runnable
// specialization of vip_chi_coh_dirty_forward_base_test; the scenario body and its
// documentation live in that file.
// ===========================================================================
class tc_chi_coh_d_dirty_forward extends
  vip_chi_coh_dirty_forward_base_test #(CHI_D_CFG_C, chi_d_types_t);
  `uvm_component_utils(tc_chi_coh_d_dirty_forward)
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction
endclass


