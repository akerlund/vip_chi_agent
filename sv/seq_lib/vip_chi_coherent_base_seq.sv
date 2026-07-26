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

`ifndef VIP_CHI_COHERENT_BASE_SEQ
`define VIP_CHI_COHERENT_BASE_SEQ

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

// -----------------------------------------------------------------------------
// Base sequence for coherent (RN-F) traffic. It reuses the whole
// vip_chi_base_seq generation loop (iterators, payload, stamping, delays) and
// only redirects two decisions:
//   * role_val()     -> VIP_CHI_ROLE_RNF_E, so items stamp the coherent role.
//   * choose_opcode() -> the configured coherent opcode, instead of the
//                        base's ReadNoSnp / WriteNoSnp defaults.
// Thin per-opcode wrappers pin the direction + opcode and defer to super.body().
// -----------------------------------------------------------------------------
class vip_chi_coherent_base_seq #(
  vip_chi_cfg_t CFG_P = VIP_CHI_DEFAULT_CFG_C
  ) extends vip_chi_base_seq #(CFG_P);

  // Coherent opcode stamped on every generated request (set by the wrappers or a
  // test). Defaults to ReadShared so a bare coherent sequence still does
  // something sensible.
  protected req_opcode_t coh_opcode = req_opcode_t'(VIP_CHI_REQ_READ_SHARED_C);

  `uvm_object_param_utils(vip_chi_coherent_base_seq #(CFG_P))

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name = "vip_chi_coherent_base_seq");
    super.new(name);
  endfunction

  // ---------------------------------------------------------------------------
  // Select the coherent opcode used for subsequent generation.
  // ---------------------------------------------------------------------------
  function void set_coherent_opcode(input req_opcode_t op);
    this.coh_opcode = op;
  endfunction

  // ---------------------------------------------------------------------------
  // Coherent role + opcode overrides consumed by the inherited generation loop.
  // ---------------------------------------------------------------------------
  protected function vip_chi_role_t role_val();
    return VIP_CHI_ROLE_RNF_E;
  endfunction

  protected function req_opcode_t choose_opcode();
    return this.coh_opcode;
  endfunction

endclass

`endif
