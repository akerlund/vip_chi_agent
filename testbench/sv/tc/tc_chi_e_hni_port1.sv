// ===========================================================================
// tc_chi_e_hni_port1
//
// The CHI-E HN-I proxy is 2x2, and until this test existed every testcase drove
// port 0. Four of the harness's binds sit on the port-1 and SN-1 links --
// e_hni_rni1, e_hni_rn1, e_hni_sn1, e_hni_snf1 -- so each carried a checker that
// had never evaluated anything, and a rule added anywhere in the registry landed
// dead on all four. That is not a coverage nicety: a bind whose rules never run
// reports a clean link, which is indistinguishable from a link that held.
//
// One transaction pair reaches all four, because RN port 1 and SN target 1 are
// two ends of the same forwarded path: the request enters at e_hni_rni1 ->
// e_hni_rn1 and leaves at e_hni_sn1 -> e_hni_snf1. E_HNI_PORT1_ADDR_C has bit 12
// set so the proxy's default decode picks target 1.
//
// The exit condition is evidence, not a green log: the seven per-opcode REQ
// field rules must have been EVALUATED at all four vantages. They are total
// rules -- every REQ flit records a pass or a fail -- so a zero count means the
// flit never reached that checker, which is the defect this test closes.
// ===========================================================================
class tc_chi_e_hni_port1 extends chi_e_proxy_base_test;

  typedef vip_chi_item #(CHI_E_WIDE_CFG_C) item_t;

  `uvm_component_utils(tc_chi_e_hni_port1)

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // A rule that never ran has proved nothing, so this asserts on the tally and
  // not on the log. Named vantages rather than a loop over binds: the point is
  // which INTERFACE saw the flit, and the four handles are the four binds.
  // ---------------------------------------------------------------------------
  protected function void require_evaluated_on_port1(input vip_chi_check_id_t id);

    int unsigned rni1;
    int unsigned rn1;
    int unsigned sn1;
    int unsigned snf1;

    rni1 = super.tb_env.hrni1_agent.vif.check_pass_count[id] +
           super.tb_env.hrni1_agent.vif.check_fail_count[id];
    rn1  = super.tb_env.hni_agent.rn_vif[1].check_pass_count[id] +
           super.tb_env.hni_agent.rn_vif[1].check_fail_count[id];
    sn1  = super.tb_env.hni_agent.sn_vif[1].check_pass_count[id] +
           super.tb_env.hni_agent.sn_vif[1].check_fail_count[id];
    snf1 = super.tb_env.hsnf1_agent.vif.check_pass_count[id] +
           super.tb_env.hsnf1_agent.vif.check_fail_count[id];

    if ((rni1 == 0) || (rn1 == 0) || (sn1 == 0) || (snf1 == 0)) begin
      `uvm_error(get_name(), $sformatf(
        "ERROR [%s] %s never evaluated on a port-1 vantage: rni1=%0d rn1=%0d sn1=%0d snf1=%0d",
        super.tc_name, vip_chi_check_name(id), rni1, rn1, sn1, snf1))
    end else begin
      `uvm_info(get_name(), $sformatf(
        "INFO [%s] %s evaluated rni1=%0d rn1=%0d sn1=%0d snf1=%0d",
        super.tc_name, vip_chi_check_name(id), rni1, rn1, sn1, snf1), UVM_LOW)
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Drive a write then a readback from proxy RN port 1 to SN target 1, confirm
  // the proxy relayed both, and require the REQ field rules to have judged them
  // at every port-1 vantage.
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t write_responses[$];
    item_t read_responses[$];
    item_t snf_reqs[$];
    item_t snf_req;

    phase.raise_objection(this);

    super.hrni1_wr_seq.reset();
    super.hrni1_wr_seq.set_requests(1);
    super.hrni1_wr_seq.set_src_id(E_HNI_PORT1_RNI_NODE_ID_C);
    super.hrni1_wr_seq.set_initial_addr(E_HNI_PORT1_ADDR_C);
    super.hrni1_wr_seq.set_size(3'd6);
    super.hrni1_wr_seq.set_data_type(VIP_CHI_DATA_COUNTER_E);
    super.hrni1_wr_seq.set_counter_value(item_t::data_t'('h71));
    super.hrni1_wr_seq.set_counter_increment(item_t::data_t'('h1));
    super.hrni1_wr_seq.set_get_response(1'b1);
    super.hrni1_wr_seq.set_verbose(1'b0);
    super.hrni1_wr_seq.start(super.tb_env.hrni1_agent.sequencer);

    super.hrni1_rd_seq.reset();
    super.hrni1_rd_seq.set_requests(1);
    super.hrni1_rd_seq.set_src_id(E_HNI_PORT1_RNI_NODE_ID_C);
    super.hrni1_rd_seq.set_initial_addr(E_HNI_PORT1_ADDR_C);
    super.hrni1_rd_seq.set_size(3'd6);
    super.hrni1_rd_seq.set_get_response(1'b1);
    super.hrni1_rd_seq.set_verbose(1'b0);
    super.hrni1_rd_seq.start(super.tb_env.hrni1_agent.sequencer);

    write_responses = super.hrni1_wr_seq.get_responses();
    read_responses  = super.hrni1_rd_seq.get_responses();

    if (write_responses.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected 1 write response from proxy port 1, got %0d",
        super.tc_name, write_responses.size()))
    end

    if (read_responses.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected 1 read response from proxy port 1, got %0d",
        super.tc_name, read_responses.size()))
    end

    // SN target 1 is the half of this path nothing had ever driven: if the
    // address decode or the SN-side arbitration sent the pair to target 0
    // instead, this FIFO stays empty and the test says which half failed.
    repeat (2) begin
      super.tb_env.hsnf1_req_fifo.get(snf_req);
      snf_reqs.push_back(snf_req);
    end

    if (snf_reqs[0].opcode != item_t::req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_FULL_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] SN target 1 did not receive the forwarded WriteNoSnpFull: 0x%0h",
        super.tc_name, snf_reqs[0].opcode))
    end

    if (snf_reqs[1].opcode != item_t::req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] SN target 1 did not receive the forwarded ReadNoSnp: 0x%0h",
        super.tc_name, snf_reqs[1].opcode))
    end

    if ((snf_reqs[0].addr != E_HNI_PORT1_ADDR_C) || (snf_reqs[1].addr != E_HNI_PORT1_ADDR_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Forwarded port-1 request address mismatch 0x%0h 0x%0h",
        super.tc_name, snf_reqs[0].addr, snf_reqs[1].addr))
    end

    if (write_responses[0].rsp_opcode != item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Port-1 write completion carried wrong opcode 0x%0h",
        super.tc_name, write_responses[0].rsp_opcode))
    end

    if (read_responses[0].dat_opcode != item_t::dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Port-1 read completion carried wrong DAT opcode 0x%0h",
        super.tc_name, read_responses[0].dat_opcode))
    end

    // Seven total REQ rules, four vantages. Every one of these was dead on all
    // four binds before this test existed.
    this.require_evaluated_on_port1(VIP_CHI_CHK_REQ_ORDER_LEGAL_E);
    this.require_evaluated_on_port1(VIP_CHI_CHK_REQ_ATTR_COMBINATION_LEGAL_E);
    this.require_evaluated_on_port1(VIP_CHI_CHK_REQ_SNP_ATTR_LEGAL_E);
    this.require_evaluated_on_port1(VIP_CHI_CHK_REQ_LIKELY_SHARED_LEGAL_E);
    this.require_evaluated_on_port1(VIP_CHI_CHK_REQ_SIZE_LEGAL_E);
    this.require_evaluated_on_port1(VIP_CHI_CHK_REQ_EXCL_LEGAL_E);
    this.require_evaluated_on_port1(VIP_CHI_CHK_REQ_ENDIAN_LEGAL_E);

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] Proxy port 1 relayed a wide CHI-E write+read to SN target 1 (RN1 -> HN-I -> SN1)",
      super.tc_name), UVM_LOW)

    phase.drop_objection(this);
  endtask
endclass
