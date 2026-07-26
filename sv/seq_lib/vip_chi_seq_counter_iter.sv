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

`ifndef VIP_CHI_SEQ_COUNTER_ITER
`define VIP_CHI_SEQ_COUNTER_ITER

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

class vip_chi_seq_counter_iter #(
  vip_chi_cfg_t CFG_P = VIP_CHI_DEFAULT_CFG_C
  ) extends uvm_object;

  `uvm_object_param_utils(vip_chi_seq_counter_iter #(CFG_P))

  typedef vip_chi_item  #(CFG_P) item_t;
  typedef vip_chi_types #(CFG_P)::data_t data_t;

  protected data_t counter;
  protected data_t counter_increment;

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name = "vip_chi_seq_counter_iter");
    super.new(name);
    this.counter           = '0;
    this.counter_increment = data_t'(1);
  endfunction

  // ---------------------------------------------------------------------------
  // Restore the counter generator to its default state.
  // ---------------------------------------------------------------------------
  function void reset();
    this.counter           = '0;
    this.counter_increment = data_t'(1);
  endfunction

  // ---------------------------------------------------------------------------
  // Set the next counter value used for COUNTER-mode payload generation.
  // ---------------------------------------------------------------------------
  function void set_counter(input data_t start);
    this.counter = start;
  endfunction

  // ---------------------------------------------------------------------------
  // Set the increment applied after each generated COUNTER beat.
  // ---------------------------------------------------------------------------
  function void set_increment(input data_t increment);
    this.counter_increment = increment;
  endfunction

  // ---------------------------------------------------------------------------
  // Return the current counter state.
  // ---------------------------------------------------------------------------
  function data_t get_counter();
    return this.counter;
  endfunction

  // ---------------------------------------------------------------------------
  // Return the current counter value and advance to the next one.
  // ---------------------------------------------------------------------------
  function data_t next();
    data_t value;

    value = this.counter;
    this.counter += this.counter_increment;
    return value;
  endfunction

  // ---------------------------------------------------------------------------
  // Stamp the current counter configuration onto a CHI item before randomize.
  // ---------------------------------------------------------------------------
  function void configure_item(input item_t item);
    item.set_counter_value(this.counter);
    item.set_counter_increment(this.counter_increment);
  endfunction

  // ---------------------------------------------------------------------------
  // Advance the iterator state after one randomized item has been consumed.
  // ---------------------------------------------------------------------------
  function void advance(
    input item_t           item,
    input vip_chi_cfg_item item_cfg
  );

    if (item_cfg.data_type == VIP_CHI_DATA_COUNTER_E) begin
      this.counter = item.get_counter();
    end
  endfunction

endclass

`endif