// ===========================================================================
// tc_chi_opcode_pool_safe
//
// Regression test for §7 T1: PCrdReturn must not be randomizable out of the
// non-coherent con_opcode_legal pools. The SN-F silently ignores PCrdReturn and
// the RN-I unconditionally waits for a completion that never arrives, so a plain
// item.randomize() that lands on PCrdReturn wedges the driver with no diagnostic.
//
// This randomizes an RN-I item many times across both directions and both CHI
// issues (CHI-D and CHI-E) and asserts the drawn opcode is (a) never PcrdReturn
// and (b) always accepted by the req_opcode_is_legal helper. Before the fix the
// write pool would occasionally draw PcrdReturn; after it, never.
//
// The same draw is repeated for the coherent RN-F pool, which is a second
// hand-written opcode table describing the same rule as the helper:
// cross-checking the two is what stops them drifting apart.
// ===========================================================================
class tc_chi_opcode_pool_safe extends uvm_test;

  `uvm_component_utils(tc_chi_opcode_pool_safe)

  string tc_name;

  localparam int N_DRAWS_C = 400;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
    tc_name = name;
    void'($value$plusargs("UVM_TESTNAME=%s", tc_name));
  endfunction

  task run_phase(input uvm_phase phase);

    vip_chi_item #(CHI_D_WIDE_CFG_C) d_item;
    vip_chi_item #(CHI_E_WIDE_CFG_C) e_item;

    phase.raise_objection(this);

    d_item = new("d_item");
    e_item = new("e_item");
    d_item.set_config(CHI_D_WIDE_CFG_C);
    e_item.set_config(CHI_E_WIDE_CFG_C);

    for (int i = 0; i < N_DRAWS_C; i++) begin
      vip_chi_dir_t dir;
      dir = (i[0]) ? VIP_CHI_DIR_WRITE_E : VIP_CHI_DIR_READ_E;

      // --- CHI-D ---
      if (!d_item.randomize() with {
        role      == VIP_CHI_ROLE_RNI_E;
        direction == dir;
      }) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] CHI-D RN-I item failed to randomize (draw %0d, dir %s)",
          tc_name, i, dir.name()))
      end
      if (d_item.opcode == vip_chi_item #(CHI_D_WIDE_CFG_C)::req_opcode_t'(VIP_CHI_REQ_PCRD_RETURN_C)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] CHI-D RN-I randomize() drew PCrdReturn (draw %0d) -- would wedge the driver (T1)",
          tc_name, i))
      end
      if (!d_item.req_opcode_is_legal(d_item.opcode, d_item.direction)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] CHI-D RN-I randomize() drew an opcode the legality helper rejects (draw %0d, op 0x%0h)",
          tc_name, i, d_item.opcode))
      end

      // --- CHI-E ---
      if (!e_item.randomize() with {
        role      == VIP_CHI_ROLE_RNI_E;
        direction == dir;
      }) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] CHI-E RN-I item failed to randomize (draw %0d, dir %s)",
          tc_name, i, dir.name()))
      end
      if (e_item.opcode == vip_chi_item #(CHI_E_WIDE_CFG_C)::req_opcode_t'(VIP_CHI_REQ_PCRD_RETURN_C)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] CHI-E RN-I randomize() drew PCrdReturn (draw %0d) -- would wedge the driver (T1)",
          tc_name, i))
      end
      if (!e_item.req_opcode_is_legal(e_item.opcode, e_item.direction)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] CHI-E RN-I randomize() drew an opcode the legality helper rejects (draw %0d, op 0x%0h)",
          tc_name, i, e_item.opcode))
      end

      // --- Coherent RN-F pool, both issues ---
      // con_opcode_legal_rnf and req_opcode_is_legal() are two hand-written
      // tables describing one rule, so they can drift apart silently. Drawing
      // from the pool and asking the helper about the result is what keeps them
      // honest -- an opcode added to one and not the other fails here.
      if (!d_item.randomize() with {
        role      == VIP_CHI_ROLE_RNF_E;
        direction == dir;
      }) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] CHI-D RN-F item failed to randomize (draw %0d, dir %s)",
          tc_name, i, dir.name()))
      end
      if (!d_item.req_opcode_is_legal(d_item.opcode, d_item.direction)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] CHI-D RN-F randomize() drew an opcode the legality helper rejects (draw %0d, op 0x%0h)",
          tc_name, i, d_item.opcode))
      end

      if (!e_item.randomize() with {
        role      == VIP_CHI_ROLE_RNF_E;
        direction == dir;
      }) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] CHI-E RN-F item failed to randomize (draw %0d, dir %s)",
          tc_name, i, dir.name()))
      end
      if (!e_item.req_opcode_is_legal(e_item.opcode, e_item.direction)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] CHI-E RN-F randomize() drew an opcode the legality helper rejects (draw %0d, op 0x%0h)",
          tc_name, i, e_item.opcode))
      end
    end

    `uvm_info(get_name(), $sformatf(
      "[%s] %0d RN-I randomizations per CHI issue drew no PCrdReturn (T1 pool clean)",
      tc_name, N_DRAWS_C), UVM_LOW)

    phase.drop_objection(this);
  endtask
endclass
