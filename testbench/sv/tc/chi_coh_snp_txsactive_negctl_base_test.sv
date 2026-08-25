// ===========================================================================
// chi_coh_snp_txsactive_negctl_base_test
//
// Negative control for the RECEIVING limb of CHI_TXSACTIVE_COVERS_OUTSTANDING,
// at the SNOOPEE.
//
// IHI 0050 E section 14.7.2 / D section 13.7.2 states the snoopee's obligation
// in a sentence of its own: "An RN-F or RN-D component must also assert
// TXSACTIVE while a Snoop transaction is in progress". The two limbs already
// controlled elsewhere are both the ICN's -- its requests and the snoops it
// sends. This is the other end of the same wire pair, and until this control
// existed nothing had shown the rule could report it.
//
// cfg.rnf_txsactive_snoop_drop_negctl makes RN-F0 answer a snoop without
// opening a TXSACTIVE window at all, so the sideband stays low for the whole
// look-up and response. The rule must report those cycles.
//
// The scenario has to leave the snoopee IDLE, which is what separates this from
// the home-side control. RN-F0 takes the line Unique and its own read is allowed
// to retire before RN-F1 reads; the snoop then arrives at a node with nothing
// outstanding of its own, so the request limb cannot hold the sideband up and
// the only thing that could is the limb this control removes.
//
// The rule is judged at the snoopee's own bind, because that is where the
// sideband being tested is driven. The home's binds see the same obligation from
// the other side, on their own wires, and are asserted to stay quiet.
//
// What the control must NOT do is trip its neighbour.
// CHI_TXSACTIVE_DEASSERT_BOUNDED bounds how long the sideband may stay UP once
// the link is quiet, so a window that is never opened cannot fire it. Asserting
// that silence is what separates "the window was missing" from "the sideband is
// broken in both directions".
//
// Used by:
//   tc_chi_coh_e_snp_txsactive_negctl  (wide CHI-E)
//   tc_chi_coh_d_snp_txsactive_negctl  (CHI-D)
// ===========================================================================
class chi_coh_snp_txsactive_negctl_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(chi_coh_snp_txsactive_negctl_base_test #(CFG_P, TYPES_T))

  localparam int SETTLE_C = 40;

  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();
    super.hrnf0_cfg.rnf_txsactive_snoop_drop_negctl = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t       setup_rsp[$];
    item_t       read_rsp[$];
    int unsigned fails;
    int unsigned neighbour;
    int unsigned home_fails;

    phase.raise_objection(this);

    // Suppress the report, keep the count.
    super.tb_env.hrnf0_agent.vif.check_severity[VIP_CHI_CHK_TXSACTIVE_COVERS_OUTSTANDING_E] =
      VIP_CHI_CHK_SEV_OFF_E;

    super.wait_reset_settle();

    // RN-F0 takes the line Unique so the home cannot answer RN-F1 without
    // snooping it. Port 0 rather than port 1 because it is the port with a snoop
    // observation fifo, and the snoop has to be OBSERVED for the count to be
    // evidence of anything.
    this.cfg_read_seq(super.hrnf0_rdunique_seq);
    super.hrnf0_rdunique_seq.start(super.tb_env.hrnf0_agent.sequencer);
    setup_rsp = super.hrnf0_rdunique_seq.get_responses();
    if (setup_rsp.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 did not acquire the line (got %0d response(s))",
        super.tc_name, setup_rsp.size()))
    end

    // The gap is the point of the scenario, not padding: it lets RN-F0's own
    // read retire so the snoop lands on an idle node.
    super.wait_clocks(SETTLE_C);

    this.cfg_read_seq(super.hrnf1_rdshared_seq);
    super.hrnf1_rdshared_seq.start(super.tb_env.hrnf1_agent.sequencer);
    read_rsp = super.hrnf1_rdshared_seq.get_responses();
    if (read_rsp.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F1's read never completed (got %0d response(s))",
        super.tc_name, read_rsp.size()))
    end

    super.wait_clocks(SETTLE_C);

    if (super.tb_env.hrnf0_snp_fifo.used() == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 was never snooped, so the home answered from its directory and the window this control removes was never needed",
        super.tc_name))
    end

    fails     = super.tb_env.hrnf0_agent.vif.check_fail_count[VIP_CHI_CHK_TXSACTIVE_COVERS_OUTSTANDING_E];
    neighbour = super.tb_env.hrnf0_agent.vif.check_fail_count[VIP_CHI_CHK_TXSACTIVE_DEASSERT_BOUNDED_E];

    if (fails == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] CHI_TXSACTIVE_COVERS_OUTSTANDING did not report a snoopee that answered a snoop with its sideband low -- the receiving limb is vacuous",
        super.tc_name))
    end

    if (neighbour != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] CHI_TXSACTIVE_DEASSERT_BOUNDED also reported %0d time(s): this control removes a window, it does not strand the sideband high",
        super.tc_name, neighbour))
    end

    // The home is unmodified here, and its own sideband is a different wire on a
    // different interface. A report there would mean this control had reached
    // further than the snoopee it was aimed at.
    home_fails = 0;
    foreach (super.tb_env.hnf_agent.rn_vif[i]) begin
      home_fails += super.tb_env.hnf_agent.rn_vif[i].check_fail_count[VIP_CHI_CHK_TXSACTIVE_COVERS_OUTSTANDING_E];
    end
    if (home_fails != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the home's own TXSACTIVE was reported %0d time(s) as well: the control is aimed at the snoopee's window and nothing else",
        super.tc_name, home_fails))
    end

    `uvm_info(get_name(), $sformatf(
      "Test (%s) PASS: CHI_TXSACTIVE_COVERS_OUTSTANDING reported %0d cycle(s) of a snoopee sideband held low across a snoop it was answering, the bounding rule stayed silent, and the home's own sideband was not touched",
      super.tc_name, fails), UVM_LOW)

    phase.drop_objection(this);

  endtask
endclass
