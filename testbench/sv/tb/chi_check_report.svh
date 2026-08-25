////////////////////////////////////////////////////////////////////////////////
//
// End-of-test reporting for the per-rule protocol-check tallies.
//
// Free functions in chi_tb_pkg rather than methods on an env, because EVERY env
// needs them and there is no base class the coherent and non-coherent ones
// share. They were duplicated per env before, and the duplication had already
// caused one silent divergence: the coherent copy relied on an uninitialised bit
// reading zero, which was the right behaviour for the wrong reason. One
// definition means the two cannot drift again.
//
// They take the four tally ARRAYS rather than a virtual interface handle,
// deliberately: a `virtual vip_chi_if` is typed by its ROLE_P parameter, so an
// env holding interfaces of several roles cannot pass them through one argument.
// The arrays are role-agnostic.
//
// Reporting goes through uvm_pkg's global uvm_report_* rather than the macros,
// which need a component context these functions do not have.
//
////////////////////////////////////////////////////////////////////////////////

// Which half of the registry a bind owns.
//
// A bind judges either the SNP channel or everything else, never both:
// vip_chi_sva owns the main range and vip_chi_snp_sva the SNP range. Reporting a
// bind against rules it does not own would list every one of them as never
// exercised, which is how a vacuity report teaches its reader to ignore it.
typedef enum {
  CHI_CHECK_SCOPE_MAIN_E,
  CHI_CHECK_SCOPE_SNP_E
} chi_check_scope_t;

function automatic bit chi_check_in_scope(
  input vip_chi_check_id_t id,
  input chi_check_scope_t  scope
);
  return (scope == CHI_CHECK_SCOPE_SNP_E) ? vip_chi_check_is_snp(id)
                                          : !vip_chi_check_is_snp(id);
endfunction

// ---------------------------------------------------------------------------
// Fold one bind's tallies into the run's verdict, and say what never ran.
// ---------------------------------------------------------------------------
function automatic void chi_check_report_tallies(
  input string                   tag,
  input chi_check_scope_t        scope,
  input bit                      enabled    [VIP_CHI_CHK_NUM_E],
  input vip_chi_check_severity_t severity   [VIP_CHI_CHK_NUM_E],
  input int unsigned             pass_count [VIP_CHI_CHK_NUM_E],
  input int unsigned             fail_count [VIP_CHI_CHK_NUM_E]
);
  int unsigned not_exercised;
  int unsigned in_scope;

  not_exercised = 0;
  in_scope      = 0;

  for (int unsigned id = 0; id < int'(VIP_CHI_CHK_NUM_E); id++) begin
    if (!chi_check_in_scope(vip_chi_check_id_t'(id), scope)) begin
      continue;
    end
    if (!enabled[id]) begin
      continue;
    end
    in_scope++;

    if ((fail_count[id] > 0) && (severity[id] == VIP_CHI_CHK_SEV_ERROR_E)) begin
      uvm_pkg::uvm_report_error("VIP_CHI_CHECK", $sformatf(
        "%s: %s failed %0d time(s)",
        tag, vip_chi_check_name(vip_chi_check_id_t'(id)), fail_count[id]));
    end

    if ((pass_count[id] == 0) && (fail_count[id] == 0)) begin
      not_exercised++;
      // One line per rule: the report server wraps at a fixed column, so a line
      // carrying a list loses everything past the wrap.
      uvm_pkg::uvm_report_info("VIP_CHI_CHECK", $sformatf(
        "VIP_CHI CHECK NOT EXERCISED: bind=%s rule=%s",
        tag, vip_chi_check_name(vip_chi_check_id_t'(id))), UVM_LOW);
    end
  end

  uvm_pkg::uvm_report_info("VIP_CHI_CHECK", $sformatf(
    "VIP_CHI CHECK VACUITY: bind=%s not_exercised=%0d of=%0d",
    tag, not_exercised, in_scope), UVM_LOW);
endfunction

// ---------------------------------------------------------------------------
// Append this run's per-rule tallies to a CSV for cross-run aggregation.
//
// A regression answers "which check does NOTHING anywhere" only by unioning
// every run, and no single run can tell you. Appending rather than rewriting is
// what makes that union work, and each row carries the testcase name so a rule
// exercised by exactly one test can be traced back to it -- the question you
// actually ask once a check turns out to be near-vacuous.
//
// Every bind exports, including the SNP ones. They did not, and the omission was
// invisible in exactly the way this whole mechanism exists to prevent: the
// aggregation reported on the rules it had rows for and said nothing about the
// seven it had never been given, so a report covering two of fourteen binds read
// as a report on all of them.
// ---------------------------------------------------------------------------
// Tags claimed so far in this run, keyed on run/tag/scope.
//
// The tag is the ONLY thing in an exported row that says which bind produced it,
// so two binds sharing one tag do not lose rows -- they merge, and every
// per-bind question the export exists to answer is then answered about the wrong
// interface. That is a silent failure: the file is well formed, the row count is
// right, and nothing in it says a name was reused.
//
// Keyed on scope as well as tag because one interface legitimately exports
// twice, once for the main check range and once for the SNP range. Keyed on the
// run because the aggregation is a union over a whole sweep, and the same tag
// appearing in every run is the normal case, not a collision.
bit chi_check_tag_claimed [string];

// Claim one tag for this run, or report the collision. Called from the export
// below before it looks at the plusarg, so the guard is armed on an ordinary run
// and not only on a sweep that happens to be writing the CSV.
function automatic void chi_check_claim_tag(
  input string            run_name,
  input string            tag,
  input chi_check_scope_t scope
);
  string key;

  key = $sformatf("%s/%s/%s", run_name, tag, scope.name());
  if (chi_check_tag_claimed.exists(key)) begin
    uvm_pkg::uvm_report_error("VIP_CHI_CHECK", $sformatf(
      "check-tally tag '%s' was exported twice for scope %s in run %s: two binds under one name merge into one set of rows, and every per-bind question asked of the export afterwards is answered about the wrong interface",
      tag, scope.name(), run_name));
  end
  chi_check_tag_claimed[key] = 1'b1;
endfunction

// The opcode-evidence companion. A separate file rather than a column on the
// tally CSV, and deliberately: that file is keyed (run, bind, check) and three
// gates already read it, so widening it to (run, bind, check, opcode) would
// multiply every row to carry a fact about the STIMULUS rather than about which
// check ran.
//
// scripts/check_opcode_evidence.py joins this against the classifier sets
// scripts/check_classifier_coverage.py resolves statically. Neither half is a
// gate on its own: an opcode no classifier claims is only a defect once
// something drives it, and an opcode that is driven is only a defect once no
// classifier claims it.
function automatic void chi_check_export_opcode_csv(
  input string       tag,
  input int unsigned req_opcode_seen [128]
);
  string path;
  string run_name;
  int    fd;

  run_name = "unknown";
  void'($value$plusargs("UVM_TESTNAME=%s", run_name));

  if (!$value$plusargs("vip_chi_opcode_csv=%s", path)) begin
    return;
  end

  fd = $fopen(path, "r");
  if (fd == 0) begin
    fd = $fopen(path, "w");
    if (fd == 0) begin
      uvm_pkg::uvm_report_warning("VIP_CHI_CHECK", $sformatf(
        "could not open %s for the opcode-evidence export", path));
      return;
    end
    $fdisplay(fd, "run,bind,opcode,seen");
  end
  else begin
    $fclose(fd);
    fd = $fopen(path, "a");
    if (fd == 0) begin
      uvm_pkg::uvm_report_warning("VIP_CHI_CHECK", $sformatf(
        "could not append to %s for the opcode-evidence export", path));
      return;
    end
  end

  for (int unsigned op = 0; op < 128; op++) begin
    if (req_opcode_seen[op] != 0) begin
      $fdisplay(fd, "%s,%s,0x%02h,%0d", run_name, tag, op, req_opcode_seen[op]);
    end
  end

  $fclose(fd);
endfunction

function automatic void chi_check_export_csv(
  input string                   tag,
  input chi_check_scope_t        scope,
  input bit                      enabled    [VIP_CHI_CHK_NUM_E],
  input vip_chi_check_severity_t severity   [VIP_CHI_CHK_NUM_E],
  input int unsigned             pass_count [VIP_CHI_CHK_NUM_E],
  input int unsigned             fail_count [VIP_CHI_CHK_NUM_E]
);
  string path;
  string run_name;
  int    fd;

  run_name = "unknown";
  void'($value$plusargs("UVM_TESTNAME=%s", run_name));

  chi_check_claim_tag(run_name, tag, scope);

  if (!$value$plusargs("vip_chi_check_csv=%s", path)) begin
    return;
  end

  // Append, and write the header only when the file is new -- the aggregation
  // script reads one file produced by a whole sweep.
  fd = $fopen(path, "r");
  if (fd == 0) begin
    fd = $fopen(path, "w");
    if (fd == 0) begin
      uvm_pkg::uvm_report_warning("VIP_CHI_CHECK", $sformatf(
        "could not open %s for the check-tally export", path));
      return;
    end
    $fdisplay(fd, "run,bind,check,enabled,severity,passes,fails");
  end
  else begin
    $fclose(fd);
    fd = $fopen(path, "a");
    if (fd == 0) begin
      uvm_pkg::uvm_report_warning("VIP_CHI_CHECK", $sformatf(
        "could not append to %s for the check-tally export", path));
      return;
    end
  end

  for (int unsigned id = 0; id < int'(VIP_CHI_CHK_NUM_E); id++) begin
    if (!chi_check_in_scope(vip_chi_check_id_t'(id), scope)) begin
      continue;
    end
    $fdisplay(fd, "%s,%s,%s,%0d,%s,%0d,%0d",
      run_name, tag, vip_chi_check_name(vip_chi_check_id_t'(id)),
      enabled[id], severity[id].name(), pass_count[id], fail_count[id]);
  end

  $fclose(fd);
endfunction
