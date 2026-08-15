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
// Combined Write + CMO requests (Issue E only): one request carrying both a
// write and a cache maintenance operation to the same address, which the
// completer must apply IN THAT ORDER.
//
// One sequence for all six rather than six sequences, because they differ only
// in two independent choices -- Full or Ptl, and which CMO rides along -- and
// spelling that as two setters keeps the six reachable from one place. A test
// that wants a specific opcode says which write and which CMO it wants, rather
// than picking a class name that encodes both.
//
////////////////////////////////////////////////////////////////////////////////

`ifndef VIP_CHI_WRITE_CMO_SEQ
`define VIP_CHI_WRITE_CMO_SEQ

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

// The CMO half. CleanShared and CleanInvalid complete with no state change at a
// memory node, which has no cache; the persistent form is the one that adds an
// observable Persist response and therefore the one with an order to get wrong.
typedef enum {
  VIP_CHI_CMO_CLEAN_SH_E,
  VIP_CHI_CMO_CLEAN_INV_E,
  VIP_CHI_CMO_CLEAN_SH_PER_SEP_E
} vip_chi_combined_cmo_e;

class vip_chi_write_cmo_seq #(
  vip_chi_cfg_t CFG_P = VIP_CHI_DEFAULT_CFG_C
  ) extends vip_chi_base_seq #(CFG_P);

  `uvm_object_param_utils(vip_chi_write_cmo_seq #(CFG_P))

  typedef vip_chi_types #(CFG_P)::req_opcode_t req_opcode_t;

  protected bit                    partial;
  protected vip_chi_combined_cmo_e cmo;

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name = "vip_chi_write_cmo_seq");
    super.new(name);
    this.partial = 1'b0;
    this.cmo     = VIP_CHI_CMO_CLEAN_SH_E;
  endfunction

  // Ptl rather than Full: the write half becomes a partial write.
  function void set_partial(input bit value);
    this.partial = value;
  endfunction

  function void set_cmo(input vip_chi_combined_cmo_e value);
    this.cmo = value;
  endfunction

  // TRUE when the CMO half is persistent, so the completer owes a Persist.
  function bit is_persist();
    return (this.cmo == VIP_CHI_CMO_CLEAN_SH_PER_SEP_E);
  endfunction

  // ---------------------------------------------------------------------------
  // Preview one generated combined request without starting the sequence. The
  // pool opt-in belongs here too, not only in body(): previewing forces the same
  // opcode through the same constraints, so without it the preview alone fails
  // to solve.
  // ---------------------------------------------------------------------------
  function item_t preview_next_request();
    super.set_direction(VIP_CHI_DIR_WRITE_E);
    super.set_combined_write_cmo_enable(1'b1);
    return super.preview_next_request();
  endfunction

  // ---------------------------------------------------------------------------
  // Pin the direction and forward to the inherited generation loop.
  // ---------------------------------------------------------------------------
  task body();
    super.set_direction(VIP_CHI_DIR_WRITE_E);

    // The six are opt-in in the item's legal-opcode pool, and this sequence is
    // the thing opting in: without it the constraint solver rejects the very
    // opcode this sequence exists to drive.
    super.set_combined_write_cmo_enable(1'b1);

    if (CFG_P.ISSUE_P != VIP_CHI_ISSUE_E_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] combined Write+CMO is only legal under CHI-E", get_name()))
      return;
    end

    super.body();
  endtask

  // ---------------------------------------------------------------------------
  // Force the request opcode to the selected combined form.
  //
  // Every one of them sits in the Opcode[6] = 1 half of the REQ table and does
  // not fit CHI-D's 6-bit opcode field at all, so a non-E config is a fatal
  // rather than a silent downgrade: truncation would put a different, legal
  // opcode on the wire.
  // ---------------------------------------------------------------------------
  virtual protected function req_opcode_t choose_opcode();

    if (CFG_P.ISSUE_P != VIP_CHI_ISSUE_E_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] combined Write+CMO is only legal under CHI-E", get_name()))
      return req_opcode_t'('0);
    end

    case (this.cmo)
      VIP_CHI_CMO_CLEAN_INV_E: begin
        return this.partial
          ? req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_PTL_CLEAN_INV_C)
          : req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_FULL_CLEAN_INV_C);
      end
      VIP_CHI_CMO_CLEAN_SH_PER_SEP_E: begin
        return this.partial
          ? req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_PTL_CLEAN_SH_PER_SEP_C)
          : req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_FULL_CLEAN_SH_PER_SEP_C);
      end
      default: begin
        return this.partial
          ? req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_PTL_CLEAN_SH_C)
          : req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_FULL_CLEAN_SH_C);
      end
    endcase
  endfunction

endclass

`endif
