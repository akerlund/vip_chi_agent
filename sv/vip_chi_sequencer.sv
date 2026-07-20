`ifndef VIP_CHI_SEQUENCER
`define VIP_CHI_SEQUENCER

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

class vip_chi_sequencer #(
  vip_chi_cfg_t CFG_P = VIP_CHI_DEFAULT_CFG_C
  ) extends uvm_sequencer #(vip_chi_item #(CFG_P));

  `uvm_component_param_utils(vip_chi_sequencer #(CFG_P))

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Stop in-flight sequences and restart the phase-default sequence after a
  // coordinated agent reset.
  // ---------------------------------------------------------------------------
  function void handle_reset(input uvm_phase phase);
    uvm_objection objection;
    int           objections_count;

    objection = phase.get_objection();
    super.stop_sequences();

    objections_count = objection.get_objection_count(this);
    if (objections_count > 0) begin
      objection.drop_objection(
        this,
        $sformatf("Dropping (%0d) objections at reset", objections_count),
        objections_count);
    end

    super.start_phase_sequence(phase);
  endfunction

endclass

`endif