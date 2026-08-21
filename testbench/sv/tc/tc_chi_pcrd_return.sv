// The other half of the retry handshake. tc_chi_pcrd_leak proves the requester
// NOTICES a P-credit it was granted and never used; this proves it can GIVE ONE
// BACK, which is what the specification actually requires: any credit that is not
// required must be returned in a timely manner, because a held credit keeps a
// re-issue slot reserved at the completer forever.
//
// The setup is deliberately the leak test's setup -- pipelined RN-I, one clean
// write to bring the link to RUN, then a raw PCrdGrant that bounces nothing --
// with cfg.return_unused_pcrd turned ON. Same stimulus, opposite verdict: the
// credit must be handed back rather than counted as a leak.
//
// What is asserted, in order of what would otherwise go unnoticed:
//
//   * a PCrdReturn REQ actually reaches the wire, observed through the monitor.
//     Draining the driver's internal bank without emitting a flit would satisfy
//     every counter here and return nothing to the completer.
//   * its PCrdType matches the grant. A return naming the wrong type frees a
//     resource the completer never reserved and leaves the real one held.
//   * TxnID is zero and TgtID is the granter -- the identifier rules for this
//     transaction are fixed by the specification, not chosen by the requester.
//   * the bank is empty afterwards, so the leak check the sibling test guards
//     has nothing left to report.

class tc_chi_pcrd_return extends chi_base_test;

  `uvm_component_utils(tc_chi_pcrd_return)

  localparam int PCRD_TYPE_C = 3;

  vip_chi_raw_seq #(CHI_D_CFG_C) snf_raw_seq;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // The injected PCrdGrant bounces nothing, so the scoreboard opens a context
  // for it that never completes and reports the stray flit as an incomplete
  // transaction. That is correct of the scoreboard and beside the point here:
  // this test is a guard on the driver's credit accounting.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_tb_cfg();

    super.configure_tb_cfg();
    super.tb_cfg.scoreboard_enable = 1'b0;
  endfunction

  // ---------------------------------------------------------------------------
  // Only the pipelined path banks P-credits, so that is the path with anything
  // to return; the serial retry handler pairs its RetryAck and PCrdGrant
  // directly and never holds one.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.configure_agent_cfgs();
    super.rni_cfg.multi_outstanding  = 1'b1;
    super.rni_cfg.return_unused_pcrd = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Create the SN-F raw-flit helper once topology is ready.
  // ---------------------------------------------------------------------------
  function void start_of_simulation_phase(input uvm_phase phase);

    super.start_of_simulation_phase(phase);

    this.snf_raw_seq = vip_chi_raw_seq #(CHI_D_CFG_C)::type_id::create("snf_raw_seq");
  endfunction

  // ---------------------------------------------------------------------------
  // Bring the link up through the pipelined loop, bank one unused P-credit, and
  // require it to come back.
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t::raw_rsp_t raw_rsp;
    item_t            req_item;
    item_t            returned;

    phase.raise_objection(this);

    super.rni0_wr_seq.reset();
    super.rni0_wr_seq.set_requests(1);
    super.rni0_wr_seq.set_initial_addr(WRITE_READ_ADDR_C);
    super.rni0_wr_seq.set_size(3'd6);
    super.rni0_wr_seq.set_get_response(1'b1);
    super.rni0_wr_seq.set_verbose(1'b0);
    super.rni0_wr_seq.start(super.v_sqr.rni_sequencer);

    super.wait_clocks(4);
    super.drain_observation_fifos();

    raw_rsp          = '0;
    raw_rsp.opcode   = item_t::rsp_opcode_t'(VIP_CHI_RSP_PCRD_GRANT_C);
    raw_rsp.pcrdtype = PCRD_TYPE_C;
    raw_rsp.resp     = VIP_CHI_RESP_STATE_I_E;
    raw_rsp.resperr  = VIP_CHI_RESP_ERR_NORMAL_OKAY_E;
    raw_rsp.srcid    = SNF_NODE_ID_C;
    raw_rsp.tgtid    = RNI_NODE_ID_C;

    this.snf_raw_seq.reset();
    this.snf_raw_seq.add_raw_rsp(raw_rsp);
    this.snf_raw_seq.start(super.v_sqr.snf_sequencer);

    super.wait_clocks(16);

    // The credit went back on the wire, not just out of an internal array.
    returned = null;
    while (super.tb_env.rni_req_fifo.try_get(req_item)) begin
      if (req_item.opcode == item_t::req_opcode_t'(VIP_CHI_REQ_PCRD_RETURN_C)) begin
        returned = req_item;
      end
    end

    if (returned == null) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] No PCrdReturn reached the wire: the banked credit was never handed back",
        super.tc_name))
    end

    if (returned.pcrd_type != PCRD_TYPE_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] PCrdReturn PCrdType 0x%0h did not match the granted 0x%0h",
        super.tc_name, returned.pcrd_type, PCRD_TYPE_C))
    end

    if (returned.txn_id != '0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] PCrdReturn TxnID 0x%0h was not zero",
        super.tc_name, returned.txn_id))
    end

    if (returned.tgt_id != item_t::node_id_t'(SNF_NODE_ID_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] PCrdReturn TgtID 0x%0h was not the granter 0x%0h",
        super.tc_name, returned.tgt_id, SNF_NODE_ID_C))
    end

    if (super.tb_env.rni_agent.rni_driver.n_pcrd_returned != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected 1 returned credit, driver counted %0d",
        super.tc_name, super.tb_env.rni_agent.rni_driver.n_pcrd_returned))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] The unused P-credit was returned with a PCrdReturn carrying the granted PCrdType, TxnID zero and the granter as TgtID",
      super.tc_name), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
