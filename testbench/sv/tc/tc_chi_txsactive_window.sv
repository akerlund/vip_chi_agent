// -----------------------------------------------------------------------------
// TXSACTIVE reports that this node MAY have snoopable transactions outstanding,
// so it has to stay asserted across that WHOLE window. The distinction this test
// exists to pin down is between that and a signal merely bracketing each flit:
// both look identical on the cycles carrying flits, and differ only in the gaps
// between them -- which is exactly the interval a receiver reads the sideband to
// decide whether it can gate its snoop logic.
//
// So the evidence is collected in the gaps, on both ends of the link, and the
// traffic is chosen to be the shape that tells the two apart:
//
//   * The requester runs PIPELINED. A sideband scoped to one transaction looks
//     correct on a single serial read -- it rises with the REQ and falls at the
//     completion either way. It is only with several reads overlapping that the
//     difference shows: the sideband must survive the FIRST read retiring while
//     its peers are still in flight, which is a statement about the count of
//     outstanding transactions rather than about any one of them.
//
//   * The completer is watched too. Its response is an RSP and a multi-beat DAT
//     burst separated by credit waits, so a per-flit bracket leaves the sideband
//     low in between while it still owes the rest of the completion.
// -----------------------------------------------------------------------------
class tc_chi_txsactive_window extends chi_base_test;

  `uvm_component_utils(tc_chi_txsactive_window)

  localparam int            N_READS_C     = 4;
  localparam item_t::addr_t TXSA_ADDR_C   = item_t::addr_t'(44'h2300_0000);
  localparam bit [2 : 0]    READ_SIZE_C   = 3'd6;
  localparam int            DRAIN_CYCLES_C = 32;

  // One entry per sampled cycle per vantage.
  protected bit rni_tx_q[$];
  protected bit rni_mv_q[$];
  protected bit snf_tx_q[$];
  protected bit snf_mv_q[$];
  protected bit sampling;

  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Both ends pipelined: the RN-I to keep several reads in flight, and the SN-F
  // to buffer inbound REQs so it does not drop one while mid-burst.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();
    super.rni_cfg.multi_outstanding    = 1'b1;
    super.rni_cfg.max_outstanding_read = N_READS_C;
    super.snf_cfg.multi_outstanding    = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Judge one vantage's trace.
  //
  // The window runs from the first cycle TXSACTIVE is asserted to the last cycle
  // a flit moves -- NOT from the first flit. A completer learns of a request by
  // observing it on the wire and can only raise its sideband on the following
  // edge, so anchoring at the first flit would charge it for one cycle of
  // inherent sequential latency at window open. Anchoring at the first assertion
  // keeps the claim the one that matters: once the node has said it has work
  // outstanding, it must not drop the signal until that work is done.
  // ---------------------------------------------------------------------------
  protected function int judge(input string tag, ref bit tx_q[$], ref bit mv_q[$]);

    int first;
    int last;
    int held_in_gap;
    int low_count;
    int first_low;

    first = -1;
    last  = -1;
    foreach (tx_q[i]) begin
      if ((first < 0) && tx_q[i]) begin
        first = i;
      end
    end
    foreach (mv_q[i]) begin
      if (mv_q[i]) begin
        last = i;
      end
    end

    if (last < 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] [%s] no flit was observed at all -- trace is empty",
        super.tc_name, tag))
    end
    if (first < 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] [%s] TXSACTIVE was never asserted at all",
        super.tc_name, tag))
    end
    if (first > last) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] [%s] TXSACTIVE first rose at %0d, after the last flit at %0d: the sideband never covered any traffic",
        super.tc_name, tag, first, last))
    end

    held_in_gap = 0;
    low_count   = 0;
    first_low   = -1;
    for (int i = first; i <= last; i++) begin
      if (tx_q[i] && !mv_q[i]) begin
        held_in_gap++;
      end
      if (!tx_q[i]) begin
        low_count++;
        if (first_low < 0) begin
          first_low = i;
        end
      end
    end

    if (held_in_gap == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] [%s] TXSACTIVE was never asserted on a cycle without a flit: it is being pulsed per flit rather than held across the outstanding window",
        super.tc_name, tag))
    end

    if (low_count != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] [%s] TXSACTIVE dropped on %0d cycle(s) inside the outstanding window (first at trace index %0d of %0d..%0d): a receiver reading it there would stand its snoop logic down while transactions were still in flight",
        super.tc_name, tag, low_count, first_low, first, last))
    end

    if (tx_q[tx_q.size() - 1]) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] [%s] TXSACTIVE was still asserted %0d cycles after the last flit: the window never closed",
        super.tc_name, tag, DRAIN_CYCLES_C))
    end

    return held_in_gap;
  endfunction

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t responses[$];
    int    rni_gap;
    int    snf_gap;

    phase.raise_objection(this);

    this.sampling = 1'b1;

    fork
      // Requester vantage.
      forever begin
        @(this.tb_env.rni_agent.vif.monitor_cb);
        if (!this.sampling) begin
          break;
        end
        this.rni_tx_q.push_back(this.tb_env.rni_agent.vif.monitor_cb.txsactive);
        this.rni_mv_q.push_back(
          this.tb_env.rni_agent.vif.monitor_cb.txreqflitv ||
          this.tb_env.rni_agent.vif.monitor_cb.txrspflitv ||
          this.tb_env.rni_agent.vif.monitor_cb.txdatflitv ||
          this.tb_env.rni_agent.vif.monitor_cb.rxreqflitv ||
          this.tb_env.rni_agent.vif.monitor_cb.rxrspflitv ||
          this.tb_env.rni_agent.vif.monitor_cb.rxdatflitv);
      end

      // Completer vantage.
      forever begin
        @(this.tb_env.snf_agent.vif.monitor_cb);
        if (!this.sampling) begin
          break;
        end
        this.snf_tx_q.push_back(this.tb_env.snf_agent.vif.monitor_cb.txsactive);
        this.snf_mv_q.push_back(
          this.tb_env.snf_agent.vif.monitor_cb.txreqflitv ||
          this.tb_env.snf_agent.vif.monitor_cb.txrspflitv ||
          this.tb_env.snf_agent.vif.monitor_cb.txdatflitv ||
          this.tb_env.snf_agent.vif.monitor_cb.rxreqflitv ||
          this.tb_env.snf_agent.vif.monitor_cb.rxrspflitv ||
          this.tb_env.snf_agent.vif.monitor_cb.rxdatflitv);
      end

      // The traffic under observation.
      begin
        super.rni0_rd_seq.reset();
        super.rni0_rd_seq.set_requests(N_READS_C);
        super.rni0_rd_seq.set_initial_addr(TXSA_ADDR_C);
        super.rni0_rd_seq.set_size(READ_SIZE_C);
        super.rni0_rd_seq.set_allow_retry(1'b0);
        super.rni0_rd_seq.set_get_response(1'b1);
        super.rni0_rd_seq.set_pipelined_send(1'b1);
        super.rni0_rd_seq.set_verbose(1'b0);
        super.rni0_rd_seq.start(super.v_sqr.rni_sequencer);

        responses = super.rni0_rd_seq.get_responses();

        if (responses.size() != N_READS_C) begin
          `uvm_fatal(get_name(), $sformatf(
            "FATAL [%s] Expected %0d read completions, got %0d",
            super.tc_name, N_READS_C, responses.size()))
        end

        // The pipeline has to have actually overlapped, or the requester
        // vantage degenerates to the serial case this test is not proving.
        if (super.rni_cfg.observed_peak_outstanding <= 1) begin
          `uvm_fatal(get_name(), $sformatf(
            "FATAL [%s] The reads did not overlap (peak outstanding %0d): the sideband was never asked to survive one transaction retiring under another",
            super.tc_name, super.rni_cfg.observed_peak_outstanding))
        end

        // Let the window close and the sideband settle before judging the tail.
        super.wait_clocks(DRAIN_CYCLES_C);
        this.sampling = 1'b0;
        super.wait_clocks(2);
      end
    join

    rni_gap = this.judge("rni", this.rni_tx_q, this.rni_mv_q);
    snf_gap = this.judge("snf", this.snf_tx_q, this.snf_mv_q);

    `uvm_info(get_name(), $sformatf(
      "Test (%s) PASS: TXSACTIVE held across the whole outstanding window on both vantages with peak %0d reads overlapping (flit-free cycles covered: requester=%0d, completer=%0d)",
      super.tc_name, super.rni_cfg.observed_peak_outstanding, rni_gap, snf_gap),
      UVM_LOW)

    phase.drop_objection(this);

  endtask

endclass
