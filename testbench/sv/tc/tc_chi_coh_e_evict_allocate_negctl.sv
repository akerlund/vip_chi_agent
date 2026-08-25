// ===========================================================================
// tc_chi_coh_e_evict_allocate_negctl
//
// CHI-E (wide) (CHI_E_WIDE_CFG_C / chi_e_wide_types_t) runnable specialization of
// chi_coh_evict_allocate_negctl_base_test; the scenario body and its
// documentation live in that file.
// ===========================================================================
class tc_chi_coh_e_evict_allocate_negctl extends
  chi_coh_evict_allocate_negctl_base_test #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t);
  `uvm_component_utils(tc_chi_coh_e_evict_allocate_negctl)
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction
endclass
