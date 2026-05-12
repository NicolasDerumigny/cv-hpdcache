/*
 *  Copyright 2026 Inria
 *
 *  SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 *  Licensed under the Solderpad Hardware License v 2.1 (the “License”); you
 *  may not use this file except in compliance with the License, or, at your
 *  option, the Apache License version 2.0. You may obtain a copy of the
 *  License at
 *
 *  https://solderpad.org/licenses/SHL-2.1/
 *
 *  Unless required by applicable law or agreed to in writing, any work
 *  distributed under the License is distributed on an “AS IS” BASIS, WITHOUT
 *  WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 *  License for the specific language governing permissions and limitations
 *  under the License.
 */
/*
 *  Authors       : Nicolas Derumigny
 *  Creation Date : April, 2026
 *  Description   : HPDcache Control Registers
 *  History       :
 */
module hpdcache_csr
    // Package imports
    // {{{
import hpdcache_pkg::*;
    // }}}

    // Parameters
    // {{{
#(
    parameter hpdcache_cfg_t HPDcacheCfg = '0,

    parameter type hpdcache_rsp_t = logic,
    parameter type hpdcache_req_addr_t = logic,
    parameter type hpdcache_req_tid_t = logic,
    parameter type hpdcache_req_sid_t = logic,
    parameter type hpdcache_req_data_t = logic
)
    // }}}

    // Ports
    // {{
(
    input logic clk_i,
    input logic rst_ni,

    //     Request interface
    input  logic                  req_valid_i,
    output logic                  req_ready_o,
    input  logic                  req_is_load_i,
    input  logic                  req_is_store_i,
    input  hpdcache_req_addr_t    req_addr_i, // Assumed to be already shifted
    input  hpdcache_req_data_t    req_wdata_i,
    input  hpdcache_req_sid_t     req_sid_i,
    input  hpdcache_req_tid_t     req_tid_i,

    //     Core response interface
    input  logic                  rsp_ready_i,
    output logic                  rsp_valid_o,
    output hpdcache_rsp_t         rsp_o,

    //     CSR values
    //     Start of pinned address region (PA)
    output hpdcache_req_addr_t    csr_pinned_addr_start_o,
    //     Size of pinned address region
    output hpdcache_req_addr_t    csr_pinned_addr_size_o
);
    // }}}

    //  Definition of internal constants
    //  {{{
    typedef enum logic [11:0] {
        HPDCACHE_PINNED_AREA_START = 'h00,
        HPDCACHE_PINNED_AREA_SIZE  = 'h08
    } hpdcache_cfg_offset_e;
    //  }}}

    //  Definition of internal registers
    //  {{{
    hpdcache_req_addr_t csr_pinned_addr_start_q, csr_pinned_addr_start_d;
    hpdcache_req_addr_t csr_pinned_addr_size_q, csr_pinned_addr_size_d;
    logic               rsp_valid_q, rsp_valid_d;
    logic               stalling;
    hpdcache_rsp_t      rsp_q, rsp_d;
    //  }}}

    //  Output logic
    //  {{{
    assign csr_pinned_addr_start_o = csr_pinned_addr_start_q;
    assign csr_pinned_addr_size_o  = csr_pinned_addr_size_q;

    assign rsp_valid_o             = rsp_valid_q;
    assign rsp_o                   = rsp_q;
    //  }}}

    //  Stalling logic
    //  {{{
    assign stalling = rsp_valid_o && ~rsp_ready_i;
    //  }}}

    //  Request logic
    //  {{{
    assign req_ready_o = !stalling;
    //  }}}

    // Main update process
    // {{{
    always_comb
    begin : main_process
        csr_pinned_addr_size_d  = csr_pinned_addr_size_q;
        csr_pinned_addr_start_d = csr_pinned_addr_start_q;

        rsp_valid_d = stalling ? rsp_valid_q : 1'b0;
        rsp_d.rdata = stalling ? rsp_q.rdata :   '0;
        rsp_d.error = stalling ? rsp_q.error : 1'b0;

        if (req_valid_i && !stalling) begin
            if (req_is_store_i) begin
                unique case (req_addr_i[11:0])
                    HPDCACHE_PINNED_AREA_START: begin
                        csr_pinned_addr_start_d = req_wdata_i;
                    end
                    HPDCACHE_PINNED_AREA_SIZE: begin
                        csr_pinned_addr_size_d = req_wdata_i;
                    end
                    default: begin
                        rsp_d.error = 'b1;
                    end
                endcase
            end else if (req_is_load_i) begin
                rsp_valid_d = 'b1;

                unique case (req_addr_i[11:0])
                    HPDCACHE_PINNED_AREA_START: begin
                        rsp_d.rdata = csr_pinned_addr_start_q;
                    end
                    HPDCACHE_PINNED_AREA_SIZE: begin
                        rsp_d.rdata = csr_pinned_addr_size_q;
                    end
                    default: begin
                        rsp_d.error = 'b1;
                    end
                endcase
            end
        end
    end

    //  Response handling
    //  {{
    assign rsp_d.sid   = req_sid_i;
    assign rsp_d.tid   = req_tid_i;
    assign rsp_d.aborted = 'b0;
    //  }}

    //  Register values
    //  {{{
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
            csr_pinned_addr_start_q <= '0;
            csr_pinned_addr_size_q  <= '0;
            rsp_valid_q             <= '0;
            rsp_q                   <= '0;
        end else begin
            csr_pinned_addr_start_q <= csr_pinned_addr_start_d;
            csr_pinned_addr_size_q  <= csr_pinned_addr_size_d;
            rsp_valid_q             <= rsp_valid_d;
            rsp_q                   <= rsp_d;
        end
    end
    //  }}}

endmodule

/// vim: sw=4 ts=4 et
