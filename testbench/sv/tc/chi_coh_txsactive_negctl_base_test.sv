// ===========================================================================
// chi_coh_txsactive_negctl_base_test
//
// Negative control for CHI_TXSACTIVE_COVERS_OUTSTANDING at the HOME.
//
// chi_coh_txsactive_window_base_test proves the home holds its RN-facing
// sideband across the whole outstanding window. This proves the rule that
// watches it would SAY SO if it did not: cfg.hnf_txsactive_early_drop_negctl
// makes the home retire the window the moment it starts serving a read rather
// than when the transaction completes, and the rule must report the cycles the
// sideband spends low with a transaction still in flight.
//
// IHI 0050 E section 14.7.2 / D section 13.7.2: the home must keep TXSACTIVE
// asserted until after the final completing flit is sent or received. Under-
// assertion is the failure that matters, because a receiver reads the sideband
// to decide when it can stop watching for snoop traffic.
//
// The read is aimed at a line the OTHER requester owns, so the home must snoop
// before it can answer: the violation window is then tens of cycles wide rather
// than the one or two a directory hit would give, and the count the test asserts
// on cannot be an artefact of a single edge.
//
// What the control must NOT do is trip its neighbour.
// CHI_TXSACTIVE_DEASSERT_BOUNDED bounds how long the sideband may stay UP once
// the link is quiet, so a sideband dropped too early cannot fire it, and this
// test asserts that silence: it is what separates "the window was too narrow"
// from "the sideband is broken in both directions".
//
// Used by:
//   tc_chi_coh_e_txsactive_negctl  (wide CHI-E)
//   tc_chi_coh_d_txsactive_negctl  (CHI-D)
// ===========================================================================
class chi_coh_txsactive_negctl_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(chi_coh_txsactive_negctl_base_test #(CFG_P, TYPES_T))

  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();
    super.hnf_cfg.hnf_txsactive_early_drop_negctl = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t   setup_rsp[$];
    item_t   read_rsp[$];
    longint  fails;
    longint  neighbour;

    phase.raise_objection(this);

    // Suppress the report, keep the count. The violation is judged where the
    // sideband is driven, which is the home's own bind; the RN-F binds see the
    // same wire from the other side and have their own window, so they are
    // asserted to stay quiet below rather than stood down here.
    foreach (super.tb_env.hnf_agent.rn_vif[i]) begin
      super.tb_env.hnf_agent.rn_vif[i].check_severity[VIP_CHI_CHK_TXSACTIVE_COVERS_OUTSTANDING_E] =
        VIP_CHI_CHK_SEV_OFF_E;
    end

    super.wait_reset_settle();

    // RN-F0 takes the line Unique so the home cannot answer RN-F1 without
    // snooping, which is what makes the violation window wide. That direction
    // rather than the other because port 0 is the one with a snoop observation
    // fifo, and the snoop has to be OBSERVED for the width to be evidence.
    this.cfg_read_seq(super.hrnf0_rdunique_seq);
    super.hrnf0_rdunique_seq.start(super.tb_env.hrnf0_agent.sequencer);
    setup_rsp = super.hrnf0_rdunique_seq.get_responses();
    if (setup_rsp.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 did not acquire the line (got %0d response(s))",
        super.tc_name, setup_rsp.size()))
    end

    this.cfg_read_seq(super.hrnf1_rdshared_seq);
    super.hrnf1_rdshared_seq.start(super.tb_env.hrnf1_agent.sequencer);
    read_rsp = super.hrnf1_rdshared_seq.get_responses();
    if (read_rsp.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F1's read never completed (got %0d response(s))",
        super.tc_name, read_rsp.size()))
    end

    super.wait_clocks(40);

    if (super.tb_env.hrnf0_snp_fifo.used() == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 was never snooped, so the home answered from its directory and the violation window was never opened wide",
        super.tc_name))
    end

    fails     = 0;
    neighbour = 0;
    foreach (super.tb_env.hnf_agent.rn_vif[i]) begin
      fails += super.tb_env.hnf_agent.rn_vif[i].check_fail_count[VIP_CHI_CHK_TXSACTIVE_COVERS_OUTSTANDING_E];
      neighbour += super.tb_env.hnf_agent.rn_vif[i].check_fail_count[VIP_CHI_CHK_TXSACTIVE_DEASSERT_BOUNDED_E];
    end

    if (fails == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] CHI_TXSACTIVE_COVERS_OUTSTANDING did not report a home that dropped TXSACTIVE while a transaction it had captured was still in flight -- the rule may be vacuous at the completer vantage",
        super.tc_name))
    end

    // The neighbour rule bounds the sideband staying UP. A window dropped too
    // early cannot trip it, and if it did the control would be exercising two
    // rules at once.
    if (neighbour != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] CHI_TXSACTIVE_DEASSERT_BOUNDED also reported %0d time(s): this control is meant to narrow the window, not to strand the sideband high",
        super.tc_name, neighbour))
    end

    `uvm_info(get_name(), $sformatf(
      "Test (%s) PASS: CHI_TXSACTIVE_COVERS_OUTSTANDING reported %0d cycle(s) of a home sideband dropped under an in-flight transaction, and the bounding rule stayed silent",
      super.tc_name, fails), UVM_LOW)

    phase.drop_objection(this);

  endtask
endclass
