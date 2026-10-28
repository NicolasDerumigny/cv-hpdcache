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
 *
 *
 *  Authors       : Nicolas Derumigny
 *  Creation Date : October, 2026
 *  Description   : HPDcache Pinned Region Writeback Controller
 *  History       :
 *
 *
 *  When the pinned region registers are modified, this controller walks the
 *  whole cache directory and writes back to memory, then invalidates, every
 *  valid cacheline which is dirty, belongs to the new region and is not marked
 *  pinned yet, i.e. the cachelines which should have been pinned when they were
 *  dirtied. The activated region therefore holds no cacheline dirtied before its
 *  activation. The pinned bit of the other valid cachelines is aligned with the
 *  new region, while the cachelines already marked pinned are left untouched: a
 *  pinned cacheline must never be evicted, and a dirty pinned cacheline has been
 *  dirtied after the activation which wrote it back.
 *
 *  The controller is the lowest priority user of the cache directory: it takes
 *  it one entry at a time, only when the pipeline and the other processes are
 *  idle (pipe_idle_i), and yields to a request waiting for the pipeline up to
 *  YIELD_MAX cycles, so the cache keeps executing requests during a walk. The
 *  processes accessing the directory out of the pipeline have priority in the
 *  directory multiplexer: when one of them preempts an access (dir_in_use_i),
 *  the controller reads that entry again.
 *
 *  Reading an entry and updating it are atomic: the controller owns the cache
 *  directory (writeback_busy_o) during those two cycles and during the cycle
 *  granting them, as they share the registered way of the last directory read.
 *  It also owns the cache while the flush controller has a cacheline left to
 *  read: that read of the data array is unhandshaked, shares its address port
 *  with the pipeline, and reads a way the invalidation has just freed. This is
 *  the exclusion the CMO controller enjoys as well.
 *
 *  One writeback request is issued at a time. Only the valid, pinned and dirty
 *  fields of an entry are modified: wback and fetch are rewritten unchanged.
 *  writeback_done_o is pulsed when the walk and all its writebacks are complete.
 */
`include "hpdcache_pinning.svh"

module hpdcache_pinned_writeback
    // Package imports
    // {{{
import hpdcache_pkg::*;
    // }}}

    // Parameters
    // {{{
#(
    parameter hpdcache_cfg_t HPDcacheCfg = '0,

    parameter type hpdcache_nline_t = logic,
    parameter type hpdcache_tag_t = logic,
    parameter type hpdcache_set_t = logic,
    parameter type hpdcache_way_vector_t = logic,

    //  Cycles the walk yields the cache directory to a request waiting for the
    //  pipeline, so that a continuously busy cache does not starve the walk
    parameter int unsigned YIELD_MAX = 8
)
    // }}}

    // Ports
    // {{{
(
    input  logic                  clk_i,
    input  logic                  rst_ni,

    //      Global control signals
    //      {{{
    //      Cache directory owned by the controller: the cycles accessing it,
    //      the cycle granting them, and the writeback of an invalidated
    //      cacheline. No new pipeline request is granted while asserted.
    output logic                  writeback_busy_o,
    output logic                  writeback_done_o,
    //      }}}

    //      Cache pipeline access control
    //      {{{
    //      The cache directory is free: the pipeline is empty and no other
    //      process accesses it, nor will in the next two cycles
    input  logic                  pipe_idle_i,
    //      A request is waiting to enter the cache pipeline
    input  logic                  pipe_req_pending_i,
    //      Another process accesses the cache directory this cycle: it has
    //      priority in the directory multiplexer, so the access the controller
    //      asks for is preempted and the entry is read again
    input  logic                  dir_in_use_i,
    //      }}}

    //      Writeback trigger
    //      {{{
    input  logic                  writeback_start_i,
    //      }}}

    //      Pinned region (cacheline granularity)
    //      {{{
    input  hpdcache_nline_t       csr_pinned_line_addr_start_i,
    input  hpdcache_nline_t       csr_pinned_line_addr_end_i,
    //      }}}

    //      Cache directory interface
    //      {{{
    output logic                  dir_check_entry_o,
    output hpdcache_set_t         dir_check_entry_set_o,
    output hpdcache_way_vector_t  dir_check_entry_way_o,
    input  logic                  dir_check_entry_valid_i,
    input  logic                  dir_check_entry_pinned_i,
    input  logic                  dir_check_entry_dirty_i,
    input  logic                  dir_check_entry_wback_i,
    input  logic                  dir_check_entry_fetch_i,
    input  hpdcache_tag_t         dir_check_entry_tag_i,

    output logic                  dir_updt_o,
    output hpdcache_set_t         dir_updt_set_o,
    output hpdcache_way_vector_t  dir_updt_way_o,
    output hpdcache_tag_t         dir_updt_tag_o,
    output logic                  dir_updt_valid_o,
    output logic                  dir_updt_pinned_o,
    output logic                  dir_updt_wback_o,
    output logic                  dir_updt_dirty_o,
    output logic                  dir_updt_fetch_o,
    //      }}}

    //      Flush controller interface
    //      {{{
    input  logic                  flush_empty_i,
    output logic                  flush_alloc_req_o,
    input  logic                  flush_alloc_grant_i,
    output hpdcache_nline_t       flush_alloc_nline_o,
    output hpdcache_way_vector_t  flush_alloc_way_o
    //      }}}
);
    //  }}}

    //  Definition of constants and types
    //  {{{
    typedef enum {
        WB_IDLE = 0,
        WB_ARBITRATE,
        WB_CHECK,
        WB_UPDATE,
        WB_FLUSH_WAIT,
        WB_WAIT
    } hpdcache_wb_fsm_t;

    typedef struct packed {
        hpdcache_nline_t      nline;
        hpdcache_way_vector_t way;
    } wb_flush_req_t;

    //  Width of the yield counter
    localparam int unsigned YIELD_WIDTH = $clog2(YIELD_MAX + 2);
    //  }}}

    //  Definition of internal signals and registers
    //  {{{
    hpdcache_wb_fsm_t   wb_fsm_q, wb_fsm_d;
    hpdcache_set_t      wb_set_q, wb_set_d;
    hpdcache_way_vector_t wb_way_q, wb_way_d;

    logic               wb_set_last;
    logic               wb_way_last;
    logic               wb_last_entry;

    //  A walk is on-going: triggered by the last modification of the pinned
    //  region, not yet complete
    logic               wb_walk_active;

    //  Granted the directory: the next state reads an entry
    logic               wb_next_check;
    //  The controller owns the cache directory: it is reading an entry, or
    //  evaluating the one it read during the previous cycle
    logic               wb_dir_own;
    //  The controller may take the cache directory
    logic               wb_pipe_free;
    //  The entry being evaluated was preempted: its value cannot be trusted
    logic               wb_check_stolen_q, wb_check_stolen_d;
    //  The entry read during the previous cycle may be updated
    logic               wb_valid_entry;

    //  Cycles the walk has been waiting for the cache directory
    logic [YIELD_WIDTH-1:0] wb_yield_q, wb_yield_d;
    logic               wb_yield_max;

    //  A cacheline the walk invalidated awaits its turn in the flush controller
    logic               wb_flush_own_pending;
    //  A cacheline the walk, or the CMO controller, invalidated is being read
    //  by the flush controller
    logic               wb_flush_pending;

    logic               wb_entry_pinned;
    logic               wb_need_writeback;
    logic               wb_need_updt;
    logic               wb_can_advance;

    logic               wb_fifo_w;
    logic               wb_fifo_wok;
    logic               wb_fifo_rok;
    wb_flush_req_t      wb_fifo_wdata;
    wb_flush_req_t      wb_fifo_rdata;

    logic               wb_start_pending_q, wb_start_pending_d;
    logic               wb_relaunch;
    //  }}}

    //  Global control signals
    //  {{{
    //  The controller owns the cache while it accesses the directory, and while
    //  a cacheline it invalidated has not been written back: the unhandshaked
    //  read the flush controller performs on the data array shares its address
    //  port with the pipeline, and reads a way the invalidation has just freed.
    //  The cachelines the CMO controller invalidated are covered as well, since
    //  the same flush controller reads them, but they do not disturb the walk:
    //  they do not involve the cache directory.
    assign wb_flush_own_pending = (wb_fsm_q == WB_FLUSH_WAIT) | wb_fifo_rok;

    assign wb_flush_pending = wb_walk_active
                            & (wb_flush_own_pending | ~flush_empty_i);

    //  Reading an entry and evaluating the entry read during the previous cycle
    //  are the two cycles during which the controller owns the cache directory
    assign wb_dir_own = (wb_fsm_q == WB_CHECK) | (wb_fsm_q == WB_UPDATE);

    assign writeback_busy_o = wb_next_check | wb_dir_own | wb_flush_pending;

    assign wb_walk_active = (wb_fsm_q != WB_IDLE);

    //  The controller yields the cache directory to a request waiting for the
    //  pipeline, but not for more than YIELD_MAX cycles: a continuously busy
    //  cache must not prevent the walk from completing
    assign wb_yield_max = (wb_yield_q == YIELD_WIDTH'(YIELD_MAX));

    assign wb_pipe_free = pipe_idle_i & (~pipe_req_pending_i | wb_yield_max);

    assign wb_set_last = (wb_set_q == hpdcache_set_t'(HPDcacheCfg.u.sets - 1));
    assign wb_way_last = wb_way_q[HPDcacheCfg.u.ways - 1];
    assign wb_last_entry = wb_set_last & wb_way_last;
    //  }}}

    //  Writeback FSM
    //  {{{
    always_comb
    begin : wb_fsm_comb
        wb_fsm_d = wb_fsm_q;
        wb_set_d = wb_set_q;
        wb_way_d = wb_way_q;

        writeback_done_o = 1'b0;
        wb_next_check    = 1'b0;
        wb_check_stolen_d = 1'b0;

        //  A trigger arriving during a walk is not lost: the walk is relaunched
        //  to take the last value of the region registers into account
        wb_start_pending_d = wb_start_pending_q
                           | (writeback_start_i & wb_walk_active);
        wb_relaunch = (wb_fsm_q == WB_WAIT) & ~wb_fifo_rok & flush_empty_i
                    & (wb_start_pending_q | writeback_start_i);
        if (wb_relaunch) begin
            wb_start_pending_d = 1'b0;
        end

        dir_check_entry_o     = 1'b0;
        dir_check_entry_set_o = wb_set_q;
        dir_check_entry_way_o = wb_way_q;

        dir_updt_o        = 1'b0;
        dir_updt_set_o    = wb_set_q;
        dir_updt_way_o    = wb_way_q;
        dir_updt_tag_o    = dir_check_entry_tag_i;
        dir_updt_valid_o  = 1'b0;
        dir_updt_pinned_o = 1'b0;
        dir_updt_wback_o  = 1'b0;
        dir_updt_dirty_o  = 1'b0;
        dir_updt_fetch_o  = 1'b0;

        //  Pinning state of the entry read during the previous cycle,
        //  evaluated with the new pinned region
        wb_entry_pinned = `HPDCACHE_LINE_ADDR_IS_PINNED(
                {dir_check_entry_tag_i, wb_set_q},
                csr_pinned_line_addr_start_i,
                csr_pinned_line_addr_end_i);

        //  The entry read during the previous cycle may be used only if no other
        //  process has taken the directory since: it is read again otherwise
        wb_valid_entry = ~wb_check_stolen_q & ~dir_in_use_i;

        //  The cachelines to write back are the ones which should have been
        //  pinned when they were dirtied. A cacheline already marked pinned is
        //  left untouched: it has been dirtied while pinned, and a pinned
        //  cacheline must never be evicted. As the pipeline allocates the
        //  cachelines of the region pinned, the set of written back cachelines
        //  depends only on the cache when the registers were written, not on how
        //  long the walk takes.
        wb_need_writeback = wb_valid_entry
                          & dir_check_entry_valid_i
                          & dir_check_entry_dirty_i
                          & wb_entry_pinned
                          & ~dir_check_entry_pinned_i;

        //  The directory entry is refreshed only if its state changes
        wb_need_updt = wb_valid_entry
                     & dir_check_entry_valid_i
                     & (wb_entry_pinned != dir_check_entry_pinned_i);

        //  The FIFO write strobe must not depend on its own readiness to avoid
        //  a combinational loop: it is asserted whenever an entry must be
        //  written back, and the FSM only advances when the FIFO can accept it
        wb_can_advance = ~wb_need_writeback | wb_fifo_wok;

        wb_fifo_w = (wb_fsm_q == WB_UPDATE) ? wb_need_writeback : 1'b0;

        unique case (wb_fsm_q)
            WB_IDLE: begin
                if (writeback_start_i) begin
                    wb_set_d = '0;
                    wb_way_d = hpdcache_way_vector_t'(1);
                    wb_fsm_d = WB_ARBITRATE;
                end
            end

            //  Wait for the cache directory to be free, then take it for the
            //  two cycles needed to access a directory entry
            WB_ARBITRATE: begin
                if (wb_pipe_free) begin
                    wb_fsm_d = WB_CHECK;
                    wb_next_check = 1'b1;
                end
            end

            //  Read one directory entry: the result is available next cycle and
            //  the directory stays owned until the entry has been evaluated
            WB_CHECK: begin
                dir_check_entry_o = 1'b1;
                wb_fsm_d = WB_UPDATE;
                //  Another process has priority: the entry read is not the one
                //  the controller requested
                if (dir_in_use_i) begin
                    wb_check_stolen_d = 1'b1;
                end
            end

            //  Evaluate the entry read during the previous cycle
            WB_UPDATE: begin
                if (!wb_valid_entry) begin
                    //  The directory has been taken while reading this entry:
                    //  release it and read that entry again later
                    wb_fsm_d = WB_ARBITRATE;
                end else if (wb_can_advance) begin
                    //  wb_need_writeback implies wb_need_updt, so the OR is redundant
                    dir_updt_o        = wb_need_updt;
                    //  A written back cacheline is invalidated: the next access
                    //  to the region will allocate it again, pinned
                    dir_updt_valid_o  = dir_check_entry_valid_i & ~wb_need_writeback;
                    //  An invalidated entry must be written unpinned: a way which
                    //  is invalid and pinned is selectable by no victim policy
                    dir_updt_pinned_o = wb_entry_pinned & ~wb_need_writeback;
                    //  wback and fetch are not modified: rewritten as read
                    dir_updt_wback_o  = dir_check_entry_wback_i;
                    dir_updt_dirty_o  = wb_need_writeback ? 1'b0 : dir_check_entry_dirty_i;
                    dir_updt_fetch_o  = dir_check_entry_fetch_i;

                    wb_set_d = wb_way_last ? (wb_set_last ? '0 : wb_set_q + 1) : wb_set_q;
                    if (HPDcacheCfg.u.ways > 1) begin
                        wb_way_d = wb_way_last ?
                                hpdcache_way_vector_t'(1) :
                                {wb_way_q[0 +: HPDcacheCfg.u.ways-1], 1'b0};
                    end else begin
                        wb_way_d = hpdcache_way_vector_t'(1);
                    end

                    //  Release the directory: the walk goes on from the
                    //  arbitration state. Passing through it for every entry keeps
                    //  the signals deciding who takes the directory registered
                    wb_fsm_d = wb_last_entry ? WB_WAIT : WB_FLUSH_WAIT;
                end else begin
                    //  The writeback request cannot be enqueued: release the
                    //  directory and evaluate this entry again later
                    wb_fsm_d = WB_ARBITRATE;
                end
            end

            //  Wait until the cacheline just invalidated has been read by the
            //  flush controller: the controller owns the cache during that time,
            //  so that way cannot be reallocated nor its read preempted
            WB_FLUSH_WAIT: begin
                if (!wb_fifo_rok && flush_empty_i) begin
                    wb_fsm_d = WB_ARBITRATE;
                end
            end

            //  Wait until all the writeback requests have been acknowledged
            WB_WAIT: begin
                if (wb_relaunch) begin
                    //  A new trigger occurred while walking: walk the whole
                    //  directory again with the new pinned region registers
                    wb_set_d = '0;
                    wb_way_d = hpdcache_way_vector_t'(1);
                    wb_fsm_d = WB_ARBITRATE;
                end else if (!wb_fifo_rok && flush_empty_i) begin
                    writeback_done_o = 1'b1;
                    wb_fsm_d = WB_IDLE;
                end
            end

            default: begin
            end
        endcase
    end
    //  }}}

    //  Writeback requests to the flush controller
    //  {{{
    assign wb_fifo_wdata = '{
        nline: {dir_check_entry_tag_i, wb_set_q},
        way  : wb_way_q
    };

    hpdcache_fifo_reg #(
        .FIFO_DEPTH  (2),
        .FEEDTHROUGH (1'b1),
        .fifo_data_t (wb_flush_req_t)
    ) wb_flush_req_fifo_i(
        .clk_i,
        .rst_ni,
        .w_i     (wb_fifo_w),
        .wok_o   (wb_fifo_wok),
        .wdata_i (wb_fifo_wdata),
        .r_i     (flush_alloc_grant_i),
        .rok_o   (wb_fifo_rok),
        .rdata_o (wb_fifo_rdata)
    );

    assign flush_alloc_req_o = wb_fifo_rok;
    assign flush_alloc_nline_o = wb_fifo_rdata.nline;
    assign flush_alloc_way_o   = wb_fifo_rdata.way;
    //  }}}

    //  Yield counter: number of cycles the walk has been waiting for the cache
    //  directory while a request was waiting for the pipeline. Once YIELD_MAX is
    //  reached, the walk does not yield anymore, so that a continuously busy
    //  cache cannot starve it.
    //  {{{
    always_comb
    begin : wb_yield_comb
        if (wb_fsm_q == WB_ARBITRATE) begin
            if (wb_pipe_free) begin
                wb_yield_d = '0;
            end else if (!wb_yield_max) begin
                wb_yield_d = wb_yield_q + 1;
            end else begin
                wb_yield_d = wb_yield_q;
            end
        end else begin
            wb_yield_d = '0;
        end
    end
    //  }}}

    //  Internal state
    //  {{{
    always_ff @(posedge clk_i or negedge rst_ni)
    begin : wb_fsm_ff
        if (!rst_ni) begin
            wb_fsm_q <= WB_IDLE;
            wb_set_q <= '0;
            wb_way_q <= '0;
            wb_start_pending_q <= 1'b0;
            wb_check_stolen_q <= 1'b0;
            wb_yield_q <= '0;
        end else begin
            wb_fsm_q <= wb_fsm_d;
            wb_set_q <= wb_set_d;
            wb_way_q <= wb_way_d;
            wb_start_pending_q <= wb_start_pending_d;
            wb_check_stolen_q <= wb_check_stolen_d;
            wb_yield_q <= wb_yield_d;
        end
    end
    //  }}}

    //  Assertions
    //  {{{
`ifndef HPDCACHE_ASSERT_OFF
    //  The entry is evaluated again later if its writeback request cannot be
    //  enqueued: the controller releases the cache directory in that case
    assert property (@(posedge clk_i) disable iff (rst_ni !== 1'b1)
            (wb_fsm_q == WB_UPDATE) && wb_need_writeback && !wb_fifo_wok
            |-> (wb_fsm_d == WB_ARBITRATE)) else
            $error("pinned_writeback: entry updated though its writeback was not accepted");

    assert property (@(posedge clk_i) disable iff (rst_ni !== 1'b1)
            (wb_fsm_q == WB_UPDATE) && !wb_valid_entry
            |-> (wb_fsm_d == WB_ARBITRATE && !dir_updt_o && !wb_fifo_w
                 && wb_set_d == wb_set_q && wb_way_d == wb_way_q)) else
            $error("pinned_writeback: entry updated or skipped after preemption");

    //  Reading an entry and updating it are atomic: the controller owns the
    //  cache directory during those two cycles
    assert property (@(posedge clk_i) disable iff (rst_ni !== 1'b1)
            dir_check_entry_o |-> (writeback_busy_o && (wb_fsm_q == WB_CHECK))) else
            $error("pinned_writeback: directory entry read while the directory is not owned");

    assert property (@(posedge clk_i) disable iff (rst_ni !== 1'b1)
            dir_updt_o |-> (writeback_busy_o && (wb_fsm_q == WB_UPDATE)
                            && $past(dir_check_entry_o))) else
            $error("pinned_writeback: directory entry updated without a preceding read");

    assert property (@(posedge clk_i) disable iff (rst_ni !== 1'b1)
            (dir_updt_o && !dir_updt_valid_o) |-> (wb_entry_pinned
                                                   && !dir_check_entry_pinned_i)) else
            $error("pinned_writeback: pinned cacheline evicted by the walk");

    assert property (@(posedge clk_i) disable iff (rst_ni !== 1'b1)
            dir_updt_o |-> (dir_updt_pinned_o
                            == (wb_entry_pinned & dir_updt_valid_o))) else
            $error("pinned_writeback: pinned bit written does not match the region and validity");

    assert property (@(posedge clk_i) disable iff (rst_ni !== 1'b1)
            wb_next_check |-> pipe_idle_i) else
            $error("pinned_writeback: cache directory taken while the pipeline is not idle");

    assert property (@(posedge clk_i) disable iff (rst_ni !== 1'b1)
            (wb_fsm_q == WB_ARBITRATE) && pipe_idle_i && wb_yield_max
            |-> wb_pipe_free) else
            $error("pinned_writeback: walk starved by the cache pipeline");

    assert property (@(posedge clk_i) disable iff (rst_ni !== 1'b1)
            wb_flush_pending |-> writeback_busy_o) else
            $error("pinned_writeback: cache not owned while a cacheline is being written back");

    assert property (@(posedge clk_i) disable iff (rst_ni !== 1'b1)
            (wb_fsm_q == WB_FLUSH_WAIT) |-> (writeback_busy_o && !dir_check_entry_o
                                             && !dir_updt_o)) else
            $error("pinned_writeback: directory accessed during a writeback");

    assert property (@(posedge clk_i) disable iff (rst_ni !== 1'b1)
            (wb_fsm_q == WB_FLUSH_WAIT) && (wb_fsm_d != WB_FLUSH_WAIT)
            |-> (!wb_fifo_rok && flush_empty_i)) else
            $error("pinned_writeback: walk resumed before the cacheline was written back");

    assert property (@(posedge clk_i) disable iff (rst_ni !== 1'b1)
            wb_fifo_w |-> ((wb_fsm_q == WB_UPDATE) && wb_need_writeback
                           && ((wb_fsm_d == WB_FLUSH_WAIT)
                               || (wb_fsm_d == WB_WAIT)))) else
            $error("pinned_writeback: writeback request enqueued without waiting for it");

    //  A trigger arriving during a walk must launch a complementary walk before
    //  the completion is reported
    assert property (@(posedge clk_i) disable iff (rst_ni !== 1'b1)
            wb_walk_active && writeback_start_i && !wb_relaunch
            |-> (wb_start_pending_d == 1'b1)) else
            $error("pinned_writeback: writeback trigger lost");

    assert property (@(posedge clk_i) disable iff (rst_ni !== 1'b1)
            writeback_done_o |-> (wb_start_pending_q == 1'b0)) else
            $error("pinned_writeback: completion reported with a pending trigger");
`endif
    //  }}}
endmodule
// vim: ts=4 : sts=4 : sw=4 : et : tw=100 : spell : spelllang=en : fdm=marker
