// ===========================================================================
// vip_chi_coh_read_once_base_test
//
// ReadOnce is a non-allocating snapshot read: the requester obtains a current
// copy of the data but caches nothing (ends Invalid) and gains no ownership.
// RN-F0 acquires a line Unique and dirties it (make_line_dirty -> UD); RN-F1 then
// ReadOnces it. The home must snoop RN-F0 with SnpOnce (state-preserving) to
// fetch the current dirty value, then return CompData(I):
//   RN-F0 ReadUnique L         -> UC, caches beats
//   make_line_dirty(L, PAT)    -> UD, held beats = orig ^ PAT
//   RN-F1 ReadOnce L           -> HN-F SnpOnce(RN-F0) -> RN-F0 SnpRespData(orig^PAT)
//                                 (RN-F0 STAYS UD, keeps its data) -> HN-F CompData(I)
// Asserts: RN-F1's CompData carries the CURRENT dirty data (orig ^ PAT), the grant
// state is Invalid (no ownership), RN-F1 caches nothing (stays I), RN-F0's state is
// PRESERVED (UD -- SnpOnce does not downgrade), a snoop was observed, and Checker D
// stays silent.
//
// Used by:
//   tc_chi_coh_e_read_once  (wide CHI-E)
//   tc_chi_coh_d_read_once    (CHI-D)
// ===========================================================================
class vip_chi_coh_read_once_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends vip_chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(vip_chi_coh_read_once_base_test #(CFG_P, TYPES_T))

  vip_chi_readonce_seq #(CFG_P) hrnf1_ro_seq;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void start_of_simulation_phase(input uvm_phase phase);
    super.start_of_simulation_phase(phase);
    this.hrnf1_ro_seq = vip_chi_readonce_seq #(CFG_P)::type_id::create("hrnf1_ro_seq");
  endfunction


  task run_phase(input uvm_phase phase);

    item_t         unique_rsp[$];
    item_t         once_rsp[$];
    vip_chi_resp_t rnf0_state;
    vip_chi_resp_t rnf1_state;
    item_t::data_t dirty_pattern;

    phase.raise_objection(this);

    super.wait_reset_settle();

    dirty_pattern = {($bits(dirty_pattern) / 8){8'hC3}};

    // 1) RN-F0 acquires the line Unique and caches the granted beats.
    this.cfg_read_seq(super.hrnf0_rdunique_seq);
    super.hrnf0_rdunique_seq.start(super.tb_env.hrnf0_agent.sequencer);
    unique_rsp = super.hrnf0_rdunique_seq.get_responses();

    // 2) Model a local store: dirty RN-F0's cached line.
    super.tb_env.hrnf0_agent.rnf_driver.make_line_dirty(item_t::addr_t'(WRITE_READ_ADDR_C), dirty_pattern);

    // 3) RN-F1 ReadOnces the line: a snapshot that must forward RN-F0's current
    //    (dirty) data without changing RN-F0's state or allocating at RN-F1.
    this.cfg_read_seq(this.hrnf1_ro_seq);
    this.hrnf1_ro_seq.start(super.tb_env.hrnf1_agent.sequencer);
    once_rsp = this.hrnf1_ro_seq.get_responses();

    if ((unique_rsp.size() != 1) || (once_rsp.size() != 1)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] expected 1+1 responses, got %0d/%0d",
        super.tc_name, unique_rsp.size(), once_rsp.size()))
    end

    if (once_rsp[0].rsp_resp != VIP_CHI_RESP_STATE_I_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] ReadOnce granted 0x%0h, expected I (no ownership)",
        super.tc_name, once_rsp[0].rsp_resp))
    end

    if (once_rsp[0].data.size() == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] ReadOnce completed with no data beats", super.tc_name))
    end

    // The returned data must be RN-F0's CURRENT (dirtied) copy, orig ^ PAT.
    if (unique_rsp[0].data.size() != once_rsp[0].data.size()) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] beat-count mismatch: unique %0d vs once %0d",
        super.tc_name, unique_rsp[0].data.size(), once_rsp[0].data.size()))
    end
    foreach (once_rsp[0].data[i]) begin
      if (once_rsp[0].data[i] !== (unique_rsp[0].data[i] ^ dirty_pattern)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] beat %0d ReadOnce returned 0x%0h, expected current 0x%0h",
          super.tc_name, i, once_rsp[0].data[i],
          (unique_rsp[0].data[i] ^ dirty_pattern)))
      end
    end

    super.wait_clocks(8);

    rnf0_state = super.tb_env.hrnf0_agent.rnf_driver.get_cache_state(item_t::addr_t'(WRITE_READ_ADDR_C));
    rnf1_state = super.tb_env.hrnf1_agent.rnf_driver.get_cache_state(item_t::addr_t'(WRITE_READ_ADDR_C));

    // RN-F0 keeps its dirty copy (SnpOnce is a snapshot, not a downgrade).
    if (rnf0_state != VIP_CHI_RESP_STATE_UP_PD_DIRTY_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 cache 0x%0h after SnpOnce, expected UD (preserved)",
        super.tc_name, rnf0_state))
    end

    // RN-F1 allocated nothing.
    if (rnf1_state != VIP_CHI_RESP_STATE_I_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F1 cache 0x%0h after ReadOnce, expected I (non-allocating)",
        super.tc_name, rnf1_state))
    end

    // Directory must not record RN-F1 as a holder.
    if (super.tb_env.hnf_agent.hnf_driver.get_directory_port_state(item_t::addr_t'(WRITE_READ_ADDR_C), 1) != VIP_CHI_RESP_STATE_I_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] directory port1 not Invalid after ReadOnce (must not allocate)",
        super.tc_name))
    end

    if (super.tb_env.hrnf0_snp_fifo.used() == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 never observed the SnpOnce", super.tc_name))
    end

    if (super.tb_env.coh_checker.get_multi_owner_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %0d coherency violations on a legal ReadOnce",
        super.tc_name, super.tb_env.coh_checker.get_multi_owner_count()))
    end

    phase.drop_objection(this);
  endtask
endclass
