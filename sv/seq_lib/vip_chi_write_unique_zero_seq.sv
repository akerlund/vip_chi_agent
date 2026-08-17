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

`ifndef VIP_CHI_WRITE_UNIQUE_ZERO_SEQ
`define VIP_CHI_WRITE_UNIQUE_ZERO_SEQ

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

// -----------------------------------------------------------------------------
// WriteUniqueZero: a snoopable full-line store of ZERO that puts NO data on the
// wire. The snoopable twin of WriteNoSnpZero -- the home invalidates every other
// holder, zeroes the line itself, and completes with DBIDResp* + Comp or a
// combined CompDBIDResp. Never carries CompAck.
// -----------------------------------------------------------------------------
class vip_chi_write_unique_zero_seq #(
  vip_chi_cfg_t CFG_P = VIP_CHI_DEFAULT_CFG_C
  ) extends vip_chi_coherent_base_seq #(CFG_P);

  `uvm_object_param_utils(vip_chi_write_unique_zero_seq #(CFG_P))

  function new(input string name = "vip_chi_write_unique_zero_seq");
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
    super.set_write_unique_zero_enable(1'b1);
    super.set_coherent_opcode(req_opcode_t'(VIP_CHI_REQ_WRITE_UNIQUE_ZERO_C));
    super.body();
  endtask

endclass

`endif
