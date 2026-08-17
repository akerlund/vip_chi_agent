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

`ifndef VIP_CHI_WRITE_EVICT_OR_EVICT_SEQ
`define VIP_CHI_WRITE_EVICT_OR_EVICT_SEQ

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

// -----------------------------------------------------------------------------
// WriteEvictOrEvict: the RN-F offers a CLEAN line back and the HOME decides
// whether it wants the data. CompDBIDResp means yes (answered with
// CopyBackWrData, which is an implicit CompAck); Comp means no (answered with an
// explicit CompAck, degenerating into an Evict). ExpCompAck is always set --
// the item constrains it -- because the no-data leg completes only on the ack.
// Which leg the home takes is cfg.hnf_write_evict_request_data.
// -----------------------------------------------------------------------------
class vip_chi_write_evict_or_evict_seq #(
  vip_chi_cfg_t CFG_P = VIP_CHI_DEFAULT_CFG_C
  ) extends vip_chi_coherent_base_seq #(CFG_P);

  `uvm_object_param_utils(vip_chi_write_evict_or_evict_seq #(CFG_P))

  function new(input string name = "vip_chi_write_evict_or_evict_seq");
    super.new(name);
  endfunction

  task body();

    if (CFG_P.ISSUE_P != VIP_CHI_ISSUE_E_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] this opcode sits in the Opcode[6] = 1 half of the REQ table and does not fit CHI-D's 6-bit field",
        get_name()))
      return;
    end

    super.set_direction(VIP_CHI_DIR_WRITE_E);

    // The opcode is opt-in in the item's coherent legal pool, and this sequence
    // is the thing opting in: without it the constraint solver rejects the very
    // opcode this sequence exists to drive.
    super.set_write_evict_or_evict_enable(1'b1);

    // ExpCompAck is not optional here, so the sequence must ask for it: the base
    // sequence pins the bit to its own default, and the item independently
    // constrains this opcode to 1. Left unset the two contradict and the solver
    // fails -- which is the constraint doing its job, not a bug to work around.
    super.set_exp_comp_ack(1'b1);
    super.set_coherent_opcode(req_opcode_t'(VIP_CHI_REQ_WRITE_EVICT_OR_EVICT_C));
    super.body();
  endtask

endclass

`endif
