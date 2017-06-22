// Author: Florian Zaruba, ETH Zurich
// Date: 20.04.2017
// Description: PC generation stage
//
// Copyright (C) 2017 ETH Zurich, University of Bologna
// All rights reserved.
//
// This code is under development and not yet released to the public.
// Until it is released, the code is under the copyright of ETH Zurich and
// the University of Bologna, and may contain confidential and/or unpublished
// work. Any reuse/redistribution is strictly forbidden without written
// permission from ETH Zurich.
//
// Bug fixes and contributions will eventually be released under the
// SolderPad open hardware license in the context of the PULP platform
// (http://www.pulp-platform.org), under the copyright of ETH Zurich and the
// University of Bologna.
//

import ariane_pkg::*;

module pcgen (
    input  logic             clk_i,              // Clock
    input  logic             rst_ni,             // Asynchronous reset active low
    // control signals
    input  logic             flush_i,            // flush request for PCGEN
    input  logic             flush_bp_i,         // flush branch prediction
    input  logic             fetch_enable_i,
    input  logic             if_ready_i,
    input  branchpredict     resolved_branch_i,  // from controller signaling a branch_predict -> update BTB
    // to IF
    output logic [63:0]      fetch_address_o,    // new PC (address because we do not distinguish instructions)
    output logic             fetch_valid_o,      // the PC (address) is valid
    output branchpredict_sbe branch_predict_o,   // pass on the information if this is speculative
    // global input
    input  logic [63:0]      boot_addr_i,
    // from commit
    input  logic [63:0]      pc_commit_i,        // PC of instruction in commit stage
    // CSR input
    input  logic [63:0]      epc_i,              // exception PC which we need to return to
    input  logic             eret_i,             // return from exception
    input  logic [63:0]      trap_vector_base_i, // base of trap vector
    input  exception         ex_i                // exception in - from commit
);

    logic [63:0]      npc_n, npc_q;
    branchpredict_sbe branch_predict_btb;

    assign fetch_address_o = npc_q;

    btb #(
        .NR_ENTRIES(64),
        .BITS_SATURATION_COUNTER(2)
    )
    btb_i
    (
        // Use the PC from last cycle to perform branch lookup for the current cycle
        .flush_i                 ( flush_bp_i              ),
        .vpc_i                   ( npc_q                   ),
        .branch_predict_i        ( resolved_branch_i       ), // update port
        .branch_predict_o        ( branch_predict_btb      ), // read port
        .*
    );
    // -------------------
    // Next PC
    // -------------------
    // next PC (NPC) can come from:
    // 0. Default assignment
    // 1. Branch Predict taken
    // 2. Debug
    // 3. Control flow change request
    // 4. Exception
    // 5. Return from exception
    // 6. Pipeline Flush because of CSR side effects
    always_comb begin : npc_select
        branch_predict_o = branch_predict_btb;
        fetch_valid_o    = 1'b1;

        // -------------------------------
        // 0. Default assignment
        // -------------------------------
        // default is a consecutive PC
        if (if_ready_i && fetch_enable_i)
            npc_n = {npc_q[63:2], 2'b0}  + 64'h4;
        else // or keep the PC stable if IF is not ready
            npc_n =  npc_q;
        // we only need to stall the consecutive and predicted case since in any other case we will flush at least
        // the front-end which means that the IF stage will always be ready to accept a new request

        // -------------------------------
        // 1. Predict taken
        // -------------------------------
        // only predict if the IF stage is ready, otherwise we might take the predicted PC away which will end in a endless loop
        // also check if we fetched on a half word (npc_q[1] == 1), it might be the case that we need the next 16 byte of the following instruction
        // prediction could potentially prevent us from getting them
        if (if_ready_i && branch_predict_btb.valid && branch_predict_btb.predict_taken && !npc_q[1]) begin
            npc_n = branch_predict_btb.predict_address;
        end
        // -------------------------------
        // 2. Debug
        // -------------------------------

        // -------------------------------
        // 3. Control flow change request
        // -------------------------------
        if (resolved_branch_i.is_mispredict) begin
            // we already got the correct target address
            npc_n = resolved_branch_i.target_address;
        end

        // -------------------------------
        // 4. Exception
        // -------------------------------
        if (ex_i.valid) begin
            npc_n                  = trap_vector_base_i;
            branch_predict_o.valid = 1'b0;
        end

        // -------------------------------
        // 5. Return from exception
        // -------------------------------
        if (eret_i) begin
            npc_n = epc_i;
        end

        // -----------------------------------------------
        // 6. Pipeline Flush because of CSR side effects
        // -----------------------------------------------
        // On a pipeline flush start fetching from the next address
        // of the instruction in the commit stage
        if (flush_i) begin
            // we came here from a flush request of a CSR instruction,
            // as CSR instructions do not exist in a compressed form
            // we can unconditionally do PC + 4 here
            npc_n = pc_commit_i + 64'h4;
        end

        // fetch enable
        if (!fetch_enable_i) begin
            fetch_valid_o = 1'b0;
        end
    end
    // -------------------
    // Sequential Process
    // -------------------
    // PCGEN -> IF Pipeline Stage
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if(~rst_ni) begin
           npc_q       <= boot_addr_i;
        end else begin
           npc_q       <= npc_n;
        end
    end

endmodule
