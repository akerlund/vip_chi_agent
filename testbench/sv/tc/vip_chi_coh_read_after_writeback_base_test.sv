// ===========================================================================
// vip_chi_coh_read_after_writeback_base_test
//
// End-to-end coherent writeback data integrity. RN-F0 acquires a line Unique
// (its CompData is the pre-writeback memory image), then WriteBackFulls a new
// (random) payload into the home. RN-F1 then ReadShareds the line and must get
// the WRITTEN-BACK data, proving the home committed the CopyBackWrData to memory
// and a later coherent read returns it:
//   RN-F0 ReadUnique L        -> rdu data = original memory image
//   RN-F0 WriteBackFull L     -> home commits wb data to memory
//   RN-F1 ReadShared L        -> rd data must equal wb data (not the original)
// The read-back must equal the writeback payload (writeback landed + is
// readable) and differ from the original image (non-vacuous: a no-op writeback
// would return the original and fail).
//
// Used by:
//   tc_chi_coh_e_read_after_writeback  (wide CHI-E)
//   tc_chi_coh_d_read_after_writeback    (CHI-D)
// ===========================================================================
class vip_chi_coh_read_after_writeback_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends vip_chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(vip_chi_coh_read_after_writeback_base_test #(CFG_P, TYPES_T))

  vip_chi_writeback_seq #(CFG_P) hrnf0_wb_seq;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void start_of_simulation_phase(input uvm_phase phase);
    super.start_of_simulation_phase(phase);
    this.hrnf0_wb_seq = vip_chi_writeback_seq #(CFG_P)::type_id::create("hrnf0_wb_seq");
  endfunction


  task run_phase(input uvm_phase phase);

    item_t rdu_rsp[$];
    item_t wb_rsp[$];
    item_t rd_rsp[$];
    bit    differs_from_original;

    phase.raise_objection(this);

    super.wait_reset_settle();

    // 1) RN-F0 acquires the line Unique (original memory image).
    this.cfg_read_seq(super.hrnf0_rdunique_seq);
    super.hrnf0_rdunique_seq.start(super.tb_env.hrnf0_agent.sequencer);
    rdu_rsp = super.hrnf0_rdunique_seq.get_responses();

    // 2) RN-F0 writes a fresh payload back to the home.
    this.cfg_read_seq(this.hrnf0_wb_seq);
    this.hrnf0_wb_seq.start(super.tb_env.hrnf0_agent.sequencer);
    wb_rsp = this.hrnf0_wb_seq.get_responses();

    // 3) RN-F1 reads the line Shared and must see the written-back data.
    this.cfg_read_seq(super.hrnf1_rdshared_seq);
    super.hrnf1_rdshared_seq.start(super.tb_env.hrnf1_agent.sequencer);
    rd_rsp = super.hrnf1_rdshared_seq.get_responses();

    if ((rdu_rsp.size() != 1) || (wb_rsp.size() != 1) || (rd_rsp.size() != 1)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] expected 1/1/1 responses, got %0d/%0d/%0d",
        super.tc_name, rdu_rsp.size(), wb_rsp.size(), rd_rsp.size()))
    end

    if ((wb_rsp[0].data.size() != rd_rsp[0].data.size()) ||
        (rdu_rsp[0].data.size() != rd_rsp[0].data.size())) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] beat-count mismatch: rdu %0d wb %0d rd %0d", super.tc_name,
        rdu_rsp[0].data.size(), wb_rsp[0].data.size(), rd_rsp[0].data.size()))
    end

    // Read-back must equal the writeback payload beat-for-beat.
    foreach (rd_rsp[0].data[i]) begin
      if (rd_rsp[0].data[i] !== wb_rsp[0].data[i]) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] beat %0d read-back 0x%0h != written 0x%0h",
          super.tc_name, i, rd_rsp[0].data[i], wb_rsp[0].data[i]))
      end
    end

    // Non-vacuity: the written data must differ from the original image, else a
    // no-op writeback (returning the original) would masquerade as a pass.
    differs_from_original = 1'b0;
    foreach (rd_rsp[0].data[i]) begin
      if (rd_rsp[0].data[i] !== rdu_rsp[0].data[i]) begin
        differs_from_original = 1'b1;
      end
    end
    if (!differs_from_original) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] written data equals the original image - check is vacuous",
        super.tc_name))
    end

    if (super.tb_env.coh_checker.get_multi_owner_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Checker D flagged %0d multi-owner violations",
        super.tc_name, super.tb_env.coh_checker.get_multi_owner_count()))
    end

    phase.drop_objection(this);
  endtask
endclass
