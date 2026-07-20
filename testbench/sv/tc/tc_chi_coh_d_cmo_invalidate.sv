// ===========================================================================
// tc_chi_coh_d_cmo_invalidate
//
// CHI-D (CHI_D_CFG_C / chi_d_types_t) runnable
// specialization of vip_chi_coh_cmo_invalidate_base_test; the scenario body and its
// documentation live in that file.
// ===========================================================================
class tc_chi_coh_d_cmo_invalidate extends
  vip_chi_coh_cmo_invalidate_base_test #(CHI_D_CFG_C, chi_d_types_t);
  `uvm_component_utils(tc_chi_coh_d_cmo_invalidate)
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction
endclass


