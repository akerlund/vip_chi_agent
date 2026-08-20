// ===========================================================================
// tc_chi_snp_flit_layout
//
// The SNP flit's field order was wrong in both ports for the life of the
// project, in three places at once, and nothing could see it. Both ports were
// wrong identically, so check_type_parity.py held them together through the
// defect; check_flit_layout.py can see it, but only when it is handed the
// specification PDFs, and without them it prints INCONCLUSIVE and verifies
// nothing -- which is how the standard gate runs.
//
// So this test asserts the layout from inside the regression, where no PDF is
// available: it sets one field at a time to all-ones and requires the ones to
// land at the bit offset the specification's field order implies. Offsets are
// accumulated from $bits() of each member rather than written down, so the test
// asserts the ORDER and not a set of hard-coded widths -- a field that changes
// width stays passing, a field that moves does not.
//
// Field order under test, LSB first, from IHI 0050 D Table 12-8 / E Table 13-8:
//   QoS, SrcID, TxnID, FwdNID, FwdTxnID, Opcode, Addr, NS, DoNotGoToSD,
//   RetToSrc, TraceTag, MPAM
//
// MPAM is the reason CHI_E_MPAM_CFG_C exists. It is the one field whose width is
// configuration-dependent, and no regression configuration enables it, so a
// layout test at MPAM_EN_P = 0 would leave the wide flit as unbuilt as it was
// when the field was missing altogether.
// ===========================================================================
class tc_chi_snp_flit_layout extends chi_base_test;

  `uvm_component_utils(tc_chi_snp_flit_layout)

  typedef chi_d_types_t::snp_flit_t                     d_snp_t;
  typedef chi_e_wide_types_t::snp_flit_t                e_snp_t;
  typedef vip_chi_types_e #(CHI_E_MPAM_CFG_C)::snp_flit_t e_mpam_snp_t;

  protected int unsigned fields_checked;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Require that a flit carrying all-ones in exactly one field has those ones at
  // [off +: width] and zeroes everywhere else. Taking the flit as a wide bit
  // vector keeps one task usable for all three flit types.
  // ---------------------------------------------------------------------------
  protected function void expect_field_at(
    input logic [1023 : 0] flit,
    input int unsigned     flit_bits,
    input int unsigned     off,
    input int unsigned     width,
    input string           issue_name,
    input string           field_name
  );

    logic [1023 : 0] want;

    want = '0;
    for (int unsigned b = 0; b < width; b++) begin
      want[off + b] = 1'b1;
    end

    // Compared as whole vectors rather than sliced to flit_bits: a variable
    // part-select is not legal here, and it is not needed -- the caller passes a
    // flit zero-extended into the wide vector, so any difference above flit_bits
    // would itself be a defect worth reporting.
    if (flit !== want) begin
      `uvm_error(get_name(), $sformatf(
        "ERROR [%s] %s SNP %s (flit %0d bits) is not at bits [%0d +: %0d]: flit=0x%0h want=0x%0h",
        super.tc_name, issue_name, field_name, flit_bits, off, width, flit, want))
    end else begin
      this.fields_checked++;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // CHI-D. Twelve fields, each set alone, offsets accumulated in spec order.
  // ---------------------------------------------------------------------------
  protected function void check_d_layout();

    d_snp_t      f;
    int unsigned off;
    int unsigned n;

    n   = $bits(f);
    off = 0;

    f = '0; f.qos         = '1; this.expect_field_at(f, n, off, $bits(f.qos),         "CHI-D", "QoS");         off += $bits(f.qos);
    f = '0; f.srcid       = '1; this.expect_field_at(f, n, off, $bits(f.srcid),       "CHI-D", "SrcID");       off += $bits(f.srcid);
    f = '0; f.txnid       = '1; this.expect_field_at(f, n, off, $bits(f.txnid),       "CHI-D", "TxnID");       off += $bits(f.txnid);
    f = '0; f.fwdnid      = '1; this.expect_field_at(f, n, off, $bits(f.fwdnid),      "CHI-D", "FwdNID");      off += $bits(f.fwdnid);
    f = '0; f.fwdtxnid    = '1; this.expect_field_at(f, n, off, $bits(f.fwdtxnid),    "CHI-D", "FwdTxnID");    off += $bits(f.fwdtxnid);
    f = '0; f.opcode      = '1; this.expect_field_at(f, n, off, $bits(f.opcode),      "CHI-D", "Opcode");      off += $bits(f.opcode);
    f = '0; f.addr        = '1; this.expect_field_at(f, n, off, $bits(f.addr),        "CHI-D", "Addr");        off += $bits(f.addr);
    f = '0; f.ns          = '1; this.expect_field_at(f, n, off, $bits(f.ns),          "CHI-D", "NS");          off += $bits(f.ns);
    f = '0; f.donotgotosd = '1; this.expect_field_at(f, n, off, $bits(f.donotgotosd), "CHI-D", "DoNotGoToSD"); off += $bits(f.donotgotosd);
    f = '0; f.rettosrc    = '1; this.expect_field_at(f, n, off, $bits(f.rettosrc),    "CHI-D", "RetToSrc");    off += $bits(f.rettosrc);
    f = '0; f.tracetag    = '1; this.expect_field_at(f, n, off, $bits(f.tracetag),    "CHI-D", "TraceTag");    off += $bits(f.tracetag);
    f = '0; f.mpam        = '1; this.expect_field_at(f, n, off, $bits(f.mpam),        "CHI-D", "MPAM");        off += $bits(f.mpam);

    if (off != n) begin
      `uvm_error(get_name(), $sformatf(
        "ERROR [%s] CHI-D SNP field widths sum to %0d but the flit is %0d bits: a field is unaccounted for",
        super.tc_name, off, n))
    end
  endfunction

  // ---------------------------------------------------------------------------
  // CHI-E, twice: at the regression's MPAM_EN_P = 0 and at MPAM_EN_P = 1. The
  // second is the only place the 11-bit MPAM field exists at all.
  // ---------------------------------------------------------------------------
  protected function void check_e_layout();

    e_snp_t      f;
    e_mpam_snp_t g;
    int unsigned off;
    int unsigned n;

    n   = $bits(f);
    off = 0;

    f = '0; f.qos         = '1; this.expect_field_at(f, n, off, $bits(f.qos),         "CHI-E", "QoS");         off += $bits(f.qos);
    f = '0; f.srcid       = '1; this.expect_field_at(f, n, off, $bits(f.srcid),       "CHI-E", "SrcID");       off += $bits(f.srcid);
    f = '0; f.txnid       = '1; this.expect_field_at(f, n, off, $bits(f.txnid),       "CHI-E", "TxnID");       off += $bits(f.txnid);
    f = '0; f.fwdnid      = '1; this.expect_field_at(f, n, off, $bits(f.fwdnid),      "CHI-E", "FwdNID");      off += $bits(f.fwdnid);
    f = '0; f.fwdtxnid    = '1; this.expect_field_at(f, n, off, $bits(f.fwdtxnid),    "CHI-E", "FwdTxnID");    off += $bits(f.fwdtxnid);
    f = '0; f.opcode      = '1; this.expect_field_at(f, n, off, $bits(f.opcode),      "CHI-E", "Opcode");      off += $bits(f.opcode);
    f = '0; f.addr        = '1; this.expect_field_at(f, n, off, $bits(f.addr),        "CHI-E", "Addr");        off += $bits(f.addr);
    f = '0; f.ns          = '1; this.expect_field_at(f, n, off, $bits(f.ns),          "CHI-E", "NS");          off += $bits(f.ns);
    f = '0; f.donotgotosd = '1; this.expect_field_at(f, n, off, $bits(f.donotgotosd), "CHI-E", "DoNotGoToSD"); off += $bits(f.donotgotosd);
    f = '0; f.rettosrc    = '1; this.expect_field_at(f, n, off, $bits(f.rettosrc),    "CHI-E", "RetToSrc");    off += $bits(f.rettosrc);
    f = '0; f.tracetag    = '1; this.expect_field_at(f, n, off, $bits(f.tracetag),    "CHI-E", "TraceTag");    off += $bits(f.tracetag);
    f = '0; f.mpam        = '1; this.expect_field_at(f, n, off, $bits(f.mpam),        "CHI-E", "MPAM");        off += $bits(f.mpam);

    if (off != n) begin
      `uvm_error(get_name(), $sformatf(
        "ERROR [%s] CHI-E SNP field widths sum to %0d but the flit is %0d bits",
        super.tc_name, off, n))
    end

    // MPAM_EN_P = 1: the field is VIP_CHI_MPAM_WIDTH_C wide and still the most
    // significant, so the flit grows by exactly the difference and nothing below
    // MPAM moves. Enabling it used to produce an SNP flit 11 bits short of the
    // specification's, because the field was not in the struct at all.
    if ($bits(g) != ($bits(f) + VIP_CHI_MPAM_WIDTH_C - 1)) begin
      `uvm_error(get_name(), $sformatf(
        "ERROR [%s] MPAM_EN_P=1 SNP flit is %0d bits, expected %0d (%0d + %0d - 1)",
        super.tc_name, $bits(g), $bits(f) + VIP_CHI_MPAM_WIDTH_C - 1,
        $bits(f), VIP_CHI_MPAM_WIDTH_C))
    end else begin
      this.fields_checked++;
    end

    g = '0;
    g.mpam = '1;
    this.expect_field_at(g, $bits(g), $bits(g) - VIP_CHI_MPAM_WIDTH_C,
                         VIP_CHI_MPAM_WIDTH_C, "CHI-E MPAM_EN_P=1", "MPAM");
  endfunction

  // ---------------------------------------------------------------------------
  // Run Phase. No traffic: this is a layout assertion, and the flit types are
  // the thing under test.
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    phase.raise_objection(this);

    this.fields_checked = 0;
    this.check_d_layout();
    this.check_e_layout();

    // 12 D fields + 12 E fields + the two MPAM_EN_P=1 checks.
    if (this.fields_checked != 26) begin
      `uvm_error(get_name(), $sformatf(
        "ERROR [%s] %0d field placements confirmed, expected 26 -- the test itself skipped something",
        super.tc_name, this.fields_checked))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] SNP flit layout matches D Table 12-8 / E Table 13-8 in %0d placements, MPAM both ways",
      super.tc_name, this.fields_checked), UVM_LOW)

    phase.drop_objection(this);
  endtask
endclass
