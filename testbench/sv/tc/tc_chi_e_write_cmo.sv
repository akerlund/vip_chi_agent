// ---------------------------------------------------------------------------
// Combined Write + CMO (Issue E): one request carrying both a write and a cache
// maintenance operation to the same address.
//
// All six forms in one run -- Full and Ptl, each with CleanSh, CleanInv and
// CleanShPerSep -- because the six differ only in two independent choices and
// testing one of them would leave the other five as opcodes nothing has ever put
// on a wire.
//
// What is actually asserted, in order of what would otherwise go unnoticed:
//
//   * the CMO half is COMPLETED. The write half of a combined request completes
//     exactly like an ordinary write, so a completer that ignored the CMO
//     entirely would still produce a run that looks clean from the requester's
//     side. CompCMO is the separate response that says the CMO happened, and it
//     is checked here as an observed flit rather than as an absence of errors.
//   * the CMO responses arrive AFTER the write's own completion, and the persist
//     leg after CompCMO, for the two persistent forms. That is the ordering the
//     whole family turns on -- the CMO acts on the state the write leaves behind
//     -- and it is the one thing here a completer can get wrong while still
//     answering every flit. RSP fifo order is RSP channel order, so this is the
//     real observation, not a restatement of what the driver enforces.
//   * CompAck, on the three Ptl forms, which set ExpCompAck. The spec permits
//     ExpCompAck on a Non-CopyBack Combined Write and requires the CompAck to be
//     sent AFTER the write's completion response -- a lower bound, with no upper
//     bound, so the requester is free to send it any time later. This test
//     checks the bound that exists rather than the placement this RN-I happens
//     to pick: CompAck after the write completion, present exactly when
//     ExpCompAck was set and absent when it was not. The three Full forms leave
//     ExpCompAck clear, so both populations run in the same test.
//   * the data landed, read back and compared beat by beat afterwards. A
//     completer that answered correctly and dropped the write would satisfy both
//     assertions above.
//
// The scoreboard is watching all of this independently: the combined forms carry
// a completion contract that requires CompCMO (and Persist for the persistent
// forms), so an incomplete transaction fails the run at check_phase whether or
// not this test looks for it.
// ---------------------------------------------------------------------------

class tc_chi_e_write_cmo extends chi_e_base_test;

  typedef vip_chi_item #(CHI_E_WIDE_CFG_C) item_t;

  `uvm_component_utils(tc_chi_e_write_cmo)

  localparam bit [2:0] SIZE_C    = 3'd6;
  localparam int       FORMS_C   = 6;
  localparam int       SETTLE_C  = 20;

  vip_chi_write_cmo_seq #(CHI_E_WIDE_CFG_C) write_cmo_seq;

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Create the combined Write + CMO sequence once topology is ready.
  // ---------------------------------------------------------------------------
  function void start_of_simulation_phase(input uvm_phase phase);

    super.start_of_simulation_phase(phase);

    this.write_cmo_seq =
      vip_chi_write_cmo_seq #(CHI_E_WIDE_CFG_C)::type_id::create("write_cmo_seq");
  endfunction

  // ---------------------------------------------------------------------------
  // The REQ opcode each form must put on the wire. Spelled out rather than
  // recomputed from the sequence's own mapping: a test that asked the thing
  // under test what it intended to send would agree with itself no matter what
  // came out.
  // ---------------------------------------------------------------------------
  protected function item_t::req_opcode_t expected_opcode(
    input bit                    partial,
    input vip_chi_combined_cmo_e cmo);

    case (cmo)
      VIP_CHI_CMO_CLEAN_INV_E: begin
        return partial
          ? item_t::req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_PTL_CLEAN_INV_C)
          : item_t::req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_FULL_CLEAN_INV_C);
      end
      VIP_CHI_CMO_CLEAN_SH_PER_SEP_E: begin
        return partial
          ? item_t::req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_PTL_CLEAN_SH_PER_SEP_C)
          : item_t::req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_FULL_CLEAN_SH_PER_SEP_C);
      end
      default: begin
        return partial
          ? item_t::req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_PTL_CLEAN_SH_C)
          : item_t::req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_FULL_CLEAN_SH_C);
      end
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    bit                    form_partial [FORMS_C];
    vip_chi_combined_cmo_e form_cmo     [FORMS_C];
    bit                    form_ack     [FORMS_C];
    item_t::data_t         written      [FORMS_C][];
    item_t::be_t           written_be   [FORMS_C][];

    item_t wr_rsp[$];
    item_t rd_rsp[$];
    item_t req_item;
    item_t rsp_item;
    item_t dat_item;
    item_t stray_item;

    int expected_beats;
    int rsp_index;
    int write_comp_index;
    int comp_cmo_index;
    int persist_index;
    int comp_ack_index;
    int dat_beats_seen;

    phase.raise_objection(this);

    form_partial = '{1'b0, 1'b0, 1'b0, 1'b1, 1'b1, 1'b1};
    form_cmo     = '{VIP_CHI_CMO_CLEAN_SH_E,
                     VIP_CHI_CMO_CLEAN_INV_E,
                     VIP_CHI_CMO_CLEAN_SH_PER_SEP_E,
                     VIP_CHI_CMO_CLEAN_SH_E,
                     VIP_CHI_CMO_CLEAN_INV_E,
                     VIP_CHI_CMO_CLEAN_SH_PER_SEP_E};

    // ExpCompAck on the Ptl half only. Splitting it this way rather than setting
    // it everywhere keeps both populations in one run: every CMO kind is covered
    // with a CompAck and without one, so "no CompAck appeared" is a failure on
    // one half and the expected outcome on the other.
    form_ack     = '{1'b0, 1'b0, 1'b0, 1'b1, 1'b1, 1'b1};

    expected_beats = vip_chi_types_pkg::chi_xfer_dat_beats(
      item_t::size_t'(SIZE_C), CHI_E_WIDE_CFG_C.DATA_BYTES_P);

    // Nothing left over from bring-up may be mistaken for a response to the
    // first form.
    super.drain_observation_fifos();

    for (int form = 0; form < FORMS_C; form++) begin

      this.write_cmo_seq.reset();
      this.write_cmo_seq.set_partial(form_partial[form]);
      this.write_cmo_seq.set_cmo(form_cmo[form]);
      this.write_cmo_seq.set_exp_comp_ack(form_ack[form]);
      this.write_cmo_seq.set_requests(1);
      this.write_cmo_seq.set_initial_addr(
        E_WRITE_CMO_ADDR_C + item_t::addr_t'(form * E_WRITE_CMO_STRIDE_C));
      this.write_cmo_seq.set_size(SIZE_C);
      this.write_cmo_seq.set_allow_retry(1'b0);
      this.write_cmo_seq.set_get_response(1'b1);
      this.write_cmo_seq.set_verbose(1'b0);
      this.write_cmo_seq.start(super.tb_env.rni_agent.sequencer);

      wr_rsp = this.write_cmo_seq.get_responses();
      if (wr_rsp.size() != 1) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] form %0d returned %0d responses, expected 1",
          super.tc_name, form, wr_rsp.size()))
      end

      // Keep the payload for the readback below: the sequence randomizes it, so
      // the only record of what this form wrote is the request itself. The byte
      // enables come with it because the three Ptl forms only land the enabled
      // lanes -- comparing whole beats there would fail on bytes the write was
      // never asked to write.
      written[form] = new[wr_rsp[0].data.size()];
      foreach (wr_rsp[0].data[beat]) begin
        written[form][beat] = wr_rsp[0].data[beat];
      end

      written_be[form] = new[wr_rsp[0].be.size()];
      foreach (wr_rsp[0].be[beat]) begin
        written_be[form][beat] = wr_rsp[0].be[beat];
      end

      super.wait_clocks(SETTLE_C);

      // ---- REQ: the opcode that actually reached the wire -------------------
      if (!super.tb_env.rni_req_fifo.try_get(req_item)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] form %0d produced no REQ flit", super.tc_name, form))
      end

      if (req_item.opcode !=
          this.expected_opcode(form_partial[form], form_cmo[form])) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] form %0d REQ opcode 0x%0h, expected 0x%0h",
          super.tc_name, form, req_item.opcode,
          this.expected_opcode(form_partial[form], form_cmo[form])))
      end

      if (super.tb_env.rni_req_fifo.try_get(stray_item)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] form %0d produced more than one REQ flit",
          super.tc_name, form))
      end

      // ---- DAT: the write half still carries its data burst -----------------
      dat_beats_seen = 0;
      while (super.tb_env.rni_dat_fifo.try_get(dat_item)) begin
        dat_beats_seen += dat_item.data.size();
      end

      if (dat_beats_seen != expected_beats) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] form %0d wrote %0d DAT beats, expected %0d",
          super.tc_name, form, dat_beats_seen, expected_beats))
      end

      // ---- RSP: the CMO half, and where it sits in the response order -------
      rsp_index        = 0;
      write_comp_index = -1;
      comp_cmo_index   = -1;
      persist_index    = -1;
      comp_ack_index   = -1;

      while (super.tb_env.rni_rsp_fifo.try_get(rsp_item)) begin

        if (rsp_item.rsp_opcode == VIP_CHI_RSP_PERSIST_C) begin
          if (rsp_item.txn_id != '0) begin
            `uvm_fatal(get_name(), $sformatf(
              "FATAL [%s] form %0d Persist TxnID 0x%0h was not zero",
              super.tc_name, form, rsp_item.txn_id))
          end
        end
        else if (rsp_item.txn_id != req_item.txn_id) begin
          `uvm_fatal(get_name(), $sformatf(
            "FATAL [%s] form %0d RSP TxnID 0x%0h did not match the request 0x%0h",
            super.tc_name, form, rsp_item.txn_id, req_item.txn_id))
        end

        case (VIP_CHI_MAX_RSP_OPCODE_WIDTH_C'(rsp_item.rsp_opcode))
          VIP_CHI_RSP_DBID_RESP_C: begin
            // Buffer grant only; the completion is one of the two below.
          end
          VIP_CHI_RSP_COMP_C,
          VIP_CHI_RSP_COMP_DBID_RESP_C: begin
            write_comp_index = rsp_index;
          end
          VIP_CHI_RSP_COMP_CMO_C: begin
            comp_cmo_index = rsp_index;
          end
          VIP_CHI_RSP_PERSIST_C: begin
            persist_index = rsp_index;
          end
          // The RN-I's own TX response. The monitor publishes both directions of
          // the RSP channel into this fifo, so its position here is the order the
          // two directions actually appeared on the link.
          VIP_CHI_RSP_COMP_ACK_C: begin
            comp_ack_index = rsp_index;
          end
          default: begin
            `uvm_fatal(get_name(), $sformatf(
              "FATAL [%s] form %0d unexpected RSP opcode 0x%0h",
              super.tc_name, form, rsp_item.rsp_opcode))
          end
        endcase

        rsp_index++;
      end

      if (write_comp_index < 0) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] form %0d drew no write completion", super.tc_name, form))
      end

      // The whole point of the family: the CMO half has its own completion.
      if (comp_cmo_index < 0) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] form %0d drew no CompCMO -- the CMO half was never completed",
          super.tc_name, form))
      end

      if (comp_cmo_index < write_comp_index) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] form %0d sent CompCMO (RSP %0d) before the write completion (RSP %0d)",
          super.tc_name, form, comp_cmo_index, write_comp_index))
      end

      if (this.write_cmo_seq.is_persist()) begin

        if (persist_index < 0) begin
          `uvm_fatal(get_name(), $sformatf(
            "FATAL [%s] form %0d is persistent but drew no Persist",
            super.tc_name, form))
        end

        if (persist_index < comp_cmo_index) begin
          `uvm_fatal(get_name(), $sformatf(
            "FATAL [%s] form %0d sent Persist (RSP %0d) before CompCMO (RSP %0d)",
            super.tc_name, form, persist_index, comp_cmo_index))
        end
      end
      else if (persist_index >= 0) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] form %0d is not persistent but drew a Persist",
          super.tc_name, form))
      end

      // ---- CompAck: sent when asked for, and never before the completion -----
      //
      // The spec states one bound and only one: with ExpCompAck set, the CompAck
      // must be sent AFTER Comp / DBIDResp / DBIDRespOrd / CompDBIDResp. Nothing
      // caps how late it may be, so where it sits relative to CompCMO and
      // Persist is the requester's choice and is deliberately not asserted --
      // pinning it would fail a legal implementation that acked earlier.
      if (form_ack[form]) begin

        if (comp_ack_index < 0) begin
          `uvm_fatal(get_name(), $sformatf(
            "FATAL [%s] form %0d set ExpCompAck but never sent a CompAck",
            super.tc_name, form))
        end

        if (comp_ack_index < write_comp_index) begin
          `uvm_fatal(get_name(), $sformatf(
            "FATAL [%s] form %0d sent CompAck (RSP %0d) before the write completion (RSP %0d)",
            super.tc_name, form, comp_ack_index, write_comp_index))
        end
      end
      else if (comp_ack_index >= 0) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] form %0d left ExpCompAck clear but sent a CompAck (RSP %0d)",
          super.tc_name, form, comp_ack_index))
      end
    end

    // -------------------------------------------------------------------------
    // And the writes actually landed. A completer that answered every response
    // correctly and dropped the data would pass everything above.
    // -------------------------------------------------------------------------
    super.rni_rd_seq.reset();
    super.rni_rd_seq.set_requests(FORMS_C);
    super.rni_rd_seq.set_initial_addr(E_WRITE_CMO_ADDR_C);
    super.rni_rd_seq.set_addr_stride(E_WRITE_CMO_STRIDE_C);
    super.rni_rd_seq.set_size(SIZE_C);
    super.rni_rd_seq.set_allow_retry(1'b0);
    super.rni_rd_seq.set_get_response(1'b1);
    super.rni_rd_seq.set_verbose(1'b0);
    super.rni_rd_seq.start(super.tb_env.rni_agent.sequencer);

    rd_rsp = super.rni_rd_seq.get_responses();
    if (rd_rsp.size() != FORMS_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] readback returned %0d responses, expected %0d",
        super.tc_name, rd_rsp.size(), FORMS_C))
    end

    foreach (rd_rsp[form]) begin

      if (rd_rsp[form].data.size() != written[form].size()) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] form %0d read back %0d beats, wrote %0d",
          super.tc_name, form, rd_rsp[form].data.size(), written[form].size()))
      end

      // Byte-wise, gated on the byte enables: a Ptl form leaves the disabled
      // lanes as whatever the backing memory already held, so only the bytes the
      // write actually claimed are evidence of anything.
      foreach (written[form][beat]) begin
        for (int byte_idx = 0; byte_idx < CHI_E_WIDE_CFG_C.DATA_BYTES_P; byte_idx++) begin

          if (!written_be[form][beat][byte_idx]) begin
            continue;
          end

          if (rd_rsp[form].data[beat][8*byte_idx +: 8] !==
              written[form][beat][8*byte_idx +: 8]) begin
            `uvm_fatal(get_name(), $sformatf(
              "FATAL [%s] form %0d beat %0d byte %0d read back 0x%02h, wrote 0x%02h",
              super.tc_name, form, beat, byte_idx,
              rd_rsp[form].data[beat][8*byte_idx +: 8],
              written[form][beat][8*byte_idx +: 8]))
          end
        end
      end
    end

    super.wait_clocks(SETTLE_C);
    super.drain_observation_fifos();

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] All %0d combined Write+CMO forms completed with CompCMO, both persistent forms drew a Persist after it, the 3 ExpCompAck forms acked after the write completion, and every write read back",
      super.tc_name, FORMS_C), UVM_LOW)

    phase.drop_objection(this);
  endtask
endclass
