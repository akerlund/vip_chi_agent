// ===========================================================================
// vip_chi_coh_dirty_forward_base_test
//
// Dirty snoop forwarding (PassDirty). RN-F0 acquires a line Unique and then
// models a local store that dirties it (make_line_dirty XORs a pattern into the
// held beats, moving the line to UD). RN-F1 then ReadShareds the same line, so
// the home snoop-downgrades RN-F0 -- which, being dirty, answers with
// SnpRespData carrying its MODIFIED data instead of a no-data SnpResp:
//   RN-F0 ReadUnique L         -> UC, caches L's beats
//   make_line_dirty(L, PAT)    -> UD, held beats = orig ^ PAT
//   RN-F1 ReadShared L         -> HN-F SnpShared(RN-F0)
//                                -> RN-F0 SnpRespData(SC, orig^PAT) [dirty]
//                                -> HN-F merges orig^PAT into memory
//                                -> HN-F CompData(SC, orig^PAT) to RN-F1
// Asserts: RN-F1's CompData carries the dirtied data (orig ^ PAT, beat-wise,
// which differs from what memory held before), RN-F1 granted SC, RN-F0
// downgraded to SC, a snoop was observed, and Checker D stays silent (the
// single-writer invariant is never broken -- a legal dirty transfer).
//
// Used by:
//   tc_chi_coh_d_dirty_forward    (CHI-D)
//   tc_chi_coh_e_dirty_forward  (wide CHI-E)
// ===========================================================================
class vip_chi_coh_dirty_forward_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends vip_chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(vip_chi_coh_dirty_forward_base_test #(CFG_P, TYPES_T))

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction


  task run_phase(input uvm_phase phase);

    item_t         unique_rsp[$];
    item_t         shared_rsp[$];
    vip_chi_resp_t rnf0_state;
    vip_chi_resp_t rnf1_state;
    // Local-store pattern XORed into RN-F0's held line. $bits keeps it width-safe
    // without a class-scoped localparam of a parameterized-class-nested type
    // (which spins VCS codegen at CHI-E width).
    item_t::data_t dirty_pattern;

    phase.raise_objection(this);

    super.wait_reset_settle();

    dirty_pattern = {($bits(dirty_pattern) / 8){8'hA5}};

    // 1) RN-F0 acquires the line Unique and caches the granted beats.
    this.cfg_read_seq(super.hrnf0_rdunique_seq);
    super.hrnf0_rdunique_seq.start(super.tb_env.hrnf0_agent.sequencer);
    unique_rsp = super.hrnf0_rdunique_seq.get_responses();

    // 2) Model a local store: dirty RN-F0's cached line.
    super.tb_env.hrnf0_agent.rnf_driver.make_line_dirty(item_t::addr_t'(WRITE_READ_ADDR_C), dirty_pattern);

    // 3) RN-F1 reads Shared, forcing a downgrading snoop that must forward the
    //    dirty data through the home to RN-F1.
    this.cfg_read_seq(super.hrnf1_rdshared_seq);
    super.hrnf1_rdshared_seq.start(super.tb_env.hrnf1_agent.sequencer);
    shared_rsp = super.hrnf1_rdshared_seq.get_responses();

    if ((unique_rsp.size() != 1) || (shared_rsp.size() != 1)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] expected 1+1 responses, got %0d/%0d",
        super.tc_name, unique_rsp.size(), shared_rsp.size()))
    end

    if (shared_rsp[0].rsp_resp != VIP_CHI_RESP_STATE_SC_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] ReadShared granted 0x%0h, expected SC (0x%0h)",
        super.tc_name, shared_rsp[0].rsp_resp, VIP_CHI_RESP_STATE_SC_E))
    end

    // The forwarded data must be RN-F0's modified copy (orig ^ pattern), not the
    // stale value memory held before the snoop.
    if (unique_rsp[0].data.size() != shared_rsp[0].data.size()) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] beat-count mismatch: unique %0d vs shared %0d",
        super.tc_name, unique_rsp[0].data.size(), shared_rsp[0].data.size()))
    end

    foreach (shared_rsp[0].data[i]) begin
      if (shared_rsp[0].data[i] !== (unique_rsp[0].data[i] ^ dirty_pattern)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] beat %0d forwarded 0x%0h, expected dirtied 0x%0h",
          super.tc_name, i, shared_rsp[0].data[i],
          (unique_rsp[0].data[i] ^ dirty_pattern)))
      end
    end

    super.wait_clocks(8);

    rnf0_state = super.tb_env.hrnf0_agent.rnf_driver.get_cache_state(item_t::addr_t'(WRITE_READ_ADDR_C));
    rnf1_state = super.tb_env.hrnf1_agent.rnf_driver.get_cache_state(item_t::addr_t'(WRITE_READ_ADDR_C));

    if (rnf0_state != VIP_CHI_RESP_STATE_SC_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 cache 0x%0h after passing dirty data, expected SC",
        super.tc_name, rnf0_state))
    end

    if (rnf1_state != VIP_CHI_RESP_STATE_SC_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F1 cache 0x%0h, expected SC", super.tc_name, rnf1_state))
    end

    if (super.tb_env.hrnf0_snp_fifo.used() == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 never observed the downgrading snoop", super.tc_name))
    end

    if (super.tb_env.coh_checker.get_multi_owner_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Checker D flagged %0d multi-owner violations on a legal dirty transfer",
        super.tc_name, super.tb_env.coh_checker.get_multi_owner_count()))
    end

    phase.drop_objection(this);
  endtask
endclass
