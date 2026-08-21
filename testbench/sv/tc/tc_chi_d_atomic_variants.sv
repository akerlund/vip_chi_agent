class tc_chi_d_atomic_variants extends chi_base_test;

  typedef vip_chi_item #(CHI_D_CFG_C) item_t;

  `uvm_component_utils(tc_chi_d_atomic_variants)

  vip_chi_atomic_store_seq   #(CHI_D_CFG_C) atomic_store_seq;
  vip_chi_atomic_load_seq    #(CHI_D_CFG_C) atomic_load_seq;
  vip_chi_atomic_swap_seq    #(CHI_D_CFG_C) atomic_swap_seq;
  vip_chi_atomic_compare_seq #(CHI_D_CFG_C) atomic_compare_seq;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Start Of Simulation Phase
  // ---------------------------------------------------------------------------
  function void start_of_simulation_phase(input uvm_phase phase);

    super.start_of_simulation_phase(phase);

    this.atomic_store_seq   = vip_chi_atomic_store_seq   #(CHI_D_CFG_C)::type_id::create("atomic_store_seq");
    this.atomic_load_seq    = vip_chi_atomic_load_seq    #(CHI_D_CFG_C)::type_id::create("atomic_load_seq");
    this.atomic_swap_seq    = vip_chi_atomic_swap_seq    #(CHI_D_CFG_C)::type_id::create("atomic_swap_seq");
    this.atomic_compare_seq = vip_chi_atomic_compare_seq #(CHI_D_CFG_C)::type_id::create("atomic_compare_seq");
  endfunction

  // ---------------------------------------------------------------------------
  // Variant Addr
  // ---------------------------------------------------------------------------
  protected function item_t::addr_t variant_addr(input int unsigned index);

    return item_t::addr_t'(
      ATOMIC_VARIANT_BASE_ADDR_C + (index * ATOMIC_VARIANT_ADDR_STRIDE_C));

  endfunction

  // ---------------------------------------------------------------------------
  // Store Variant To Op
  // ---------------------------------------------------------------------------
  protected function vip_chi_atomic_op_t store_variant_to_op(input int unsigned variant);

    case (variant)
      0: return VIP_CHI_ATOMIC_OP_STORE_0_E;
      1: return VIP_CHI_ATOMIC_OP_STORE_1_E;
      2: return VIP_CHI_ATOMIC_OP_STORE_2_E;
      3: return VIP_CHI_ATOMIC_OP_STORE_3_E;
      4: return VIP_CHI_ATOMIC_OP_STORE_4_E;
      5: return VIP_CHI_ATOMIC_OP_STORE_5_E;
      6: return VIP_CHI_ATOMIC_OP_STORE_6_E;
      7: return VIP_CHI_ATOMIC_OP_STORE_7_E;
      default: begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] AtomicStore variant %0d is outside [0:7]",
          super.tc_name, variant))
        return VIP_CHI_ATOMIC_OP_STORE_0_E;
      end
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Load Variant To Op
  // ---------------------------------------------------------------------------
  protected function vip_chi_atomic_op_t load_variant_to_op(input int unsigned variant);

    case (variant)
      0: return VIP_CHI_ATOMIC_OP_LOAD_0_E;
      1: return VIP_CHI_ATOMIC_OP_LOAD_1_E;
      2: return VIP_CHI_ATOMIC_OP_LOAD_2_E;
      3: return VIP_CHI_ATOMIC_OP_LOAD_3_E;
      4: return VIP_CHI_ATOMIC_OP_LOAD_4_E;
      5: return VIP_CHI_ATOMIC_OP_LOAD_5_E;
      6: return VIP_CHI_ATOMIC_OP_LOAD_6_E;
      7: return VIP_CHI_ATOMIC_OP_LOAD_7_E;
      default: begin
        `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] AtomicLoad variant %0d is outside [0:7]",
        super.tc_name, variant))
        return VIP_CHI_ATOMIC_OP_LOAD_0_E;
      end
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Atomic Op To Opcode
  // ---------------------------------------------------------------------------
  protected function item_t::req_opcode_t atomic_op_to_opcode(input vip_chi_atomic_op_t op);

    return item_t::req_opcode_t'(vip_chi_types_pkg::vip_chi_atomic_op_to_req_opcode(op));

  endfunction

  // ---------------------------------------------------------------------------
  // Atomic Variant Operand
  // ---------------------------------------------------------------------------
  protected function item_t::data_t atomic_variant_operand(input int unsigned variant);

    case (variant)
      0: return item_t::data_t'('h10);

      1: return item_t::data_t'('h0f);
      2: return item_t::data_t'('h55);
      3: return item_t::data_t'('ha0);
      4: return ~item_t::data_t'('0);
      5: return ~item_t::data_t'('0);
      6: return ~item_t::data_t'('0);
      7: return item_t::data_t'('0);
      default: begin
        `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] No operand mapping for atomic variant %0d",
        super.tc_name, variant))
        return item_t::data_t'('0);
      end
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Apply Atomic Variant
  // ---------------------------------------------------------------------------
  protected function item_t::data_t apply_atomic_variant(
    input int            variant,
    input item_t::data_t current_value,
    input item_t::data_t operand_value
  );

    logic signed [CHI_D_CFG_C.DATA_BYTES_P * 8 - 1 : 0] current_signed;
    logic signed [CHI_D_CFG_C.DATA_BYTES_P * 8 - 1 : 0] operand_signed;

    current_signed = current_value;
    operand_signed = operand_value;

    case (variant)
      0: return item_t::data_t'(current_value + operand_value);
      1: return item_t::data_t'(current_value & ~operand_value);
      2: return item_t::data_t'(current_value ^ operand_value);
      3: return item_t::data_t'(current_value | operand_value);
      4: return (current_signed > operand_signed) ? current_value : operand_value;
      5: return (current_signed < operand_signed) ? current_value : operand_value;
      6: return (current_value > operand_value) ? current_value : operand_value;
      7: return (current_value < operand_value) ? current_value : operand_value;
      default: begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] Unsupported atomic variant %0d",
          super.tc_name, variant))
        return current_value;
      end
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Setup Atomic Seq
  // ---------------------------------------------------------------------------
  protected task setup_atomic_seq(
    input vip_chi_atomic_seq #(CHI_D_CFG_C) seq,
    input item_t::addr_t               addr,
    input item_t::size_t               beat_size,
    input item_t::data_t               data_beats[$]
  );

    seq.set_requests(1);
    seq.set_initial_addr(addr);
    seq.set_size(beat_size);
    seq.set_get_response(1'b1);
    seq.set_verbose(1'b0);
    seq.set_data(data_beats);
  endtask

  // ---------------------------------------------------------------------------
  // Readback Expect
  // ---------------------------------------------------------------------------
  protected task readback_expect(
    input item_t::addr_t  addr,
    input item_t::size_t  beat_size,
    input item_t::data_t  expected_value,
    input string          label
  );

    item_t read_responses[$];

    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(1);
    super.rni0_rd_seq.set_initial_addr(addr);
    super.rni0_rd_seq.set_size(beat_size);
    super.rni0_rd_seq.set_get_response(1'b1);
    super.rni0_rd_seq.set_verbose(1'b0);
    super.rni0_rd_seq.start(super.v_sqr.rni_sequencer);

    read_responses = super.rni0_rd_seq.get_responses();
    if ((read_responses.size() != 1) ||
        (read_responses[0].data.size() != 1) ||
        (read_responses[0].data[0] != expected_value)) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] %s readback mismatch expected 0x%0h got %0h",
      super.tc_name, label, expected_value,
      (read_responses.size() == 0 || read_responses[0].data.size() == 0) ? '0 : read_responses[0].data[0]))
    end
  endtask

  // ---------------------------------------------------------------------------
  // Run Store Variant
  // ---------------------------------------------------------------------------
  protected task run_store_variant(
    input int unsigned    variant,
    input item_t::addr_t  addr,
    input item_t::size_t  beat_size
  );

    item_t preview;
    item_t responses[$];
    item_t::data_t data_beats[$];
    item_t::data_t initial_value;
    item_t::data_t operand_value;
    item_t::data_t expected_value;

    initial_value  = item_t::data_t'(addr);
    operand_value  = this.atomic_variant_operand(variant);
    expected_value = this.apply_atomic_variant(variant, initial_value, operand_value);

    this.atomic_store_seq.reset();
    this.atomic_store_seq.set_variant(variant);
    this.atomic_store_seq.set_requests(1);
    this.atomic_store_seq.set_initial_addr(addr);
    this.atomic_store_seq.set_size(beat_size);
    this.atomic_store_seq.set_get_response(1'b1);
    this.atomic_store_seq.set_verbose(1'b0);

    preview = this.atomic_store_seq.preview_next_request();
    if (preview.opcode != this.atomic_op_to_opcode(this.store_variant_to_op(variant))) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] AtomicStore%0d preview opcode 0x%0h was unexpected",
      super.tc_name, variant, preview.opcode))
    end

    data_beats.push_back(operand_value);
    this.atomic_store_seq.set_data(data_beats);
    this.atomic_store_seq.start(super.v_sqr.rni_sequencer);
    responses = this.atomic_store_seq.get_responses();

    if ((responses.size() != 1) ||
        (responses[0].rsp_opcode != item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C))) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] AtomicStore%0d completion was not CompDBIDResp",
      super.tc_name, variant))
    end

    this.readback_expect(addr, beat_size, expected_value, $sformatf("AtomicStore%0d", variant));
  endtask

  // ---------------------------------------------------------------------------
  // Run Load Variant
  // ---------------------------------------------------------------------------
  protected task run_load_variant(
    input int unsigned    variant,
    input item_t::addr_t  addr,
    input item_t::size_t  beat_size
  );

    item_t preview;
    item_t responses[$];
    item_t::data_t data_beats[$];
    item_t::data_t initial_value;
    item_t::data_t operand_value;
    item_t::data_t expected_value;

    initial_value  = item_t::data_t'(addr);
    operand_value  = this.atomic_variant_operand(variant);
    expected_value = this.apply_atomic_variant(variant, initial_value, operand_value);

    this.atomic_load_seq.reset();
    this.atomic_load_seq.set_variant(variant);
    this.atomic_load_seq.set_requests(1);
    this.atomic_load_seq.set_initial_addr(addr);
    this.atomic_load_seq.set_size(beat_size);
    this.atomic_load_seq.set_get_response(1'b1);
    this.atomic_load_seq.set_verbose(1'b0);

    preview = this.atomic_load_seq.preview_next_request();
    if (preview.opcode != this.atomic_op_to_opcode(this.load_variant_to_op(variant))) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] AtomicLoad%0d preview opcode 0x%0h was unexpected",
      super.tc_name, variant, preview.opcode))
    end

    data_beats.push_back(operand_value);
    this.atomic_load_seq.set_data(data_beats);
    this.atomic_load_seq.start(super.v_sqr.rni_sequencer);
    responses = this.atomic_load_seq.get_responses();

    if ((responses.size() != 1) ||
        (responses[0].dat_opcode != item_t::dat_opcode_t'(VIP_CHI_DAT_COMP_DATA_C)) ||
        (responses[0].data.size() != 1) ||
        (responses[0].data[0] != initial_value)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] AtomicLoad%0d did not return the expected pre-op value",
        super.tc_name, variant))
    end

    this.readback_expect(addr, beat_size, expected_value, $sformatf("AtomicLoad%0d", variant));
  endtask

  // ---------------------------------------------------------------------------
  // Run Swap Case
  // ---------------------------------------------------------------------------
  protected task run_swap_case(
    input item_t::addr_t addr,
    input item_t::size_t beat_size,
    input item_t::data_t operand_value
  );

    item_t preview;
    item_t responses[$];
    item_t::data_t data_beats[$];
    item_t::data_t initial_value;

    initial_value = item_t::data_t'(addr);

    this.atomic_swap_seq.reset();
    this.atomic_swap_seq.set_requests(1);
    this.atomic_swap_seq.set_initial_addr(addr);
    this.atomic_swap_seq.set_size(beat_size);
    this.atomic_swap_seq.set_get_response(1'b1);
    this.atomic_swap_seq.set_verbose(1'b0);

    preview = this.atomic_swap_seq.preview_next_request();
    if (preview.opcode != item_t::req_opcode_t'(VIP_CHI_REQ_ATOMIC_SWAP_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] AtomicSwap preview opcode 0x%0h was unexpected",
        super.tc_name, preview.opcode))
    end

    data_beats.push_back(operand_value);
    this.atomic_swap_seq.set_data(data_beats);
    this.atomic_swap_seq.start(super.v_sqr.rni_sequencer);
    responses = this.atomic_swap_seq.get_responses();

    if ((responses.size() != 1) ||
        (responses[0].data.size() != 1) ||
        (responses[0].data[0] != initial_value)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] AtomicSwap did not return the expected pre-swap value",
        super.tc_name))
    end

    this.readback_expect(addr, beat_size, operand_value, "AtomicSwap");
  endtask

  // ---------------------------------------------------------------------------
  // Run Compare Case
  // ---------------------------------------------------------------------------
  protected task run_compare_case(
    input item_t::addr_t addr,
    input item_t::size_t beat_size,
    input item_t::data_t compare_value,
    input item_t::data_t swap_value,
    input bit            expect_match,
    input string         label
  );

    item_t preview;
    item_t responses[$];
    item_t::data_t data_beats[$];
    item_t::data_t initial_value;
    item_t::data_t expected_value;

    initial_value  = item_t::data_t'(addr);
    expected_value = expect_match ? swap_value : initial_value;

    this.atomic_compare_seq.reset();
    this.atomic_compare_seq.set_requests(1);
    this.atomic_compare_seq.set_initial_addr(addr);
    // AtomicCompare Size is the COMBINED compare+swap size (IHI 0050): two
    // beat_size operands span Size = beat_size + 1. readback_expect below still
    // reads the per-operand granule (beat_size). [P2]
    this.atomic_compare_seq.set_size(item_t::size_t'(beat_size + 1));
    this.atomic_compare_seq.set_get_response(1'b1);
    this.atomic_compare_seq.set_verbose(1'b0);

    preview = this.atomic_compare_seq.preview_next_request();
    data_beats.push_back(compare_value);
    data_beats.push_back(swap_value);
    if ((preview.opcode != item_t::req_opcode_t'(VIP_CHI_REQ_ATOMIC_COMPARE_C)) ||
      (preview.data.size() != 2)) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] %s preview request did not carry the expected compare/swap payload",
      super.tc_name, label))
    end

    this.atomic_compare_seq.set_data(data_beats);
    this.atomic_compare_seq.start(super.v_sqr.rni_sequencer);
    responses = this.atomic_compare_seq.get_responses();

    if ((responses.size() != 1) ||
        (responses[0].data.size() != 1) ||
        (responses[0].data[0] != initial_value)) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] %s did not return the expected pre-compare value",
      super.tc_name, label))
    end

    this.readback_expect(addr, beat_size, expected_value, label);
  endtask

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t::size_t beat_size;
    int unsigned variant;

    // The wide-operand stress profile is out of spec by Table 2-17, on purpose.
    // The rule is turned down to OFF -- still evaluated, still counted, not
    // reported -- and required to have fired before this test ends. See the
    // §22 L7 note in vip_chi_atomic_seq for why both halves are needed.
    super.tb_env.rni_agent.vif.check_severity[VIP_CHI_CHK_ATOMIC_SIZE_LEGAL_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.snf_agent.vif.check_severity[VIP_CHI_CHK_ATOMIC_SIZE_LEGAL_E] =
      VIP_CHI_CHK_SEV_OFF_E;

    phase.raise_objection(this);

    beat_size = item_t::size_t'($clog2(CHI_D_CFG_C.DATA_BYTES_P));

    for (variant = 0; variant < 8; variant++) begin
      this.run_store_variant(variant, this.variant_addr(variant), beat_size);
    end

    for (variant = 0; variant < 8; variant++) begin
      this.run_load_variant(variant, this.variant_addr(8 + variant), beat_size);
    end

    this.run_swap_case(
      this.variant_addr(16),
      beat_size,
      item_t::data_t'('h4455));

    this.run_compare_case(
      this.variant_addr(17),
      beat_size,
      item_t::data_t'(this.variant_addr(17)),
      item_t::data_t'('h99aa),
      1'b1,
      "AtomicCompareHit");

    this.run_compare_case(
      this.variant_addr(18),
      beat_size,
      item_t::data_t'(this.variant_addr(18)) ^ item_t::data_t'('h1),
      item_t::data_t'('h55aa),
      1'b0,
      "AtomicCompareMiss");

    // The waiver's second half: this traffic must have been out of spec in the
    // way the profile claims. A silenced rule that stopped firing would look
    // exactly like a passing test.
    if ((super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_ATOMIC_SIZE_LEGAL_E] == 0) ||
        (super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_ATOMIC_SIZE_LEGAL_E] == 0)) begin
      `uvm_error(get_name(), $sformatf(
        "ERROR [%s] %s recorded no violation at one or both ends, but this test drives the wide-operand stress profile on purpose; either the sizes are legal now and the waiver should go, or the rule stopped evaluating",
        super.tc_name, vip_chi_check_name(VIP_CHI_CHK_ATOMIC_SIZE_LEGAL_E)))
    end

    phase.drop_objection(this);
  endtask
endclass