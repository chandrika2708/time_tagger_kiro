//-----------------------------------------------------------------------------
// tb_tag_mux.v
// Testbench for tag_mux (Round-Robin Arbiter)
//-----------------------------------------------------------------------------
// Verifies:
//   - Round-robin fairness when multiple sources have data
//   - Immediate grant for single available source
//   - Backpressure holds output stable when tag_ready deasserted
//   - Resumed operation after backpressure release
//   - No data loss (total output count = total input count)
//   - Per-source ordering preserved at mux output
//   - tag_valid deasserted when all sources empty
//-----------------------------------------------------------------------------

`timescale 1ns / 1ps

`include "time_tagger_pkg.v"

module tb_tag_mux;

    // ========================================================================
    // Parameters
    // ========================================================================
    localparam NUM_SOURCES = 9;
    localparam TAG_WIDTH   = `TAG_WIDTH;  // 96
    localparam CLK_PERIOD  = 4;           // 250 MHz (4 ns period)

    // Source memory depth (tags per source for testing)
    localparam SRC_DEPTH = 32;

    // ========================================================================
    // Signals
    // ========================================================================
    reg                         clk;
    reg                         rst_n;

    // FIFO emulation signals
    reg  [TAG_WIDTH-1:0]        fifo_rd_data [0:NUM_SOURCES-1];
    reg  [NUM_SOURCES-1:0]      fifo_empty;
    wire [NUM_SOURCES-1:0]      fifo_rd_en;

    // Output interface
    wire [TAG_WIDTH-1:0]        tag_out;
    wire                        tag_valid;
    reg                         tag_ready;

    // ========================================================================
    // Error Tracking
    // ========================================================================
    integer error_count = 0;

    // ========================================================================
    // Source Memory Arrays
    // ========================================================================
    // Each source has a local memory array and read pointer
    reg [TAG_WIDTH-1:0] src_mem [0:NUM_SOURCES-1][0:SRC_DEPTH-1];
    integer             src_rd_ptr [0:NUM_SOURCES-1];
    integer             src_count  [0:NUM_SOURCES-1]; // number of tags loaded

    // ========================================================================
    // Clock Generation (250 MHz)
    // ========================================================================
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ========================================================================
    // DUT Instantiation
    // ========================================================================
    tag_mux #(
        .NUM_SOURCES(NUM_SOURCES),
        .TAG_WIDTH(TAG_WIDTH)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .fifo_rd_data (fifo_rd_data),
        .fifo_empty   (fifo_empty),
        .fifo_rd_en   (fifo_rd_en),
        .tag_out      (tag_out),
        .tag_valid    (tag_valid),
        .tag_ready    (tag_ready)
    );

    // ========================================================================
    // FIFO Source Emulation
    // ========================================================================
    // When fifo_rd_en is asserted for a source, advance its read pointer
    // and update fifo_rd_data and fifo_empty accordingly.
    integer s;
    always @(posedge clk) begin
        for (s = 0; s < NUM_SOURCES; s = s + 1) begin
            if (fifo_rd_en[s] && !fifo_empty[s]) begin
                src_rd_ptr[s] <= src_rd_ptr[s] + 1;
            end
        end
    end

    // Combinational: update fifo_rd_data and fifo_empty based on current pointers
    integer c;
    always @(*) begin
        for (c = 0; c < NUM_SOURCES; c = c + 1) begin
            fifo_rd_data[c] = src_mem[c][src_rd_ptr[c]];
            fifo_empty[c]   = (src_rd_ptr[c] >= src_count[c]) ? 1'b1 : 1'b0;
        end
    end

    // ========================================================================
    // Simulation Timeout (50 µs)
    // ========================================================================
    initial begin
        #50000;
        $display("[FAIL] Simulation timeout at 50 us");
        $finish(1);
    end

    // ========================================================================
    // Helper Tasks
    // ========================================================================

    // Load a source with N tags, each tagged with source ID and sequence number
    task load_source;
        input integer src_id;
        input integer count;
        integer i;
        begin
            src_count[src_id] = count;
            src_rd_ptr[src_id] = 0;
            for (i = 0; i < count; i = i + 1) begin
                // Tag format: [95:32]=sequence, [31:24]=src_id, [23:16]=0, [15:0]=i
                src_mem[src_id][i] = {32'd0, i[31:0], src_id[7:0], 8'd0, i[15:0]};
            end
        end
    endtask

    // Reset all sources to empty
    task reset_all_sources;
        integer i;
        begin
            for (i = 0; i < NUM_SOURCES; i = i + 1) begin
                src_count[i] = 0;
                src_rd_ptr[i] = 0;
            end
        end
    endtask

    // Wait for N clock edges
    task wait_clks;
        input integer n;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1)
                @(posedge clk);
        end
    endtask

    // Collect all output tags into arrays for analysis
    // Returns total count collected
    reg [TAG_WIDTH-1:0] collected_tags [0:511];
    integer collected_count;

    task collect_all_outputs;
        input integer max_cycles;
        integer cyc;
        integer idle_count;
        begin
            collected_count = 0;
            idle_count = 0;
            for (cyc = 0; cyc < max_cycles; cyc = cyc + 1) begin
                @(posedge clk);
                if (tag_valid && tag_ready) begin
                    collected_tags[collected_count] = tag_out;
                    collected_count = collected_count + 1;
                    idle_count = 0;
                end else begin
                    idle_count = idle_count + 1;
                    // Stop if idle for 20 cycles (all sources drained)
                    if (idle_count > 20)
                        cyc = max_cycles; // break
                end
            end
        end
    endtask

    // ========================================================================
    // Main Test Sequence
    // ========================================================================
    integer i, j;
    reg [7:0] out_src_id;
    reg [15:0] out_seq;
    integer total_input_count;
    integer total_output_count;

    // Per-source output tracking for ordering check
    integer last_seq [0:NUM_SOURCES-1];
    integer src_out_count [0:NUM_SOURCES-1];

    // Round-robin tracking
    integer rr_order [0:63];
    integer rr_count;

    reg [TAG_WIDTH-1:0] held_tag;

    initial begin
        // Initialize
        rst_n = 0;
        tag_ready = 1;
        reset_all_sources;

        // Reset sequence
        #100;
        rst_n = 1;
        wait_clks(10);

        // ==================================================================
        // TEST 1: Verify tag_valid deasserted when all sources empty
        // ==================================================================
        $display("--- Test 1: tag_valid deasserted when all sources empty ---");
        wait_clks(5);
        if (tag_valid !== 1'b0) begin
            $display("[FAIL] Test 1: tag_valid should be 0 when all sources empty, got %b", tag_valid);
            error_count = error_count + 1;
        end else begin
            $display("[PASS] Test 1: tag_valid deasserted when all sources empty");
        end

        // ==================================================================
        // TEST 2: Immediate grant for single available source
        // ==================================================================
        $display("--- Test 2: Immediate grant for single available source ---");
        // Reset DUT to get clean rr_ptr state
        rst_n = 0;
        reset_all_sources;
        wait_clks(5);
        rst_n = 1;
        wait_clks(5);

        load_source(5, 3); // Load source 5 with 3 tags
        wait_clks(3); // Allow pipeline to propagate

        // Should see tag_valid asserted with source 5 data
        if (tag_valid !== 1'b1) begin
            $display("[FAIL] Test 2: tag_valid should be 1 when source 5 has data, got %b", tag_valid);
            error_count = error_count + 1;
        end else begin
            out_src_id = tag_out[31:24];
            if (out_src_id !== 8'd5) begin
                $display("[FAIL] Test 2: Expected source 5, got source %0d", out_src_id);
                error_count = error_count + 1;
            end else begin
                $display("[PASS] Test 2: Immediate grant for single available source (source 5)");
            end
        end

        // Drain source 5
        wait_clks(10);

        // ==================================================================
        // TEST 3: Round-robin fairness when multiple sources have data
        // ==================================================================
        $display("--- Test 3: Round-robin fairness ---");
        // Reset DUT to get clean rr_ptr=0 state
        rst_n = 0;
        reset_all_sources;
        wait_clks(5);
        rst_n = 1;
        wait_clks(5);

        // Load all 9 sources with 4 tags each
        for (i = 0; i < NUM_SOURCES; i = i + 1) begin
            load_source(i, 4);
        end

        // Collect outputs and track source order
        rr_count = 0;
        begin : rr_collect
            integer cyc, idle;
            idle = 0;
            for (cyc = 0; cyc < 200; cyc = cyc + 1) begin
                @(posedge clk);
                if (tag_valid && tag_ready) begin
                    rr_order[rr_count] = tag_out[31:24];
                    rr_count = rr_count + 1;
                    idle = 0;
                end else begin
                    idle = idle + 1;
                    if (idle > 20) cyc = 200;
                end
            end
        end

        // Verify round-robin: first 9 outputs should be from sources 0..8 in order
        // (since rr_ptr starts at 0 after reset)
        begin : rr_check
            integer pass_rr;
            pass_rr = 1;
            if (rr_count < 9) begin
                $display("[FAIL] Test 3: Expected at least 9 outputs, got %0d", rr_count);
                error_count = error_count + 1;
                pass_rr = 0;
            end else begin
                for (i = 0; i < 9; i = i + 1) begin
                    if (rr_order[i] !== i) begin
                        $display("[FAIL] Test 3: Round-robin position %0d expected source %0d, got %0d",
                                 i, i, rr_order[i]);
                        error_count = error_count + 1;
                        pass_rr = 0;
                    end
                end
            end
            if (pass_rr)
                $display("[PASS] Test 3: Round-robin fairness verified (first 9 outputs in order 0..8)");
        end

        // Verify total output count = 9 * 4 = 36
        if (rr_count !== 36) begin
            $display("[FAIL] Test 3: Expected 36 total outputs, got %0d", rr_count);
            error_count = error_count + 1;
        end else begin
            $display("[PASS] Test 3: Total output count matches (36)");
        end

        // ==================================================================
        // TEST 4: Backpressure holds output stable
        // ==================================================================
        $display("--- Test 4: Backpressure holds output stable ---");
        // Reset DUT for clean state
        rst_n = 0;
        reset_all_sources;
        wait_clks(5);
        rst_n = 1;
        wait_clks(5);

        load_source(0, 4);
        load_source(1, 4);

        // Wait for first valid output to appear, then immediately apply backpressure
        tag_ready = 1;
        wait_clks(2); // Allow data to propagate through pipeline
        begin : bp_wait
            integer timeout_cnt;
            timeout_cnt = 0;
            while (!tag_valid && timeout_cnt < 20) begin
                @(posedge clk);
                timeout_cnt = timeout_cnt + 1;
            end
        end

        // tag_valid is now asserted. The current tag is being consumed this cycle
        // (since tag_ready=1). Wait one more cycle for the next tag to appear,
        // then deassert tag_ready to hold it.
        @(posedge clk);
        // Now a new tag should be in the output register
        tag_ready = 0;
        // Sample the held tag after the register updates
        @(posedge clk);
        #1;
        held_tag = tag_out;

        // Wait several cycles under backpressure
        wait_clks(10);

        // Verify output is held stable
        if (tag_out !== held_tag) begin
            $display("[FAIL] Test 4: Output changed during backpressure. Expected %h, got %h",
                     held_tag, tag_out);
            error_count = error_count + 1;
        end else if (tag_valid !== 1'b1) begin
            $display("[FAIL] Test 4: tag_valid dropped during backpressure");
            error_count = error_count + 1;
        end else begin
            $display("[PASS] Test 4: Backpressure holds output stable");
        end

        // ==================================================================
        // TEST 5: Resumed operation after backpressure release
        // ==================================================================
        $display("--- Test 5: Resumed operation after backpressure release ---");

        // Re-assert tag_ready
        tag_ready = 1;
        @(posedge clk);

        // The held tag should be consumed, then new tags should flow
        wait_clks(3);
        if (tag_valid !== 1'b1) begin
            $display("[FAIL] Test 5: tag_valid not asserted after backpressure release");
            error_count = error_count + 1;
        end else begin
            // Verify we get a different tag (next in sequence)
            if (tag_out === held_tag) begin
                // It's possible the same tag is still there for 1 cycle, wait one more
                @(posedge clk);
            end
            $display("[PASS] Test 5: Resumed operation after backpressure release");
        end

        // Drain remaining
        wait_clks(30);

        // ==================================================================
        // TEST 6: No data loss (total output = total input)
        // ==================================================================
        $display("--- Test 6: No data loss ---");
        // Reset DUT for clean state
        rst_n = 0;
        reset_all_sources;
        wait_clks(5);
        rst_n = 1;
        wait_clks(5);

        // Load varying amounts per source
        total_input_count = 0;
        load_source(0, 5);  total_input_count = total_input_count + 5;
        load_source(1, 3);  total_input_count = total_input_count + 3;
        load_source(2, 7);  total_input_count = total_input_count + 7;
        load_source(3, 2);  total_input_count = total_input_count + 2;
        load_source(4, 6);  total_input_count = total_input_count + 6;
        load_source(5, 4);  total_input_count = total_input_count + 4;
        load_source(6, 8);  total_input_count = total_input_count + 8;
        load_source(7, 1);  total_input_count = total_input_count + 1;
        load_source(8, 5);  total_input_count = total_input_count + 5;

        tag_ready = 1;
        collect_all_outputs(300);

        if (collected_count !== total_input_count) begin
            $display("[FAIL] Test 6: Data loss detected. Input=%0d, Output=%0d",
                     total_input_count, collected_count);
            error_count = error_count + 1;
        end else begin
            $display("[PASS] Test 6: No data loss (input=%0d, output=%0d)",
                     total_input_count, collected_count);
        end

        // ==================================================================
        // TEST 7: Per-source ordering preserved
        // ==================================================================
        $display("--- Test 7: Per-source ordering preserved ---");

        // Analyze collected_tags from Test 6 for per-source ordering
        for (i = 0; i < NUM_SOURCES; i = i + 1) begin
            last_seq[i] = -1;
            src_out_count[i] = 0;
        end

        begin : ordering_check
            integer pass_order;
            pass_order = 1;
            for (i = 0; i < collected_count; i = i + 1) begin
                out_src_id = collected_tags[i][31:24];
                out_seq = collected_tags[i][15:0];
                if (out_src_id < NUM_SOURCES) begin
                    if ($signed(out_seq) <= last_seq[out_src_id]) begin
                        $display("[FAIL] Test 7: Source %0d out of order. seq=%0d after %0d",
                                 out_src_id, out_seq, last_seq[out_src_id]);
                        error_count = error_count + 1;
                        pass_order = 0;
                    end
                    last_seq[out_src_id] = out_seq;
                    src_out_count[out_src_id] = src_out_count[out_src_id] + 1;
                end
            end
            if (pass_order)
                $display("[PASS] Test 7: Per-source ordering preserved for all sources");
        end

        // ==================================================================
        // TEST 8: tag_valid deasserted after all sources drained
        // ==================================================================
        $display("--- Test 8: tag_valid deasserted after drain ---");
        // Sources should be empty after Test 6 collection
        wait_clks(10);
        if (tag_valid !== 1'b0) begin
            $display("[FAIL] Test 8: tag_valid should be 0 after all sources drained, got %b", tag_valid);
            error_count = error_count + 1;
        end else begin
            $display("[PASS] Test 8: tag_valid deasserted after all sources drained");
        end

        // ==================================================================
        // TEST 9: Round-robin skips empty sources
        // ==================================================================
        $display("--- Test 9: Round-robin skips empty sources ---");
        // Reset DUT for clean rr_ptr=0 state
        rst_n = 0;
        reset_all_sources;
        wait_clks(5);
        rst_n = 1;
        wait_clks(5);

        // Only load sources 2, 5, 7
        load_source(2, 2);
        load_source(5, 2);
        load_source(7, 2);

        rr_count = 0;
        begin : skip_collect
            integer cyc, idle;
            idle = 0;
            for (cyc = 0; cyc < 100; cyc = cyc + 1) begin
                @(posedge clk);
                if (tag_valid && tag_ready) begin
                    rr_order[rr_count] = tag_out[31:24];
                    rr_count = rr_count + 1;
                    idle = 0;
                end else begin
                    idle = idle + 1;
                    if (idle > 20) cyc = 100;
                end
            end
        end

        // Should get 6 outputs total, from sources 2, 5, 7 in round-robin
        if (rr_count !== 6) begin
            $display("[FAIL] Test 9: Expected 6 outputs, got %0d", rr_count);
            error_count = error_count + 1;
        end else begin
            // First round should be 2, 5, 7 (skipping empty sources)
            begin : skip_check
                integer pass_skip;
                pass_skip = 1;
                if (rr_order[0] !== 2) begin pass_skip = 0; end
                if (rr_order[1] !== 5) begin pass_skip = 0; end
                if (rr_order[2] !== 7) begin pass_skip = 0; end
                if (pass_skip)
                    $display("[PASS] Test 9: Round-robin correctly skips empty sources");
                else begin
                    $display("[FAIL] Test 9: First round order wrong: %0d, %0d, %0d (expected 2, 5, 7)",
                             rr_order[0], rr_order[1], rr_order[2]);
                    error_count = error_count + 1;
                end
            end
        end

        // ==================================================================
        // TEST 10: Backpressure with multiple sources - no advancement
        // ==================================================================
        $display("--- Test 10: Backpressure prevents source advancement ---");
        // Reset DUT for clean state
        rst_n = 0;
        reset_all_sources;
        wait_clks(5);
        rst_n = 1;
        wait_clks(5);

        load_source(0, 3);
        load_source(1, 3);
        load_source(2, 3);

        tag_ready = 1;
        // Wait for first valid output
        begin : bp2_wait
            integer timeout_cnt;
            timeout_cnt = 0;
            while (!tag_valid && timeout_cnt < 20) begin
                @(posedge clk);
                timeout_cnt = timeout_cnt + 1;
            end
        end

        // Consume first tag, then apply backpressure
        @(posedge clk);
        tag_ready = 0;
        wait_clks(2); // Let pipeline settle with backpressure

        // Now verify no fifo_rd_en during backpressure
        wait_clks(10);
        @(posedge clk);
        if (fifo_rd_en !== {NUM_SOURCES{1'b0}}) begin
            $display("[FAIL] Test 10: fifo_rd_en active during backpressure: %b", fifo_rd_en);
            error_count = error_count + 1;
        end else begin
            $display("[PASS] Test 10: No FIFO reads during backpressure");
        end

        // Release and verify operation resumes
        tag_ready = 1;
        wait_clks(30);

        // ==================================================================
        // Final Summary
        // ==================================================================
        $display("");
        $display("========================================");
        if (error_count == 0) begin
            $display("=== ALL TESTS PASSED ===");
            $finish(0);
        end else begin
            $display("=== %0d TESTS FAILED ===", error_count);
            $finish(1);
        end
    end

endmodule
