// Ordered write stream WITHOUT ExpCompAck.
//
// An ordered write does not have to ask for a CompAck. The Order field asks the
// completer to acknowledge in receipt order; ExpCompAck asks for a separate
// requester-driven acknowledgement afterwards. They are independent, and a
// source is entitled to set the first without the second.
//
// This combination had no coverage: every other ordered-write test sets
// ExpCompAck, so the pipeline retired ordered writes only ever on the path where
// a CompAck follows the completion. That left the plain path -- where a write
// retires the moment its data is sent and its completion is seen -- unexercised
// for ordered traffic, which is precisely where a missing retire condition would
// strand the pipeline with no diagnostic beyond a test that never finishes.
//
// The completion opcode is asserted, not just the response count. A run that
// merely terminated would prove the pipeline did not deadlock; requiring each
// write to hand back the combined CompDBIDResp proves it retired on the
// completion the completer actually sent.
//
// Scope: the SN-F's default combined-completion policy on the CHI-D cut. The
// split DBIDResp+Comp policy and the CHI-E DBIDRespOrd variant are each a
// separate static SN-F configuration and are not covered here.

class tc_chi_ordered_write_no_comp_ack extends chi_base_test;

  `uvm_component_utils(tc_chi_ordered_write_no_comp_ack)

  localparam int            N_C         = 6;
  localparam item_t::addr_t BASE_ADDR_C = item_t::addr_t'(44'h3C80_0000);
  localparam bit [2:0]      SIZE_C      = 3'd6;   // 64 B = 4 beats on the CHI-D cut
  localparam int            SETTLE_C    = 20;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Both ends have to overlap: the RN-I must keep several writes in flight and
  // the SN-F must buffer them rather than servicing each to completion before
  // sampling the next. A stream one deep would retire on the serial path and
  // never reach the pipeline retire condition this test exists to exercise.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.configure_agent_cfgs();

    super.rni_cfg.multi_outstanding       = 1'b1;
    super.rni_cfg.multi_outstanding_write = 1'b1;
    super.rni_cfg.max_outstanding_write   = N_C;
    super.snf_cfg.multi_outstanding       = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t wr_rsp [$];
    item_t w;
    int    wr_peak;
    int    acks;

    phase.raise_objection(this);

    super.rni0_wr_seq.reset();
    super.rni0_wr_seq.set_requests(N_C);
    super.rni0_wr_seq.set_initial_addr(BASE_ADDR_C);
    super.rni0_wr_seq.set_size(SIZE_C);
    super.rni0_wr_seq.set_order(VIP_CHI_ORDER_REQ_ORDER_E);
    super.rni0_wr_seq.set_exp_comp_ack(1'b0);
    super.rni0_wr_seq.set_get_response(1'b1);
    super.rni0_wr_seq.set_pipelined_send(1'b1);
    super.rni0_wr_seq.set_verbose(1'b0);
    super.rni0_wr_seq.start(super.v_sqr.rni_sequencer);

    wr_peak = super.rni_cfg.observed_peak_outstanding;
    wr_rsp  = super.rni0_wr_seq.get_responses();

    super.wait_clocks(SETTLE_C);

    // Every write must have come back. A stranded pipeline would hang rather
    // than return short, but a short return is the cheaper failure to diagnose
    // and costs nothing to check.
    if (wr_rsp.size() != N_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected %0d write responses, got %0d",
        super.tc_name, N_C, wr_rsp.size()))
    end

    // Retired on the completer's own completion flit, not merely retired.
    foreach (wr_rsp[k]) begin
      w = wr_rsp[k];

      if (w.rsp_opcode != item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Write %0d (txn 0x%0h) completed with opcode 0x%0h, expected CompDBIDResp 0x%0h",
          super.tc_name, k, w.txn_id, w.rsp_opcode,
          item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C)))
      end

      if (w.exp_comp_ack != 1'b0) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Write %0d (txn 0x%0h) carried ExpCompAck - this test covers the path where it is clear",
          super.tc_name, k, w.txn_id))
      end
    end

    // A stream one deep can never be out of order, so a run that never
    // overlapped proves nothing and must not be read as a pass.
    if (wr_peak <= 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Ordered write stream did not overlap: peak in-flight was %0d, expected > 1",
        super.tc_name, wr_peak))
    end

    // The ordering guarantee still applies without ExpCompAck: the acknowledging
    // flit is the CompDBIDResp itself.
    acks = super.tb_env.scoreboard.get_order_checked_count();

    if (acks < N_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Ordered-stream check compared only %0d acknowledgements, expected at least %0d - the check did not see this traffic",
        super.tc_name, acks, N_C))
    end

    if (super.tb_env.scoreboard.get_order_violation_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Ordered-stream check reported %0d out-of-order acknowledgement(s) on a completer that serves requests first-come-first-served",
        super.tc_name, super.tb_env.scoreboard.get_order_violation_count()))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] %0d ordered writes without ExpCompAck retired on CompDBIDResp in order (%0d compared; peak in-flight %0d)",
      super.tc_name, N_C, acks, wr_peak), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
