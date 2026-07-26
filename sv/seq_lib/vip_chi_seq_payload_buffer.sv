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

`ifndef VIP_CHI_SEQ_PAYLOAD_BUFFER
`define VIP_CHI_SEQ_PAYLOAD_BUFFER

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

class vip_chi_seq_payload_buffer #(
  vip_chi_cfg_t CFG_P = VIP_CHI_DEFAULT_CFG_C
  ) extends uvm_object;

  `uvm_object_param_utils(vip_chi_seq_payload_buffer #(CFG_P))

  typedef vip_chi_item  #(CFG_P) item_t;
  typedef vip_chi_types #(CFG_P)::data_t data_t;
  typedef vip_chi_types #(CFG_P)::be_t   be_t;

  localparam int DATA_BYTES_C = CFG_P.DATA_BYTES_P;

  protected data_t data [$];
  protected be_t   be   [$];

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name = "vip_chi_seq_payload_buffer");
    super.new(name);
  endfunction

  // ---------------------------------------------------------------------------
  // Clear any queued custom payload slices.
  // ---------------------------------------------------------------------------
  function void reset();
    this.data.delete();
    this.be.delete();
  endfunction

  // ---------------------------------------------------------------------------
  // Load custom write data, one queue entry per DAT beat.
  // ---------------------------------------------------------------------------
  function void set_data(input data_t data [$]);
    this.data = data;
  endfunction

  // ---------------------------------------------------------------------------
  // Load custom write byte-enables, one queue entry per DAT beat.
  // ---------------------------------------------------------------------------
  function void set_be(input be_t be [$]);
    this.be = be;
  endfunction

  // ---------------------------------------------------------------------------
  // Return the number of custom data beats still queued.
  // ---------------------------------------------------------------------------
  function int data_size();
    return this.data.size();
  endfunction

  // ---------------------------------------------------------------------------
  // Return TRUE once all queued custom data beats have been consumed.
  // ---------------------------------------------------------------------------
  function bit exhausted();
    return (this.data.size() == 0);
  endfunction

  // ---------------------------------------------------------------------------
  // Return TRUE when the caller supplied custom byte-enables.
  // ---------------------------------------------------------------------------
  function bit has_custom_be();
    return (this.be.size() != 0);
  endfunction

  // ---------------------------------------------------------------------------
  // Limit the item size range so the next request cannot consume more custom
  // data beats than remain queued.
  // ---------------------------------------------------------------------------
  function void clamp_size(ref vip_chi_cfg_item item_cfg);
    int remaining_bytes;
    int max_size;

    if (this.data.size() == 0) begin
      return;
    end

    remaining_bytes = this.data.size() * DATA_BYTES_C;
    max_size = 0;
    while ((max_size < 6) && ((1 << (max_size + 1)) <= remaining_bytes)) begin
      max_size++;
    end

    if (item_cfg.max_size > max_size) begin
      item_cfg.max_size = max_size;
      if (item_cfg.min_size > item_cfg.max_size) begin
        item_cfg.min_size = item_cfg.max_size;
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Copy the next queued custom payload slice onto the randomized item and
  // consume those beats from the buffer queues.
  // ---------------------------------------------------------------------------
  function void apply(
    input item_t            item,
    input vip_chi_cfg_item  item_cfg
  );
    int beats;

    if (item_cfg.data_type != VIP_CHI_DATA_CUSTOM_E) begin
      return;
    end

    beats = item.get_payload_beat_count();
    if (beats > this.data.size()) begin
      `uvm_fatal(item.get_name(), $sformatf(
        "FATAL [%s] custom payload buffer underrun: need %0d beats, have %0d",
        item.get_name(), beats, this.data.size()))
    end

    if ((this.be.size() != 0) && (beats > this.be.size())) begin
      `uvm_fatal(item.get_name(), $sformatf(
        "FATAL [%s] custom BE buffer underrun: need %0d beats, have %0d",
        item.get_name(), beats, this.be.size()))
    end

    for (int beat = 0; beat < beats; beat++) begin
      item.data[beat] = this.data[beat];
      if (this.be.size() != 0) begin
        item.be[beat] = this.be[beat];
      end
    end

    for (int beat = 0; beat < beats; beat++) begin
      this.data.delete(0);
      if (this.be.size() != 0) begin
        this.be.delete(0);
      end
    end
  endfunction

endclass

`endif