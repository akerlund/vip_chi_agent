// ===========================================================================
// chi_coh_txsactive_window_base_test
//
// TXSACTIVE at the HOME: the window opens when a request is CAPTURED, not when
// the home gets round to serving it.
//
// IHI 0050 E section 14.7.2 / D section 13.7.2 states the obligation separately
// for each role, and the home's is its own: on receiving a transaction
// initiating flit it must assert TXSACTIVE before or in the same cycle in which
// its first Response flit is sent, and "keep TXSACTIVE asserted until after the
// final completing flit is sent or received".
//
// tc_chi_txsactive_window already proves the held window on the RN-I requester
// and SN-F completer vantages. The home's is a different claim, because a home
// serves one request at a time out of a queue: the interval a request spends
// WAITING is part of the window the specification asks for, and it is invisible
// on any run where the home is never busy when a request arrives.
//
// So the queue is made non-empty on purpose. RN-F1 reads a line RN-F0 owns,
// which the home can only answer by snooping RN-F0 first -- tens of cycles --
// and RN-F0's own read of a DIFFERENT line is launched into the middle of that.
// It is captured on port 0 and then sits in the queue while the home finishes
// port 1's transaction, so on port 0 the whole interval between the request
// arriving and the first response flit going out is queueing delay:
//
//   * an implementation that raises TXSACTIVE when it starts SERVING a request
//     leaves the sideband low across that interval, and fails the lead check;
//   * one that pulses per flit leaves it low in the gaps, and fails the held
//     check;
//   * one that drives it from link-up passes both and fails the close check.
//
// Two requesters rather than one pipelined requester is a fact about the VIP
// rather than a preference: the multi-outstanding datapath covers ReadNoSnp,
// WriteNoSnp, atomics and persist only, so a single RN-F cannot hold two
// coherent reads in flight and the cross-port queue is what makes the home's
// waiting interval reachable at all.
//
// Used by:
//   tc_chi_coh_e_txsactive_window  (wide CHI-E)
//   tc_chi_coh_d_txsactive_window  (CHI-D)
// ===========================================================================
class chi_coh_txsactive_window_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(chi_coh_txsactive_window_base_test #(CFG_P, TYPES_T))

  localparam longint unsigned LINE_A_C = WRITE_READ_ADDR_C;
  localparam longint unsigned LINE_B_C = WRITE_READ_ADDR_C + 'h400;
  // Long enough that RN-F1's request is captured first and its snoop round trip
  // is under way, short enough that it has not completed.
  localparam int LAUNCH_SKEW_C      = 6;
  // The queueing interval has to be real, not a one-cycle accident of
  // arbitration.
  localparam int MIN_QUEUE_CYCLES_C = 4;
  localparam int DRAIN_CYCLES_C     = 48;

  // Per cycle on the home's port-0 wire: what the sideband did, what moved,
  // when the request arrived, when the first response went out.
  protected bit tx_q     [$];
  protected bit mv_q     [$];
  protected bit req_in_q [$];
  protected bit rsp_out_q[$];
  protected bit sampling;

  // Reported by judge().
  protected int queued_cycles;
  protected int lead_cycles;
  protected int held_in_gap;

  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  protected function int first_set(ref bit q[$]);
    foreach (q[i]) begin
      if (q[i]) begin
        return i;
      end
    end
    return -1;
  endfunction

  // ---------------------------------------------------------------------------
  // Judge the home's port-0 trace.
  // ---------------------------------------------------------------------------
  protected function void judge();

    int req_idx;
    int rsp_idx;
    int high_idx;
    int last_moving;
    int low_in_wait;
    int first_low_in_wait;
    int low_count;
    int first_low;

    req_idx  = this.first_set(this.req_in_q);
    rsp_idx  = this.first_set(this.rsp_out_q);
    high_idx = this.first_set(this.tx_q);

    if (req_idx < 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] no request arrived on the home's port 0 -- nothing to judge",
        super.tc_name))
    end
    if (rsp_idx < 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the home sent no response flit on port 0: the request it captured was never answered",
        super.tc_name))
    end
    if (high_idx < 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the home never asserted TXSACTIVE on port 0", super.tc_name))
    end

    // The queueing interval has to exist, or this test degenerates into the
    // serial case tc_chi_txsactive_window already covers.
    this.queued_cycles = rsp_idx - req_idx;
    if (this.queued_cycles < MIN_QUEUE_CYCLES_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the home answered port 0 only %0d cycle(s) after the request arrived: it was not busy with the other port, so the waiting interval this test exists to measure never happened",
        super.tc_name, this.queued_cycles))
    end

    // 14.7.2's deadline: asserted before or in the cycle of the first Response
    // flit. This is the half a dispatch-time window fails, because the home does
    // not start serving until the other transaction is done.
    if (high_idx > rsp_idx) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the home first asserted TXSACTIVE at cycle %0d, after its first response flit on port 0 at %0d: 14.7.2 requires the sideband up before or in the cycle of the first Response flit",
        super.tc_name, high_idx, rsp_idx))
    end
    this.lead_cycles = rsp_idx - high_idx;

    // And it must have been up for the whole wait, not raised just in time.
    // From req_idx + 1: the home observes the arriving flit at one edge and can
    // only reflect it at the next, so charging it for the arrival cycle itself
    // would be charging it for inherent sequential latency rather than for
    // anything the specification asks of it. Every cycle after that is the
    // home's own choice.
    low_in_wait       = 0;
    first_low_in_wait = -1;
    for (int i = req_idx + 1; i <= rsp_idx; i++) begin
      if (!this.tx_q[i]) begin
        low_in_wait++;
        if (first_low_in_wait < 0) begin
          first_low_in_wait = i;
        end
      end
    end
    if (low_in_wait != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the home dropped TXSACTIVE on %0d cycle(s) of the %0d-cycle interval a captured request spent waiting for service (first at %0d, request arrived at %0d): the window has to cover the wait, not only the service",
        super.tc_name, low_in_wait, this.queued_cycles, first_low_in_wait, req_idx))
    end

    last_moving = -1;
    foreach (this.mv_q[i]) begin
      if (this.mv_q[i]) begin
        last_moving = i;
      end
    end

    this.held_in_gap = 0;
    low_count        = 0;
    first_low        = -1;
    for (int i = high_idx; i <= last_moving; i++) begin
      if (this.tx_q[i] && !this.mv_q[i]) begin
        this.held_in_gap++;
      end
      if (!this.tx_q[i]) begin
        low_count++;
        if (first_low < 0) begin
          first_low = i;
        end
      end
    end

    if (this.held_in_gap == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the home never asserted TXSACTIVE on a cycle without a flit: it is pulsing per flit rather than holding across the outstanding window",
        super.tc_name))
    end

    if (low_count != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the home dropped TXSACTIVE on %0d cycle(s) inside the outstanding window (first at %0d of %0d..%0d): a receiver reading it there would stand its snoop logic down while the home still owed a completion",
        super.tc_name, low_count, first_low, high_idx, last_moving))
    end

    if (this.tx_q[this.tx_q.size() - 1]) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the home still asserted TXSACTIVE %0d cycles after the last flit: the window never closed, so the sideband carries nothing",
        super.tc_name, DRAIN_CYCLES_C))
    end

  endfunction

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t setup_rsp[$];
    item_t rsp_a[$];
    item_t rsp_b[$];

    phase.raise_objection(this);

    super.wait_reset_settle();

    // Setup, before sampling starts: RN-F0 takes line A Unique, so RN-F1's read
    // of A cannot be answered without snooping RN-F0.
    this.cfg_read_seq(super.hrnf0_rdunique_seq, item_t::addr_t'(LINE_A_C));
    super.hrnf0_rdunique_seq.start(super.tb_env.hrnf0_agent.sequencer);
    setup_rsp = super.hrnf0_rdunique_seq.get_responses();
    if (setup_rsp.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 did not acquire line A (got %0d response(s))",
        super.tc_name, setup_rsp.size()))
    end
    super.wait_clocks(8);

    this.sampling = 1'b1;

    fork
      // The home's port-0 vantage. tx is the home's own direction, so rx REQ is
      // the request arriving and tx RSP/DAT are its responses. Snoops are left
      // out of the response set deliberately: a snoop belongs to the OTHER
      // requester's transaction, and 14.7.2's deadline is the first Response
      // flit of the transaction this port initiated. They ARE in the "moving"
      // set, because "no flit moving" has to mean the port is genuinely idle.
      forever begin
        @(super.tb_env.hnf_agent.rn_vif[0].monitor_cb);
        if (!this.sampling) begin
          break;
        end
        this.tx_q.push_back(super.tb_env.hnf_agent.rn_vif[0].monitor_cb.txsactive);
        this.mv_q.push_back(
          super.tb_env.hnf_agent.rn_vif[0].monitor_cb.txreqflitv ||
          super.tb_env.hnf_agent.rn_vif[0].monitor_cb.txrspflitv ||
          super.tb_env.hnf_agent.rn_vif[0].monitor_cb.txdatflitv ||
          super.tb_env.hnf_agent.rn_vif[0].monitor_cb.txsnpflitv ||
          super.tb_env.hnf_agent.rn_vif[0].monitor_cb.rxreqflitv ||
          super.tb_env.hnf_agent.rn_vif[0].monitor_cb.rxrspflitv ||
          super.tb_env.hnf_agent.rn_vif[0].monitor_cb.rxdatflitv);
        this.req_in_q.push_back(
          super.tb_env.hnf_agent.rn_vif[0].monitor_cb.rxreqflitv);
        this.rsp_out_q.push_back(
          super.tb_env.hnf_agent.rn_vif[0].monitor_cb.txrspflitv ||
          super.tb_env.hnf_agent.rn_vif[0].monitor_cb.txdatflitv);
      end

      // RN-F1 reads the line RN-F0 owns: the home must snoop before it can
      // answer, and it is busy for as long as that takes.
      begin
        this.cfg_read_seq(super.hrnf1_rdshared_seq, item_t::addr_t'(LINE_A_C));
        super.hrnf1_rdshared_seq.start(super.tb_env.hrnf1_agent.sequencer);
        rsp_a = super.hrnf1_rdshared_seq.get_responses();
      end

      // RN-F0's own read of a different line, launched into the middle of that.
      begin
        super.wait_clocks(LAUNCH_SKEW_C);
        this.cfg_read_seq(super.hrnf0_rdshared_seq, item_t::addr_t'(LINE_B_C));
        super.hrnf0_rdshared_seq.start(super.tb_env.hrnf0_agent.sequencer);
        rsp_b = super.hrnf0_rdshared_seq.get_responses();

        super.wait_clocks(DRAIN_CYCLES_C);
        this.sampling = 1'b0;
        super.wait_clocks(2);
      end
    join

    if ((rsp_a.size() != 1) || (rsp_b.size() != 1)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] expected 1+1 responses, got %0d/%0d",
        super.tc_name, rsp_a.size(), rsp_b.size()))
    end
    if (rsp_a[0].rsp_resp != VIP_CHI_RESP_STATE_SC_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F1 read of line A granted 0x%0h, expected SC (0x%0h)",
        super.tc_name, rsp_a[0].rsp_resp, VIP_CHI_RESP_STATE_SC_E))
    end

    // The snoop is what made the home busy; without it there was no queue.
    if (super.tb_env.hrnf0_snp_fifo.used() == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 was never snooped, so the home was not busy when RN-F0's own request arrived",
        super.tc_name))
    end

    this.judge();

    `uvm_info(get_name(), $sformatf(
      "Test (%s) PASS: the home held TXSACTIVE on port 0 across a %0d-cycle wait for service, raising it %0d cycle(s) before its first response flit, covering %0d flit-free cycle(s), and closed it after the traffic drained",
      super.tc_name, this.queued_cycles, this.lead_cycles, this.held_in_gap),
      UVM_LOW)

    phase.drop_objection(this);

  endtask
endclass
