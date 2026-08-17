// Config self-validation.
//
// is_valid() exists so an inconsistent configuration is reported once, at build
// time, instead of surfacing later as a hang or a silently-ignored knob. This
// test drives it directly with silent=1 (verdict only, no reports), one case
// per rule, so the expected failures do not pollute the test's own error count.
//
// Each case starts from a known-good config, breaks exactly one thing, and
// asserts is_valid() flips to 0 - so a rule that stops working is caught, and so
// is a rule that starts rejecting a legal config.

class tc_chi_cfg_invalid extends chi_base_test;

  `uvm_component_utils(tc_chi_cfg_invalid)

  int rejected = 0;
  int accepted = 0;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Exercise every rule from both sides.
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    vip_chi_cfg_agent c;

    phase.raise_objection(this);

    // A freshly-constructed config must be valid, or every case below is
    // meaningless.
    c = vip_chi_cfg_agent::type_id::create("baseline");
    if (!c.is_valid(.silent(1'b1))) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] A default-constructed vip_chi_cfg_agent is not valid",
        super.tc_name))
    end

    // ---- Rules that must REJECT --------------------------------------------
    c = this.fresh(); c.max_outstanding_read = 0;
    this.expect_invalid(c, "max_outstanding_read below 1");

    c = this.fresh(); c.max_outstanding_write = -1;
    this.expect_invalid(c, "max_outstanding_write below 1");

    c = this.fresh(); c.max_pcrd_budget = -1;
    this.expect_invalid(c, "negative P-credit budget");

    c = this.fresh(); c.multi_outstanding_write = 1'b1;
    this.expect_invalid(c, "multi_outstanding_write without multi_outstanding");

    c = this.fresh(); c.multi_outstanding_mixed = 1'b1;
    this.expect_invalid(c, "multi_outstanding_mixed without multi_outstanding");

    c = this.fresh(); c.snf_reorder_ordered_service = 1'b1;
    this.expect_invalid(c, "snf_reorder_ordered_service without multi_outstanding");

    c = this.fresh(); c.dat_interleave_depth = 0;
    this.expect_invalid(c, "dat_interleave_depth of 0");

    c = this.fresh(); c.dat_interleave_depth = 2;
    this.expect_invalid(c, "dat_interleave_depth above 1 without multi_outstanding");

    c = this.fresh();
    c.req_valid_delay_enabled       = 1'b1;
    c.req_valid_delay_gauss_enabled = 1'b1;
    c.req_valid_delay_stddev        = 0.0;
    this.expect_invalid(c, "gaussian delay shaping with a zero spread");

    c = this.fresh();
    c.rsp_valid_delay_gauss_enabled = 1'b1;
    this.expect_invalid(c, "gaussian shaping on a channel whose delay is off");

    c = this.fresh(); c.initial_req_credits = 65;
    this.expect_invalid(c, "initial REQ credits above the send-credit cap");

    c = this.fresh(); c.initial_dat_credits = 65;
    this.expect_invalid(c, "initial DAT credits above the send-credit cap");

    c = this.fresh(); c.initial_snp_credits = 65;
    this.expect_invalid(c, "initial SNP credits above the send-credit cap");

    c = this.fresh(); c.force_retry_count = -1;
    this.expect_invalid(c, "negative force_retry_count");

    c = this.fresh(); c.compack_timeout_cycles = -1;
    this.expect_invalid(c, "negative CompAck timeout");

    c = this.fresh();
    c.decerr_ranges = new[1];
    c.decerr_ranges[0].base  = 'h2000;
    c.decerr_ranges[0].limit = 'h1000;
    this.expect_invalid(c, "inverted DECERR range");

    c = this.fresh();
    c.derr_ranges = new[1];
    c.derr_ranges[0].base  = 'h2000;
    c.derr_ranges[0].limit = 'h1000;
    this.expect_invalid(c, "inverted DERR range");

    c = this.fresh();
    c.decerr_ranges = new[1];
    c.decerr_ranges[0].base  = 'h1000;
    c.decerr_ranges[0].limit = 'h2000;
    c.derr_ranges = new[1];
    c.derr_ranges[0].base  = 'h1800;
    c.derr_ranges[0].limit = 'h2800;
    this.expect_invalid(c, "DECERR range overlapping a DERR range");

    c = this.fresh(); c.rnf_cache_max_lines = -1;
    this.expect_invalid(c, "negative RN-F cache bound");

    c = this.fresh(); c.req_valid_delay_min = 99;
    this.expect_invalid(c, "inverted REQ valid-delay window");

    c = this.fresh(); c.link_act_delay_min = -1;
    this.expect_invalid(c, "negative link-activation delay");

    // ---- Rules that only WARN must not flip the verdict --------------------
    c = this.fresh(); c.rnf_cache_max_lines = 1;
    this.expect_valid(c, "single-line RN-F cache (no dirty writeback modeled)");

    c = this.fresh(); c.hnf_suppress_snoops = 1'b1;
    this.expect_valid(c, "a negative-control knob set on purpose");

    c = this.fresh();
    c.hnf_downstream_en    = 1'b1;
    c.hnf_suppress_snoops  = 1'b1;
    this.expect_valid(c, "two-level hierarchy with snoops suppressed");

    // ---- Legal configurations must stay legal ------------------------------
    c = this.fresh();
    c.multi_outstanding       = 1'b1;
    c.multi_outstanding_mixed = 1'b1;
    this.expect_valid(c, "the mixed overlap loop with its master enable");

    c = this.fresh();
    c.multi_outstanding             = 1'b1;
    c.snf_reorder_ordered_service   = 1'b1;
    this.expect_valid(c, "the ordered-service reorder knob with its master enable");

    c = this.fresh();
    c.multi_outstanding      = 1'b1;
    c.dat_interleave_depth   = 4;
    this.expect_valid(c, "DAT beat interleaving with its master enable");

    c = this.fresh();
    c.dat_valid_delay_enabled       = 1'b1;
    c.dat_valid_delay_gauss_enabled = 1'b1;
    this.expect_valid(c, "gaussian delay shaping with its channel delay enabled");

    c = this.fresh();
    c.decerr_ranges = new[1];
    c.decerr_ranges[0].base  = 'h1000;
    c.decerr_ranges[0].limit = 'h2000;
    c.derr_ranges = new[1];
    c.derr_ranges[0].base  = 'h3000;
    c.derr_ranges[0].limit = 'h4000;
    this.expect_valid(c, "disjoint DECERR and DERR ranges");

    c = this.fresh(); c.is_active = UVM_PASSIVE;
    this.expect_valid(c, "a passive agent");

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] %0d rejection rules and %0d accept/warn-only rules verified",
      super.tc_name, rejected, accepted), UVM_LOW)

    phase.drop_objection(this);
  endtask

  // ---------------------------------------------------------------------------
  // A known-good starting point for every case.
  // ---------------------------------------------------------------------------
  function vip_chi_cfg_agent fresh();

    return vip_chi_cfg_agent::type_id::create("case");
  endfunction

  // ---------------------------------------------------------------------------
  // The rule under test must reject this config.
  // ---------------------------------------------------------------------------
  function void expect_invalid(input vip_chi_cfg_agent c, input string what);

    if (c.is_valid(.silent(1'b1))) begin
      `uvm_error(get_name(), $sformatf(
        "ERROR [%s] is_valid() accepted an invalid config: %s",
        super.tc_name, what))
    end
    else begin
      rejected++;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // The rule under test must NOT reject this config (legal, or warn-only).
  // ---------------------------------------------------------------------------
  function void expect_valid(input vip_chi_cfg_agent c, input string what);

    if (!c.is_valid(.silent(1'b1))) begin
      `uvm_error(get_name(), $sformatf(
        "ERROR [%s] is_valid() rejected a legal config: %s",
        super.tc_name, what))
    end
    else begin
      accepted++;
    end
  endfunction

endclass
