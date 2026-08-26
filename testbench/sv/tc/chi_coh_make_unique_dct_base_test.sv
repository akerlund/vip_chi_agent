// ===========================================================================
// chi_coh_make_unique_dct_base_test
//
// DCT variant of chi_coh_make_unique_base_test (findings.txt F2). Identical
// scenario -- two Shared holders, RN-F1 MakeUnique (no-data Unique-Dirty grant
// with a materialized all-zero image), then RN-F0 reads the line back -- but with
// hnf_enable_snoop_fwd = 1 so the read-after-MakeUnique is served by direct cache
// transfer: the home originates a forwarding snoop to RN-F1, RN-F1 forwards its
// materialized zero image via SnpRespDataFwded, and the home relays it to RN-F0.
//
// The base test proved the NON-DCT snoop path forwards the zero image; this guards
// the SnpRespDataFwded (DCT) leg for a MakeUnique-owned line -- the path that had
// the original hang / stale-data risk (vip_chi_driver_hnf.sv DCT origination). The
// inherited assertions re-run unchanged: RN-F0 must read the defined all-zero image
// (not stale home memory, and no DCT wedge), with a single owner throughout.
//
// Used by:
//   tc_chi_coh_d_make_unique_dct    (CHI-D)
//   tc_chi_coh_e_make_unique_dct  (wide CHI-E)
// ===========================================================================
class chi_coh_make_unique_dct_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends chi_coh_make_unique_base_test #(CFG_P, TYPES_T);

  `uvm_component_param_utils(chi_coh_make_unique_dct_base_test #(CFG_P, TYPES_T))

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // Enable DCT origination on the home; the inherited run_phase then drives the
  // read-after-MakeUnique through the SnpRespDataFwded forward path.
  protected virtual function void configure_agent_cfgs();
    super.hnf_cfg.hnf_enable_snoop_fwd = 1'b1;
  endfunction

  // The inherited assertions do not distinguish the two paths.
  //
  // They require RN-F0 to read the defined all-zero image, and it reads that
  // image whether the home forwarded it from RN-F1 or fetched it the ordinary
  // way -- so a home whose DCT gate fell back to the normal dirty-snoop path
  // would satisfy every one of them while never originating a forwarding snoop.
  // Enabling a knob is not evidence that the knob was used.
  //
  // n_snp_fwd_judged is the evidence: the coherency checker counts a forwarding
  // snoop only where it has correlated one to its causing request and checked
  // the forwarded names against it, so a rise here says a fwd snoop went out AND
  // that its FwdNID/FwdTxnID named the requester's read. The mismatch count is
  // asserted beside it because judged-without-mismatch is the claim, not judged
  // alone.
  task run_phase(input uvm_phase phase);

    int fwd_judged_before;
    int fwd_judged_after;

    fwd_judged_before = super.tb_env.coh_checker.get_snp_fwd_judged_count();

    super.run_phase(phase);

    fwd_judged_after = super.tb_env.coh_checker.get_snp_fwd_judged_count();

    if (fwd_judged_after <= fwd_judged_before) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] no forwarding snoop was judged (%0d -> %0d) with hnf_enable_snoop_fwd set, so the read was served by the ordinary snoop path and this testcase proved only what its non-DCT parent already proves",
      super.tc_name, fwd_judged_before, fwd_judged_after))
    end
    if (super.tb_env.coh_checker.get_snp_fwd_mismatch_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] %0d forwarding snoop(s) named a requester or transaction that did not match the request they answer",
      super.tc_name, super.tb_env.coh_checker.get_snp_fwd_mismatch_count()))
    end
  endtask
endclass
