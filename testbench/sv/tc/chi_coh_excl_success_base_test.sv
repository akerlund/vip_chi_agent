// ===========================================================================
// chi_coh_excl_success_base_test
//
// Exclusive LL/SC happy path on the coherent bench. RN-F0 performs an exclusive
// load (ReadClean+excl), which arms the home's per-(line,port) monitor, then --
// with NO intervening traffic to the line -- an exclusive store
// (CleanUnique+excl). The monitor is still valid, so the store WINS:
//   RN-F0 LL (ReadClean+excl) L  -> grant SC, monitor[L][0]=1, Comp/ExclOkay
//   RN-F0 SC (CleanUnique+excl) L -> monitor still set -> upgrade to UC,
//                                    consume monitor, Comp/ExclOkay
// Asserts: the LL completion carries ExclOkay, the SC completion carries
// ExclOkay, RN-F0's cache ends UC, the directory shows port0=UC, and Checker D
// is silent (a fully coherent, legal exclusive sequence).
//
// Used by:
//   tc_chi_coh_e_excl_success  (wide CHI-E)
//   tc_chi_coh_d_excl_success    (CHI-D)
// ===========================================================================
class chi_coh_excl_success_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(chi_coh_excl_success_base_test #(CFG_P, TYPES_T))

  vip_chi_excl_load_seq  #(CFG_P) hrnf0_ll_seq;
  vip_chi_excl_store_seq #(CFG_P) hrnf0_sc_seq;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void start_of_simulation_phase(input uvm_phase phase);
    super.start_of_simulation_phase(phase);
    this.hrnf0_ll_seq = vip_chi_excl_load_seq  #(CFG_P)::type_id::create("hrnf0_ll_seq");
    this.hrnf0_sc_seq = vip_chi_excl_store_seq #(CFG_P)::type_id::create("hrnf0_sc_seq");
  endfunction


  task run_phase(input uvm_phase phase);

    item_t         ll_rsp[$];
    item_t         sc_rsp[$];
    vip_chi_resp_t rnf0_state;

    phase.raise_objection(this);

    super.wait_reset_settle();

    // Exclusive load: fetch the line and arm the monitor.
    this.cfg_read_seq(this.hrnf0_ll_seq);
    this.hrnf0_ll_seq.start(super.tb_env.hrnf0_agent.sequencer);
    ll_rsp = this.hrnf0_ll_seq.get_responses();

    // Exclusive store: with no intervening traffic, the monitor is still valid.
    this.cfg_read_seq(this.hrnf0_sc_seq);
    this.hrnf0_sc_seq.start(super.tb_env.hrnf0_agent.sequencer);
    sc_rsp = this.hrnf0_sc_seq.get_responses();

    if ((ll_rsp.size() != 1) || (sc_rsp.size() != 1)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] expected 1+1 responses, got %0d/%0d",
        super.tc_name, ll_rsp.size(), sc_rsp.size()))
    end

    // The exclusive load must report ExclOkay -- the monitor was set.
    if (ll_rsp[0].rsp_resp_err != VIP_CHI_RESP_ERR_EXCLUSIVE_OKAY_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] LL completion resperr 0x%0h, expected ExclOkay (0x%0h)",
        super.tc_name, ll_rsp[0].rsp_resp_err, VIP_CHI_RESP_ERR_EXCLUSIVE_OKAY_E))
    end

    // The exclusive store must WIN (ExclOkay) -- no intervening conflict.
    if (sc_rsp[0].rsp_resp_err != VIP_CHI_RESP_ERR_EXCLUSIVE_OKAY_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] SC completion resperr 0x%0h, expected ExclOkay (0x%0h) -- store should have won",
        super.tc_name, sc_rsp[0].rsp_resp_err, VIP_CHI_RESP_ERR_EXCLUSIVE_OKAY_E))
    end

    super.wait_clocks(8);

    // RN-F0 upgraded its held line to Unique-Clean on the winning SC.
    rnf0_state = super.tb_env.hrnf0_agent.rnf_driver.get_cache_state(item_t::addr_t'(WRITE_READ_ADDR_C));
    if (rnf0_state != VIP_CHI_RESP_STATE_UC_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 cache 0x%0h after winning SC, expected UC (0x%0h)",
        super.tc_name, rnf0_state, VIP_CHI_RESP_STATE_UC_E))
    end

    // The home directory records port0 as the Unique owner.
    if (super.tb_env.hnf_agent.hnf_driver.get_directory_port_state(item_t::addr_t'(WRITE_READ_ADDR_C), 0) != VIP_CHI_RESP_STATE_UC_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] directory port0 not UC after the winning SC", super.tc_name))
    end

    // A legal exclusive sequence must not trip any coherency invariant.
    if (super.tb_env.coh_checker.get_multi_owner_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %0d coherency violations on a legal exclusive LL/SC",
        super.tc_name, super.tb_env.coh_checker.get_multi_owner_count()))
    end

    phase.drop_objection(this);
  endtask
endclass
