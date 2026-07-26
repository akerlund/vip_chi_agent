// ===========================================================================
// chi_coherent_e_base_test
//
// Wide-CHI-E specialization of the parameterized chi_coherent_base_test:
// the same two-RN-F -> one-HN-F coherent topology at CHI_E_WIDE_CFG_C /
// chi_e_wide_types_t. Base class for the CHI-E-only coherent scenarios that
// have no CHI-D twin (tc_chi_coh_e_make_read_unique, tc_chi_coh_e_cmo_negctl);
// D/E paired scenarios instead derive vip_chi_<scenario>_base_test classes from the
// parameterized base.
//
// Used by:
//   tc_chi_coh_e_cmo_negctl
//   tc_chi_coh_e_make_read_unique
// ===========================================================================
class chi_coherent_e_base_test extends chi_coherent_base_test #(CHI_E_WIDE_CFG_C, chi_e_wide_types_t);

  `uvm_component_utils(chi_coherent_e_base_test)

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction
endclass
