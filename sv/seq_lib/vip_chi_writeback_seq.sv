`ifndef VIP_CHI_WRITEBACK_SEQ
`define VIP_CHI_WRITEBACK_SEQ

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

// -----------------------------------------------------------------------------
// Coherent WriteBackFull: give a held (dirty) line back to the home. The write
// path grants a DBID (CompDBIDResp), the RN-F sends the line as CopyBackWrData,
// and the home commits it to memory. The line ends Invalid at the requester.
// -----------------------------------------------------------------------------
class vip_chi_writeback_seq #(
  vip_chi_cfg_t CFG_P = VIP_CHI_DEFAULT_CFG_C
  ) extends vip_chi_coherent_base_seq #(CFG_P);

  `uvm_object_param_utils(vip_chi_writeback_seq #(CFG_P))

  function new(input string name = "vip_chi_writeback_seq");
    super.new(name);
  endfunction

  task body();
    super.set_direction(VIP_CHI_DIR_WRITE_E);
    super.set_coherent_opcode(req_opcode_t'(VIP_CHI_REQ_WRITE_BACK_FULL_C));
    super.body();
  endtask

endclass

`endif
