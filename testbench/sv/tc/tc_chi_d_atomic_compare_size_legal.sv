////////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2026 Fredrik Akerlund
// https://github.com/akerlund/vip_chi_agent
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
////////////////////////////////////////////////////////////////////////////////
//
// The POSITIVE control for CHI_ATOMIC_SIZE_LEGAL.
//
// The five wide-operand atomic testcases prove the rule FIRES: they drive Sizes
// Table 2-17 does not list, arm the rule at VIP_CHI_CHK_SEV_OFF_E, and require
// it to have reported. Nothing proved the other half -- that the rule permits
// what the table DOES list -- and a rule that fires on everything would pass all
// five of them.
//
// AtomicCompare at Size 5 is the case worth controlling, because it is the one a
// plausible implementation gets wrong. Its Size is the COMBINED compare+swap
// size, so Table 2-17 gives it a ceiling one step above the ordinary atomic
// limit: 32 bytes, two 16-byte operands. Deriving that ceiling from the ordinary
// 8-byte limit yields Size <= 4 and rejects a legal request. On this 16-byte cut
// Size 5 is also the only value that is both legal and beat-representable, since
// con_atomic_compare_size requires Size >= clog2(DATA_BYTES_P) + 1 = 5.
//
// The rule is ARMED here -- not turned down to OFF -- which is the whole point:
// the checks below are about a live rule seeing conformant traffic.
//
// The sequence is configured plainly: Table 2-17's Sizes are what the item's
// constraints draw by default, so this testcase gets the specification without
// asking for it. Should the constraint's ceiling drop back to Size 4,
// randomization fails outright rather than quietly drawing something else.
//
////////////////////////////////////////////////////////////////////////////////

class tc_chi_d_atomic_compare_size_legal extends chi_base_test;

  typedef vip_chi_item #(CHI_D_CFG_C) item_t;

  `uvm_component_utils(tc_chi_d_atomic_compare_size_legal)

  vip_chi_atomic_seq #(CHI_D_CFG_C) atomic_seq;

  // Plain integer literals, NOT `localparam item_t::data_t`. A class-scope
  // localparam typed through `item_t::` is a form this tree has hit before: VCS
  // does not reject it, it churns on it, and the build stops making progress
  // rather than failing with a message.
  localparam longint unsigned COMPARE_OPERAND_C = 'h4455;
  localparam longint unsigned COMPARE_SWAP_C    = 'h99AA;

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Create the dedicated atomic sequence handle.
  // ---------------------------------------------------------------------------
  function void start_of_simulation_phase(input uvm_phase phase);

    super.start_of_simulation_phase(phase);

    this.atomic_seq = vip_chi_atomic_seq #(CHI_D_CFG_C)::type_id::create("atomic_seq");
  endfunction

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t            request_item;
    item_t            sequence_responses[$];
    item_t::data_t    data_beats[$];
    int               size;
    int unsigned      fails;
    int unsigned      passes;

    phase.raise_objection(this);

    // Table 2-17's AtomicCompare ceiling, and on a 16-byte bus also its floor.
    size = $clog2(CHI_D_CFG_C.DATA_BYTES_P) + 1;

    if (size != 5) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] this control is written for the 16-byte cut, where Table 2-17's 32-byte AtomicCompare is Size 5; this cut wants Size %0d",
      get_name(), size))
    end

    data_beats.delete();
    data_beats.push_back(item_t::data_t'(COMPARE_OPERAND_C));
    data_beats.push_back(item_t::data_t'(COMPARE_SWAP_C));

    this.atomic_seq.reset();
    this.atomic_seq.set_atomic_op(VIP_CHI_ATOMIC_OP_COMPARE_E);
    this.atomic_seq.set_requests(1);
    this.atomic_seq.set_initial_addr(ATOMIC_ADDR_C);
    this.atomic_seq.set_size(item_t::size_t'(size));
    // Table 2-17's Sizes are what a plainly configured sequence draws, so no
    // override is needed to reach them. Should the constraint's ceiling drop
    // back to Size 4, randomization fails outright rather than quietly drawing
    // something else.
    this.atomic_seq.set_get_response(1'b1);
    this.atomic_seq.set_verbose(1'b0);
    this.atomic_seq.set_data(data_beats);
    this.atomic_seq.start(super.v_sqr.rni_sequencer);

    sequence_responses = this.atomic_seq.get_responses();

    if (sequence_responses.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] the legal AtomicCompare returned %0d responses, expected 1; the rest of this testcase says nothing if the request never completed",
      get_name(), sequence_responses.size()))
    end

    super.tb_env.rni_req_fifo.get(request_item);

    if (request_item.opcode != item_t::req_opcode_t'(VIP_CHI_REQ_ATOMIC_COMPARE_C)) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] observed opcode 0x%0h, not AtomicCompare",
      get_name(), request_item.opcode))
    end

    if (int'(request_item.size) != size) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] observed Size %0d on the wire, not %0d; the rule judges what it sees, so a request that did not carry the legal size would make the counts below prove nothing",
      get_name(), int'(request_item.size), size))
    end

    fails = super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_ATOMIC_SIZE_LEGAL_E] +
            super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_ATOMIC_SIZE_LEGAL_E];
    passes = super.tb_env.rni_agent.vif.check_pass_count[VIP_CHI_CHK_ATOMIC_SIZE_LEGAL_E] +
             super.tb_env.snf_agent.vif.check_pass_count[VIP_CHI_CHK_ATOMIC_SIZE_LEGAL_E];

    if (fails != 0) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] CHI_ATOMIC_SIZE_LEGAL reported %0d time(s) against a 32-byte AtomicCompare, which Table 2-17 lists: the rule's ceiling has been derived from the ordinary 8-byte atomic limit instead of from the table, and it is now rejecting conformant traffic",
      get_name(), fails))
    end

    if (passes == 0) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] CHI_ATOMIC_SIZE_LEGAL recorded no pass, so this testcase proves nothing about it. The rule is armed here on purpose -- if it is not reaching this link, the five stress testcases that assert it FIRES are the only evidence it exists, and a rule that only ever fails is indistinguishable from one that is wrong",
      get_name()))
    end

    `uvm_info(get_name(), $sformatf(
    "PASS [%s] a 32-byte AtomicCompare (Size %0d) passed CHI_ATOMIC_SIZE_LEGAL %0d time(s) with the rule armed and reported %0d time(s)",
    get_name(), size, passes, fails), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
