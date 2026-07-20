class vip_chi_virtual_sequencer extends uvm_sequencer;

  `uvm_component_utils(vip_chi_virtual_sequencer)

  // Integrated RN-I / SN-F sequencers.
  vip_chi_sequencer #(CHI_D_CFG_C) rni_sequencer;
  vip_chi_sequencer #(CHI_D_CFG_C) snf_sequencer;
  // HN-I requester sequencers (port 0 and port 1).
  vip_chi_sequencer #(CHI_D_CFG_C) hrni0_sequencer;
  vip_chi_sequencer #(CHI_D_CFG_C) hrni1_sequencer;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent);
    super.new(name, parent);
  endfunction

endclass
