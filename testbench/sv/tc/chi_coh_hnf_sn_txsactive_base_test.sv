// ===========================================================================
// chi_coh_hnf_sn_txsactive_base_test
//
// The home's SN-facing TXSACTIVE is a WINDOW around its own downstream
// requests, not a level that follows the link.
//
// IHI 0050 E section 14.7.2: "The interconnect interface to an SN must assert
// TXSACTIVE before, or in the same cycle in which its initiating Request flit
// is sent. It must keep TXSACTIVE asserted until after the final completing
// flit is sent or received." Read with the general statement earlier in that
// section -- deassertion "implies that the component has completed all
// transactions in progress" -- this is a window opened by a request the home
// SENDS.
//
// The home used to drive it from sn_link_up, so it was high from bring-up to
// tear-down whatever it had downstream. Legal by the letter, since
// over-assertion always is, and carrying no information at all -- which is the
// state CHI_TXSACTIVE_DEASSERT_BOUNDED exists to report and could not, because
// the bind stood that rule down for exactly this drive.
//
// What is asserted, from a per-cycle trace of the home's SN-facing port taken
// after the link is already up:
//
//   * TXSACTIVE is LOW for at least one cycle BEFORE the first downstream
//     flit. This is the claim the old drive could not satisfy at all: the link
//     comes up long before the home has anything to fetch, so a sideband tied
//     to link state has no low cycle here.
//   * TXSACTIVE is HIGH on every cycle a flit moves in either direction. That
//     is the requirement itself -- the window must cover the request and
//     everything up to the final completing flit.
//   * TXSACTIVE is HIGH on at least one cycle with no flit moving, so it is a
//     held window rather than a per-flit pulse.
//   * TXSACTIVE is LOW again once the traffic has drained, so the window
//     closes and the signal still carries information.
//
// Used by:
//   tc_chi_coh_d_hnf_sn_txsactive   (CHI-D)
//   tc_chi_coh_e_hnf_sn_txsactive   (wide CHI-E)
// ===========================================================================
class chi_coh_hnf_sn_txsactive_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(chi_coh_hnf_sn_txsactive_base_test #(CFG_P, TYPES_T))

  localparam int SETTLE_C        = 8;
  localparam int DRAIN_CYCLES_C  = 32;

  protected bit sampling;
  protected bit tx_q [$];
  protected bit mv_q [$];

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // Enable the downstream SN-F behind the HN-F, which is what gives the home
  // anything to open a window for.
  protected virtual function void configure_agent_cfgs();
    super.hnf_cfg.hnf_downstream_en = 1'b1;
  endfunction

  task run_phase(input uvm_phase phase);

    item_t dn_req;
    int    n_dn_req;
    int    first_mv;
    int    last_mv;
    int    low_before;
    int    n_moving;
    int    held_in_gap;
    int    uncovered;
    int    first_uncovered;

    phase.raise_objection(this);

    super.wait_reset_settle();

    // Sampling starts with the link already up and nothing downstream
    // outstanding, which is what makes the low-before assertion meaningful.
    this.sampling = 1'b1;

    fork
      forever begin
        @(super.tb_env.hnf_agent.sn_vif[0].monitor_cb);
        if (!this.sampling) begin
          break;
        end
        this.tx_q.push_back(super.tb_env.hnf_agent.sn_vif[0].monitor_cb.txsactive);
        this.mv_q.push_back(
          super.tb_env.hnf_agent.sn_vif[0].monitor_cb.txreqflitv ||
          super.tb_env.hnf_agent.sn_vif[0].monitor_cb.txrspflitv ||
          super.tb_env.hnf_agent.sn_vif[0].monitor_cb.txdatflitv ||
          super.tb_env.hnf_agent.sn_vif[0].monitor_cb.rxreqflitv ||
          super.tb_env.hnf_agent.sn_vif[0].monitor_cb.rxrspflitv ||
          super.tb_env.hnf_agent.sn_vif[0].monitor_cb.rxdatflitv);
      end
    join_none

    super.wait_clocks(SETTLE_C);

    // RN-F0 reads a cold line -> the HN-F must fetch it from the SN-F.
    this.cfg_read_seq(super.hrnf0_rdshared_seq);
    super.hrnf0_rdshared_seq.start(super.tb_env.hrnf0_agent.sequencer);

    super.wait_clocks(DRAIN_CYCLES_C);
    this.sampling = 1'b0;
    super.wait_clocks(2);

    // The downstream fetch really happened. Without this the trace could be
    // judged against a run where the home answered from its own memory and the
    // sideband correctly never rose -- which every assertion below would
    // survive except the first, and that one only by accident.
    n_dn_req = 0;
    while (super.tb_env.dsnf0_req_fifo.try_get(dn_req)) begin
      n_dn_req++;
      if (vip_chi_req_opcode_t'(dn_req.opcode) != VIP_CHI_REQ_READ_NO_SNP_E) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] downstream REQ opcode 0x%0h, expected ReadNoSnp (0x%0h)",
          super.tc_name, dn_req.opcode, VIP_CHI_REQ_READ_NO_SNP_C))
      end
    end
    if (n_dn_req != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] SN-F saw %0d downstream REQs, expected exactly 1 ReadNoSnp",
        super.tc_name, n_dn_req))
    end

    // ---- judge the trace ----------------------------------------------------
    first_mv = -1;
    last_mv  = -1;
    n_moving = 0;
    foreach (this.mv_q[i]) begin
      if (this.mv_q[i]) begin
        if (first_mv < 0) begin
          first_mv = i;
        end
        last_mv = i;
        n_moving++;
      end
    end
    if (first_mv < 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] no flit moved on the home's SN-facing link at all, so the sideband was never asked to cover anything",
        super.tc_name))
    end

    low_before = 0;
    for (int i = 0; i < first_mv; i++) begin
      if (!this.tx_q[i]) begin
        low_before++;
      end
    end
    if (low_before == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] TXSACTIVE was already asserted on every one of the %0d cycle(s) before the first downstream flit: it is following the link state, not a window opened by the home's own request",
        super.tc_name, first_mv))
    end

    uncovered       = 0;
    first_uncovered = -1;
    foreach (this.mv_q[i]) begin
      if (this.mv_q[i] && !this.tx_q[i]) begin
        uncovered++;
        if (first_uncovered < 0) begin
          first_uncovered = i;
        end
      end
    end
    if (uncovered != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] TXSACTIVE was low on %0d cycle(s) carrying a flit (first at trace index %0d): section 14.7.2 requires it asserted before or with the initiating Request flit and held until after the final completing flit",
        super.tc_name, uncovered, first_uncovered))
    end

    held_in_gap = 0;
    for (int i = first_mv; i <= last_mv; i++) begin
      if (this.tx_q[i] && !this.mv_q[i]) begin
        held_in_gap++;
      end
    end
    if (held_in_gap == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] TXSACTIVE was never asserted on a cycle without a flit inside the window: it is being pulsed per flit rather than held across the outstanding transaction",
        super.tc_name))
    end

    if (this.tx_q[this.tx_q.size() - 1]) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] TXSACTIVE was still asserted %0d cycles after the last downstream flit: the window never closed, which is the state a link-driven sideband is permanently in",
        super.tc_name, DRAIN_CYCLES_C))
    end

    `uvm_info(get_name(), $sformatf(
      "PASS [%s] %0d idle cycle(s) before the window opened, %0d flit cycle(s) all covered, %0d held cycle(s) inside it, and the window closed",
      super.tc_name, low_before, n_moving, held_in_gap), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
