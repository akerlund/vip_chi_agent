// Negative control for the RN-I's end-of-test P-credit accounting. The requester
// banks a PCrdGrant against the RetryAck that owed it; a grant nothing bounced is
// a credit the completer set aside and the requester never took. Nothing else in
// the flow notices - the traffic completes and the test passes - so the only
// thing standing between a half-finished retry handshake and a green run is the
// driver's check_phase.
//
// Inject a bare PCrdGrant from the SN-F with the RN-I pipelined (the path that
// banks credits), then require the leak to have been reported. A report catcher
// demotes the deliberately induced error so it does not count against the run.

class tc_chi_pcrd_leak extends chi_base_test;

  `uvm_component_utils(tc_chi_pcrd_leak)

  localparam int PCRD_TYPE_C = 3;

  chi_pcrd_leak_negctl_catcher   pcrd_catcher;
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
  // this test is a guard on the driver's credit accounting, so keep the
  // scoreboard's separate (and correct) complaint out of the verdict.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_tb_cfg();

    super.configure_tb_cfg();
    super.tb_cfg.scoreboard_enable = 1'b0;
  endfunction

  // ---------------------------------------------------------------------------
  // Only the pipelined path banks P-credits: the serial retry handler pairs its
  // single RetryAck and PCrdGrant directly and never holds one. So the RN-I is
  // pipelined and the SN-F is NOT -- its buffered loop is auto-responder only
  // and never pulls from its sequencer, which would leave the raw injection
  // below waiting forever. A single write needs no SN-F buffering anyway.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.configure_agent_cfgs();
    super.rni_cfg.multi_outstanding = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Create the catcher and the SN-F raw-flit helper once topology is ready. The
  // catcher stays installed through check_phase, which is where the leak is
  // reported.
  // ---------------------------------------------------------------------------
  function void start_of_simulation_phase(input uvm_phase phase);

    super.start_of_simulation_phase(phase);

    this.pcrd_catcher = new("pcrd_leak_catcher");
    this.snf_raw_seq  = vip_chi_raw_seq #(CHI_D_CFG_C)::type_id::create("snf_raw_seq");
    uvm_report_cb::add(null, this.pcrd_catcher);
  endfunction

  // ---------------------------------------------------------------------------
  // Bring the link up through the pipelined loop, then leak one P-credit.
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t::raw_rsp_t raw_rsp;

    phase.raise_objection(this);

    // One clean write brings the link to RUN through the pipelined loop, so the
    // RSP monitor that banks P-credits is running when the grant arrives.
    super.rni0_wr_seq.reset();
    super.rni0_wr_seq.set_requests(1);
    super.rni0_wr_seq.set_initial_addr(WRITE_READ_ADDR_C);
    super.rni0_wr_seq.set_size(3'd6);
    super.rni0_wr_seq.set_get_response(1'b1);
    super.rni0_wr_seq.set_verbose(1'b0);
    super.rni0_wr_seq.start(super.v_sqr.rni_sequencer);

    super.wait_clocks(4);

    // A PCrdGrant that bounces nothing. The RN-I banks it, and no pipeline entry
    // is owed that PCrdType, so it stays banked for the rest of the run.
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

    super.wait_clocks(8);

    phase.drop_objection(this);
  endtask

  // ---------------------------------------------------------------------------
  // check_phase is bottom-up, so the RN-I driver has already reported by the
  // time report_phase runs. (The Python port asserts in report_phase for the
  // same reason: pyUVM runs check_phase top-down.)
  // ---------------------------------------------------------------------------
  function void report_phase(input uvm_phase phase);

    super.report_phase(phase);

    uvm_report_cb::delete(null, this.pcrd_catcher);

    if (!this.pcrd_catcher.saw_leak_error) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-I did NOT report the leaked P-credit - the end-of-test credit accounting may be vacuous",
        super.tc_name))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] RN-I reported the granted-and-unused P-credit (negative control passed)",
      super.tc_name), UVM_LOW)
  endfunction

endclass
