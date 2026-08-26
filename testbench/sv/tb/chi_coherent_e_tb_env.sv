// ===========================================================================
// chi_coherent_e_tb_env
//
// The coherent topology with the Issue-E-exact agents at both ends of the RN-F
// <-> HN-F link. Same components, same connections, same checkers: the only
// difference is which driver classes the two agents build.
//
// It exists because the E-only REQ fields have to be driven AND read, and those
// are two different classes. 13.10.8 builds PGroupID out of
// {GroupIDExt[2:0], LPID[4:0]}, so a requester that never drives GroupIDExt and
// a home that never reads it agree perfectly on group zero -- with every check
// passing, because nothing on the link ever carried a different answer to
// disagree with. Swapping one end alone would only move the zero.
//
// A separate class rather than a branch inside chi_coherent_tb_env, and that is
// a language constraint rather than a preference. The E drivers name REQ flit
// members the CHI-D flit does not have, and a member reference to a missing
// field fails at ELABORATION -- so a `if (CFG_P.ISSUE_P == ...)` inside the base
// env would still name the CHI-D specialization and still fail, however
// unreachable the branch is at runtime. The class boundary is what keeps that
// specialization from being named at all.
//
// A coherent test opts in by overriding create_tb_env. The other CHI-E coherent
// tests are right to stay on the base env: GroupIDExt is zero on a request that
// has no group and zero is a legal TagOp, so the base agents put legal CHI-E
// traffic on the wire. It is a persistent CMO that turns that zero from a value
// into an absence.
//
// Used by:
//   chi_coh_combined_write_cmo_base_test
// ===========================================================================
class chi_coherent_e_tb_env #(
  vip_chi_cfg_t CFG_P   = CHI_E_WIDE_CFG_C,
  type          TYPES_P = chi_e_wide_types_t
  ) extends chi_coherent_tb_env #(CFG_P, TYPES_P);

  `uvm_component_param_utils(chi_coherent_e_tb_env #(CFG_P, TYPES_P))

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // The requesting end: vip_chi_agent_e builds vip_chi_driver_rnf_e, which puts
  // GroupIDExt and the DAT tagging fields on the wire.
  // ---------------------------------------------------------------------------
  protected virtual function vip_chi_agent #(CFG_P, TYPES_P, VIP_CHI_ROLE_RNF_E) create_rnf_agent(
    input string name
  );
    return vip_chi_agent_e #(CFG_P, TYPES_P, VIP_CHI_ROLE_RNF_E)::type_id::create(name, this);
  endfunction

  // ---------------------------------------------------------------------------
  // The completing end: vip_chi_hnf_agent_e builds vip_chi_driver_hnf_e, which
  // reads GroupIDExt back off the request that asked for the persistent CMO.
  // ---------------------------------------------------------------------------
  protected virtual function vip_chi_hnf_agent #(CFG_P, TYPES_P, HNF_N_RNF_PORTS_C, HNF_N_SN_PORTS_C) create_hnf_agent(
    input string name
  );
    return vip_chi_hnf_agent_e #(CFG_P, TYPES_P, HNF_N_RNF_PORTS_C, HNF_N_SN_PORTS_C)::type_id::create(name, this);
  endfunction
endclass
