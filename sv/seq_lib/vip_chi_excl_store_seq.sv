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

`ifndef VIP_CHI_EXCL_STORE_SEQ
`define VIP_CHI_EXCL_STORE_SEQ

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

// -----------------------------------------------------------------------------
// Exclusive store (SC): a CleanUnique with the exclusive attribute set. It is a
// WRITE-direction, RSP-only (no data) ownership upgrade. If the home's monitor
// for this (line, port) is still valid, the store "wins": the home invalidates
// the other holders, grants Unique, and completes Comp/ExclOkay. If an
// intervening conflict cleared the monitor the store "fails": the home still
// upgrades to Unique but completes Comp/NormalOkay, and the RN-F must retry.
// The exclusive result lands on req.rsp_resp_err. Pair with vip_chi_excl_load_seq.
// -----------------------------------------------------------------------------
class vip_chi_excl_store_seq #(
  vip_chi_cfg_t CFG_P = VIP_CHI_DEFAULT_CFG_C
  ) extends vip_chi_coherent_base_seq #(CFG_P);

  `uvm_object_param_utils(vip_chi_excl_store_seq #(CFG_P))

  function new(input string name = "vip_chi_excl_store_seq");
    super.new(name);
  endfunction

  task body();
    super.set_direction(VIP_CHI_DIR_WRITE_E);
    super.set_coherent_opcode(req_opcode_t'(VIP_CHI_REQ_CLEAN_UNIQUE_C));
    // Set excl AFTER any reset() the test issued in cfg (reset clears excl_val).
    super.set_excl(1'b1);
    super.body();
  endtask

endclass

`endif
