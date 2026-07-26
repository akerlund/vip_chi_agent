// ===========================================================================
// chi_coh_make_unique_base_test
//
// MakeUnique is a no-data unique acquire: the requester takes write permission
// for a line it intends to overwrite entirely, WITHOUT any data transfer.
//
// Scenario: RN-F0 and RN-F1 both take the line Shared. RN-F1 then issues
// MakeUnique. The home snoops the other holder (SnpMakeInvalid, no data
// forwarded), grants RN-F1 Unique-Dirty with an RSP-only Comp (no data beats),
// and leaves RN-F0 Invalid.
//
// Asserts: exactly one data-less Comp granting Unique-Dirty; a snoop fired;
// RN-F0 (cache + directory port 0) returns to Invalid; RN-F1 (cache + directory
// port 1) holds Unique-Dirty; and Checker D stays silent (a single-writer
// acquire never violates the single-writer invariant).
//
// Used by:
//   tc_chi_coh_d_make_unique    (CHI-D)
//   tc_chi_coh_e_make_unique  (wide CHI-E)
// ===========================================================================
class chi_coh_make_unique_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(chi_coh_make_unique_base_test #(CFG_P, TYPES_T))

  vip_chi_makeunique_seq #(CFG_P) hrnf1_mu_seq;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void start_of_simulation_phase(input uvm_phase phase);
    super.start_of_simulation_phase(phase);
    this.hrnf1_mu_seq = vip_chi_makeunique_seq #(CFG_P)::type_id::create("hrnf1_mu_seq");
  endfunction

  task run_phase(input uvm_phase phase);

    item_t mu_rsp[$];
    item_t rd_rsp[$];
    int    snoops_before;

    phase.raise_objection(this);

    super.wait_reset_settle();

    // Both RN-Fs take the line Shared.
    this.cfg_read_seq(super.hrnf0_rdshared_seq);
    super.hrnf0_rdshared_seq.start(super.tb_env.hrnf0_agent.sequencer);
    void'(super.hrnf0_rdshared_seq.get_responses());

    this.cfg_read_seq(super.hrnf1_rdshared_seq);
    super.hrnf1_rdshared_seq.start(super.tb_env.hrnf1_agent.sequencer);
    void'(super.hrnf1_rdshared_seq.get_responses());

    snoops_before = super.tb_env.coh_checker.get_snoop_count();

    // RN-F1 acquires the line Unique via MakeUnique (no data transfer).
    this.cfg_read_seq(this.hrnf1_mu_seq);
    this.hrnf1_mu_seq.start(super.tb_env.hrnf1_agent.sequencer);
    mu_rsp = this.hrnf1_mu_seq.get_responses();

    super.wait_clocks(8);

    if (mu_rsp.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] MakeUnique expected 1 completion, got %0d", super.tc_name, mu_rsp.size()))
    end
    if (mu_rsp[0].rsp_opcode != item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] MakeUnique completion opcode 0x%0h was not Comp",
        super.tc_name, mu_rsp[0].rsp_opcode))
    end
    if (mu_rsp[0].data.size() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] MakeUnique returned %0d data beats, expected 0 (RSP-only Comp)",
        super.tc_name, mu_rsp[0].data.size()))
    end
    if (mu_rsp[0].rsp_resp != VIP_CHI_RESP_STATE_UP_PD_DIRTY_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] MakeUnique granted resp 0x%0h, expected Unique-Dirty",
        super.tc_name, mu_rsp[0].rsp_resp))
    end
    if (super.tb_env.coh_checker.get_snoop_count() <= snoops_before) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] MakeUnique originated no snoop (count %0d -> %0d)",
        super.tc_name, snoops_before, super.tb_env.coh_checker.get_snoop_count()))
    end

    // RN-F0 invalidated (cache + directory port 0).
    if (super.tb_env.hrnf0_agent.rnf_driver.get_cache_state(item_t::addr_t'(WRITE_READ_ADDR_C)) != VIP_CHI_RESP_STATE_I_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 cache not Invalid after MakeUnique", super.tc_name))
    end
    if (super.tb_env.hnf_agent.hnf_driver.get_directory_port_state(item_t::addr_t'(WRITE_READ_ADDR_C), 0) != VIP_CHI_RESP_STATE_I_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] directory port0 not Invalid after MakeUnique", super.tc_name))
    end

    // RN-F1 holds the line Unique-Dirty (cache + directory port 1).
    if (super.tb_env.hrnf1_agent.rnf_driver.get_cache_state(item_t::addr_t'(WRITE_READ_ADDR_C)) != VIP_CHI_RESP_STATE_UP_PD_DIRTY_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F1 cache not Unique-Dirty after MakeUnique", super.tc_name))
    end
    if (super.tb_env.hnf_agent.hnf_driver.get_directory_port_state(item_t::addr_t'(WRITE_READ_ADDR_C), 1) != VIP_CHI_RESP_STATE_UP_PD_DIRTY_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] directory port1 not Unique-Dirty after MakeUnique", super.tc_name))
    end

    // F2: read the freshly-made line back. RN-F1 holds it Unique-Dirty with a
    // materialized (all-zero) image and never received original data; the home
    // must snoop RN-F1, take its forwarded beats (NOT a no-data response that
    // would serve stale home memory, and no DCT wedge), and return defined data.
    // A pre-F2 model (empty cache_data) would forward no data -> RN-F0 would read
    // the home's stale synthesized pattern (non-zero) and this assert would fire.
    this.cfg_read_seq(super.hrnf0_rdshared_seq);
    super.hrnf0_rdshared_seq.start(super.tb_env.hrnf0_agent.sequencer);
    rd_rsp = super.hrnf0_rdshared_seq.get_responses();
    if (rd_rsp.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] read-after-MakeUnique expected 1 response, got %0d",
        super.tc_name, rd_rsp.size()))
    end
    foreach (rd_rsp[0].data[i]) begin
      if (rd_rsp[0].data[i] !== '0) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] read-after-MakeUnique beat %0d = 0x%0h, expected the materialized all-zero image (stale/undefined data forwarded)",
          super.tc_name, i, rd_rsp[0].data[i]))
      end
    end

    if (super.tb_env.coh_checker.get_multi_owner_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %0d coherency violations on legal MakeUnique",
        super.tc_name, super.tb_env.coh_checker.get_multi_owner_count()))
    end

    phase.drop_objection(this);
  endtask
endclass
