class tc_chi_d_hni_qos extends chi_base_test;

  `uvm_component_utils(tc_chi_d_hni_qos)

  localparam item_t::node_id_t RN0_NODE_ID_C = item_t::node_id_t'('h012);
  localparam item_t::node_id_t RN1_NODE_ID_C = item_t::node_id_t'('h013);

  // Both addresses decode to the same SN target (share address bit 12) so the
  // two RNs contend for one SN and QoS decides the forwarding order.
  localparam item_t::addr_t    RN0_ADDR_C    = item_t::addr_t'(WRITE_READ_ADDR_C);
  localparam item_t::addr_t    RN1_ADDR_C    = item_t::addr_t'(WRITE_READ_ADDR_C + 'h40);
  localparam logic [VIP_CHI_QOS_WIDTH_C-1:0] LOW_QOS_C  = 4'h2;
  localparam logic [VIP_CHI_QOS_WIDTH_C-1:0] HIGH_QOS_C = 4'hd;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Give the HN-I a QoS arbitration collection window so both requestors are
  // captured before it arbitrates.
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // Build Phase
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);

    super.build_phase(phase);

    uvm_config_db #(int)::set(this, "env.hni_agent", "arb_window", 60);
  endfunction

  // ---------------------------------------------------------------------------
  // RN0 (low QoS) and RN1 (high QoS) present reads to the same SN target at the
  // same time. The HN-I must forward the high-QoS request first, so SN-F 0 sees
  // RN1's read before RN0's.
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t rn0_rsp[$];
    item_t rn1_rsp[$];
    item_t sn_reqs[$];
    item_t r;

    phase.raise_objection(this);

    fork
      begin
        super.rni0_rd_seq.reset();
        super.rni0_rd_seq.set_requests(1);
        super.rni0_rd_seq.set_src_id(RN0_NODE_ID_C);
        super.rni0_rd_seq.set_initial_addr(RN0_ADDR_C);
        super.rni0_rd_seq.set_size(3'd6);
        super.rni0_rd_seq.set_allow_retry(1'b0);
        super.rni0_rd_seq.set_qos(LOW_QOS_C);
        super.rni0_rd_seq.set_get_response(1'b1);
        super.rni0_rd_seq.start(super.v_sqr.hrni0_sequencer);
      end
      begin
        super.rni1_rd_seq.reset();
        super.rni1_rd_seq.set_requests(1);
        super.rni1_rd_seq.set_src_id(RN1_NODE_ID_C);
        super.rni1_rd_seq.set_initial_addr(RN1_ADDR_C);
        super.rni1_rd_seq.set_size(3'd6);
        super.rni1_rd_seq.set_allow_retry(1'b0);
        super.rni1_rd_seq.set_qos(HIGH_QOS_C);
        super.rni1_rd_seq.set_get_response(1'b1);
        super.rni1_rd_seq.start(super.v_sqr.hrni1_sequencer);
      end
    join

    rn0_rsp = super.rni0_rd_seq.get_responses();
    rn1_rsp = super.rni1_rd_seq.get_responses();

    if ((rn0_rsp.size() != 1) || (rn1_rsp.size() != 1)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected 1 read response per RN, got RN0=%0d RN1=%0d",
        super.tc_name, rn0_rsp.size(), rn1_rsp.size()))
    end

    // SN-F 0 observed both reads; the first must be the high-QoS RN1 request.
    repeat (2) begin
      super.tb_env.hsnf0_req_fifo.get(r);
      sn_reqs.push_back(r);
    end

    if (sn_reqs[0].qos != HIGH_QOS_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] First forwarded request had QoS 0x%0h, expected high QoS 0x%0h",
        super.tc_name, sn_reqs[0].qos, HIGH_QOS_C))
    end

    if (sn_reqs[0].src_id != RN1_NODE_ID_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] High-QoS request came from src 0x%0h, expected RN1 0x%0h",
        super.tc_name, sn_reqs[0].src_id, RN1_NODE_ID_C))
    end

    if (sn_reqs[1].qos != LOW_QOS_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Second forwarded request had QoS 0x%0h, expected low QoS 0x%0h",
        super.tc_name, sn_reqs[1].qos, LOW_QOS_C))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] HN-I QoS arbitration forwarded high-QoS RN1 before low-QoS RN0",
      super.tc_name), UVM_LOW)

    phase.drop_objection(this);
  endtask
endclass
