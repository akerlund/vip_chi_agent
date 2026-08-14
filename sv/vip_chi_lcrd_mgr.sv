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

`ifndef VIP_CHI_LCRD_MGR
`define VIP_CHI_LCRD_MGR

import uvm_pkg::*;
`include "uvm_macros.svh"

class vip_chi_lcrd_mgr extends uvm_object;

  `uvm_object_utils(vip_chi_lcrd_mgr)

  protected int unsigned available_credits;
  protected int unsigned max_credits;

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name = "vip_chi_lcrd_mgr");
    super.new(name);
  endfunction

  // ---------------------------------------------------------------------------
  // Configure the credit capacity for one channel and optionally seed the
  // currently-available count. Real CHI links usually start at 0 available and
  // learn the initial grant budget from peer LCRDV pulses after activation.
  // ---------------------------------------------------------------------------
  function void reset(
    input int unsigned max_credits,
    input int unsigned initial_available_credits = 0
  );
    if (initial_available_credits > max_credits) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Invalid credit reset: available=%0d max=%0d",
        get_name(), initial_available_credits, max_credits))
    end

    this.available_credits = initial_available_credits;
    this.max_credits       = max_credits;
  endfunction

  // ---------------------------------------------------------------------------
  // Consume one send-side credit if available.
  // ---------------------------------------------------------------------------
  function bit try_acquire_credit();
    if (this.available_credits == 0) begin
      return 1'b0;
    end

    this.available_credits--;
    return 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Non-consuming check: TRUE when a send-side credit is currently available.
  // Lets a caller decide whether an issue would block before committing to it
  // (e.g. the RN-I mixed pipeline gating a fresh REQ so it can instead drive an
  // already-granted write's data when the completer is credit-starved).
  // ---------------------------------------------------------------------------
  // The count itself, for a caller that has to REPORT it rather than act on it
  // (the deactivation drain says how many credits were still banked).
  function int unsigned available();
    return this.available_credits;
  endfunction

  function bit has_credit();
    return (this.available_credits != 0);
  endfunction

  // ---------------------------------------------------------------------------
  // Return one credit from a peer LCRDV pulse.
  // ---------------------------------------------------------------------------
  function void return_credit();
    if (this.available_credits >= this.max_credits) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Credit overflow: available=%0d max=%0d",
        get_name(), this.available_credits, this.max_credits))
    end

    this.available_credits++;
  endfunction

endclass

`endif