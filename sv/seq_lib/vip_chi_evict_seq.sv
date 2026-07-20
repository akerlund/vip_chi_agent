`ifndef VIP_CHI_EVICT_SEQ
`define VIP_CHI_EVICT_SEQ

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

// -----------------------------------------------------------------------------
// Coherent Evict: a completion-only (no-data) notification that the RN-F is
// dropping a clean line. The home clears the requester's directory ownership and
// returns a plain Comp; no data changes hands.
// -----------------------------------------------------------------------------
class vip_chi_evict_seq #(
  vip_chi_cfg_t CFG_P = VIP_CHI_DEFAULT_CFG_C
  ) extends vip_chi_coherent_base_seq #(CFG_P);

  `uvm_object_param_utils(vip_chi_evict_seq #(CFG_P))

  function new(input string name = "vip_chi_evict_seq");
    super.new(name);
  endfunction

  task body();
    super.set_direction(VIP_CHI_DIR_WRITE_E);
    super.set_coherent_opcode(req_opcode_t'(VIP_CHI_REQ_EVICT_C));
    super.body();
  endtask

endclass

`endif
