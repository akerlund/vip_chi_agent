`ifndef VIP_CHI_READONCE_SEQ
`define VIP_CHI_READONCE_SEQ

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

// -----------------------------------------------------------------------------
// Coherent ReadOnce: a non-allocating snapshot read. The requester obtains a
// current copy of the line's data but does NOT cache it (ends Invalid) and gains
// no ownership. The home snoops a dirty holder with SnpOnce (state-preserving) to
// fetch the current value, then returns CompData with resp = Invalid.
// -----------------------------------------------------------------------------
class vip_chi_readonce_seq #(
  vip_chi_cfg_t CFG_P = VIP_CHI_DEFAULT_CFG_C
  ) extends vip_chi_coherent_base_seq #(CFG_P);

  `uvm_object_param_utils(vip_chi_readonce_seq #(CFG_P))

  function new(input string name = "vip_chi_readonce_seq");
    super.new(name);
  endfunction

  task body();
    super.set_direction(VIP_CHI_DIR_READ_E);
    super.set_coherent_opcode(req_opcode_t'(VIP_CHI_REQ_READ_ONCE_C));
    super.body();
  endtask

endclass

`endif
