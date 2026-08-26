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

`ifndef VIP_CHI_AGENT_PKG
`define VIP_CHI_AGENT_PKG

package vip_chi_agent_pkg;

  `include "uvm_macros.svh"
  import uvm_pkg::*;
  import vip_chi_types_pkg::*;
  import vip_memory_pkg::*;

  `include "vip_gauss.sv"
  `include "vip_chi_cfg_agent.sv"
  `include "vip_chi_cfg_item.sv"
  `include "vip_chi_lcrd_mgr.sv"
  `include "vip_chi_item.sv"
  `include "vip_chi_sequencer.sv"
  `include "vip_chi_monitor.sv"
  `include "vip_chi_monitor_e.sv"
  `include "vip_chi_coverage.sv"
  `include "vip_chi_perf_counters.sv"
  // SAM ahead of the scoreboard: Checker B replicates the HN-I address decode.
  `include "vip_chi_hni_sam.sv"
  `include "vip_chi_scoreboard.sv"
  `include "vip_chi_coherency_checker.sv"
  `include "vip_chi_issue_e_fields.sv"
  `include "vip_chi_driver_rni.sv"
  `include "vip_chi_driver_rni_e.sv"
  `include "vip_chi_driver_rnf.sv"
  `include "vip_chi_driver_rnf_e.sv"
  `include "vip_chi_driver_snf.sv"
  `include "vip_chi_driver_snf_e.sv"
  `include "vip_chi_driver_hni.sv"
  `include "vip_chi_driver_hnf.sv"
  `include "vip_chi_driver_hnf_e.sv"
  `include "seq_lib/vip_chi_seq_config.sv"
  `include "seq_lib/vip_chi_addr_iterator.sv"
  `include "seq_lib/vip_chi_seq_payload_buffer.sv"
  `include "seq_lib/vip_chi_seq_counter_iter.sv"
  `include "seq_lib/vip_chi_base_seq.sv"
  `include "seq_lib/vip_chi_read_seq.sv"
  `include "seq_lib/vip_chi_coherent_base_seq.sv"
  `include "seq_lib/vip_chi_readshared_seq.sv"
  `include "seq_lib/vip_chi_readclean_seq.sv"
  `include "seq_lib/vip_chi_readunique_seq.sv"
  `include "seq_lib/vip_chi_writeback_seq.sv"
  `include "seq_lib/vip_chi_evict_seq.sv"
  `include "seq_lib/vip_chi_write_unique_zero_seq.sv"
  `include "seq_lib/vip_chi_write_evict_or_evict_seq.sv"
  `include "seq_lib/vip_chi_makereadunique_seq.sv"
  `include "seq_lib/vip_chi_cleaninvalid_seq.sv"
  `include "seq_lib/vip_chi_makeinvalid_seq.sv"
  `include "seq_lib/vip_chi_makeunique_seq.sv"
  `include "seq_lib/vip_chi_readonce_seq.sv"
  `include "seq_lib/vip_chi_writeunique_seq.sv"
  `include "seq_lib/vip_chi_excl_load_seq.sv"
  `include "seq_lib/vip_chi_excl_store_seq.sv"
  `include "seq_lib/vip_chi_write_seq.sv"
  `include "seq_lib/vip_chi_write_zero_seq.sv"
  `include "seq_lib/vip_chi_write_cmo_seq.sv"
  `include "seq_lib/vip_chi_atomic_seq.sv"
  `include "seq_lib/vip_chi_persist_seq.sv"
  `include "seq_lib/vip_chi_pipelined_seq.sv"
  `include "seq_lib/vip_chi_raw_seq.sv"
  `include "vip_chi_agent.sv"
  `include "vip_chi_agent_e.sv"
  `include "vip_chi_hni_agent.sv"
  `include "vip_chi_hnf_agent.sv"
  `include "vip_chi_hnf_agent_e.sv"
endpackage

`endif