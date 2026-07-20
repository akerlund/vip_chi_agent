`ifndef VIP_CHI_MAKEINVALID_SEQ
`define VIP_CHI_MAKEINVALID_SEQ

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

// -----------------------------------------------------------------------------
// Coherent MakeInvalid CMO: invalidate ALL copies of the line WITHOUT requiring
// any dirty data be preserved (dirty data may be discarded). The home snoops
// every other holder with SnpMakeInvalid (holder drops to I, no data forwarded)
// and returns an RSP-only Comp. Completion-only, like Evict.
// -----------------------------------------------------------------------------
class vip_chi_makeinvalid_seq #(
  vip_chi_cfg_t CFG_P = VIP_CHI_DEFAULT_CFG_C
  ) extends vip_chi_coherent_base_seq #(CFG_P);

  `uvm_object_param_utils(vip_chi_makeinvalid_seq #(CFG_P))

  function new(input string name = "vip_chi_makeinvalid_seq");
    super.new(name);
  endfunction

  task body();
    super.set_direction(VIP_CHI_DIR_WRITE_E);
    super.set_coherent_opcode(req_opcode_t'(VIP_CHI_REQ_MAKE_INVALID_C));
    super.body();
  endtask

endclass

`endif
