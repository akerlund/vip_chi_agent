// ===========================================================================
// vip_chi_coh_write_unique_base_test
//
// WriteUnique is a non-allocating coherent write. RN-F0 first holds the line
// Shared; RN-F1 then WriteUniques a fresh payload. The home must snoop-invalidate
// RN-F0 before committing (its Shared copy would otherwise be stale), commit the
// NonCopyBackWrData to memory, and leave RN-F1 Invalid (no ownership):
//   RN-F0 ReadShared L    -> SC (original data)
//   RN-F1 WriteUnique L   -> HN-F SnpCleanInvalid(RN-F0) -> RN-F0 I
//                            -> CompDBIDResp -> RN-F1 NonCopyBackWrData -> memory
//   RN-F0 ReadShared L    -> must return the written data (not the original)
// Asserts: RN-F0 invalidated by the WriteUnique snoop, RN-F1 allocates nothing
// (stays I), the read-back equals the written payload (write landed + is coherently
// visible) and differs from the original image (non-vacuous), Checker D silent.
//
// Used by:
//   tc_chi_coh_e_write_unique  (wide CHI-E)
//   tc_chi_coh_d_write_unique    (CHI-D)
// ===========================================================================
class vip_chi_coh_write_unique_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends vip_chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(vip_chi_coh_write_unique_base_test #(CFG_P, TYPES_T))

  vip_chi_writeunique_seq #(CFG_P) hrnf1_wu_seq;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void start_of_simulation_phase(input uvm_phase phase);
    super.start_of_simulation_phase(phase);
    this.hrnf1_wu_seq = vip_chi_writeunique_seq #(CFG_P)::type_id::create("hrnf1_wu_seq");
  endfunction


  task run_phase(input uvm_phase phase);

    item_t rds_rsp[$];
    item_t wu_rsp[$];
    item_t rd_rsp[$];
    bit    differs_from_original;

    phase.raise_objection(this);

    super.wait_reset_settle();

    // 1) RN-F0 takes the line Shared (original memory image).
    this.cfg_read_seq(super.hrnf0_rdshared_seq);
    super.hrnf0_rdshared_seq.start(super.tb_env.hrnf0_agent.sequencer);
    rds_rsp = super.hrnf0_rdshared_seq.get_responses();

    // 2) RN-F1 WriteUniques a fresh payload; the home must invalidate RN-F0.
    this.cfg_read_seq(this.hrnf1_wu_seq);
    this.hrnf1_wu_seq.start(super.tb_env.hrnf1_agent.sequencer);
    wu_rsp = this.hrnf1_wu_seq.get_responses();

    super.wait_clocks(8);

    if ((rds_rsp.size() != 1) || (wu_rsp.size() != 1)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] expected 1+1 responses, got %0d/%0d",
        super.tc_name, rds_rsp.size(), wu_rsp.size()))
    end

    // RN-F0's Shared copy must have been snoop-invalidated by the WriteUnique.
    if (super.tb_env.hrnf0_agent.rnf_driver.get_cache_state(item_t::addr_t'(WRITE_READ_ADDR_C)) != VIP_CHI_RESP_STATE_I_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 not invalidated by the WriteUnique snoop", super.tc_name))
    end
    // The non-allocating writer holds nothing.
    if (super.tb_env.hrnf1_agent.rnf_driver.get_cache_state(item_t::addr_t'(WRITE_READ_ADDR_C)) != VIP_CHI_RESP_STATE_I_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F1 cache not Invalid after WriteUnique (non-allocating)", super.tc_name))
    end
    if (super.tb_env.hrnf0_snp_fifo.used() == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 never observed the invalidating WriteUnique snoop", super.tc_name))
    end

    // 3) Read the line back -- it must carry the written data.
    this.cfg_read_seq(super.hrnf0_rdshared_seq);
    super.hrnf0_rdshared_seq.start(super.tb_env.hrnf0_agent.sequencer);
    rd_rsp = super.hrnf0_rdshared_seq.get_responses();

    if (rd_rsp.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] expected 1 read-back response, got %0d", super.tc_name, rd_rsp.size()))
    end

    if ((wu_rsp[0].data.size() != rd_rsp[0].data.size()) ||
        (rds_rsp[0].data.size() != rd_rsp[0].data.size())) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] beat-count mismatch: rds %0d wu %0d rd %0d", super.tc_name,
        rds_rsp[0].data.size(), wu_rsp[0].data.size(), rd_rsp[0].data.size()))
    end

    // Read-back must equal the WriteUnique payload beat-for-beat.
    foreach (rd_rsp[0].data[i]) begin
      if (rd_rsp[0].data[i] !== wu_rsp[0].data[i]) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] beat %0d read-back 0x%0h != written 0x%0h",
          super.tc_name, i, rd_rsp[0].data[i], wu_rsp[0].data[i]))
      end
    end

    // Non-vacuity: the written data must differ from the original image.
    differs_from_original = 1'b0;
    foreach (rd_rsp[0].data[i]) begin
      if (rd_rsp[0].data[i] !== rds_rsp[0].data[i]) begin
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
        "FATAL [%s] %0d coherency violations on a legal WriteUnique",
        super.tc_name, super.tb_env.coh_checker.get_multi_owner_count()))
    end

    phase.drop_objection(this);
  endtask
endclass
