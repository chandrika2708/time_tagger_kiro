//-----------------------------------------------------------------------------
// tb_coincidence_detector.v
// Self-checking testbench for coincidence_detector module
//-----------------------------------------------------------------------------
`timescale 1ns / 1ps

`include "time_tagger_pkg.v"

module tb_coincidence_detector;

// ============================================================================
// Parameters
// ============================================================================
localparam NUM_CHANNELS = 8;
localparam NUM_GROUPS   = 4;
localparam WINDOW_BITS  = 10;
localparam CLK_PERIOD   = 2; // 500 MHz = 2 ns period

// ============================================================================
// Signals
// ============================================================================
reg        clk_coarse;
reg        rst_n;
reg [95:0] tag_in [NUM_CHANNELS-1:0];
reg [NUM_CHANNELS-1:0] tag_valid_in;
reg [NUM_CHANNELS-1:0] group_mask [NUM_GROUPS-1:0];
reg [WINDOW_BITS-1:0]  window [NUM_GROUPS-1:0];
reg [NUM_GROUPS-1:0]   group_enable;

wire [95:0] coinc_tag;
wire        coinc_valid;
wire        config_error;

integer error_count = 0;
integer test_num = 0;

// Capture variables
reg        got_coinc;
reg [95:0] captured_tag;
integer    coinc_latency;

// ============================================================================
// Clock Generation (500 MHz)
// ============================================================================
initial clk_coarse = 0;
always #(CLK_PERIOD/2) clk_coarse = ~clk_coarse;

// ============================================================================
// Simulation Timeout (20 µs)
// ============================================================================
initial begin
    #20000;
    $display("[FAIL] Simulation timeout");
    $finish(1);
end

// ============================================================================
// DUT Instantiation
// ============================================================================
coincidence_detector #(
    .NUM_CHANNELS(NUM_CHANNELS),
    .NUM_GROUPS(NUM_GROUPS),
    .WINDOW_BITS(WINDOW_BITS)
) dut (
    .clk_coarse(clk_coarse),
    .rst_n(rst_n),
    .tag_in(tag_in),
    .tag_valid_in(tag_valid_in),
    .group_mask(group_mask),
    .window(window),
    .group_enable(group_enable),
    .coinc_tag(coinc_tag),
    .coinc_valid(coinc_valid),
    .config_error(config_error)
);

// ============================================================================
// Helper Functions and Tasks
// ============================================================================

function [95:0] make_tag;
    input [63:0] timestamp;
    input [7:0]  channel_id;
    input [7:0]  flags;
    input [15:0] reserved;
begin
    make_tag = {timestamp, channel_id, flags, reserved};
end
endfunction

task clear_inputs;
    integer i;
begin
    tag_valid_in = {NUM_CHANNELS{1'b0}};
    for (i = 0; i < NUM_CHANNELS; i = i + 1)
        tag_in[i] = 96'd0;
end
endtask

task init_groups;
    integer g;
begin
    group_enable = {NUM_GROUPS{1'b0}};
    for (g = 0; g < NUM_GROUPS; g = g + 1) begin
        group_mask[g] = {NUM_CHANNELS{1'b0}};
        window[g] = 10'd0;
    end
end
endtask

// Task: Wait up to max_cycles for coinc_valid, capture result
task wait_for_coinc;
    input integer max_cycles;
    integer cyc;
begin
    got_coinc = 0;
    captured_tag = 96'd0;
    coinc_latency = 0;
    for (cyc = 0; cyc < max_cycles; cyc = cyc + 1) begin
        @(posedge clk_coarse);
        if (coinc_valid) begin
            got_coinc = 1;
            captured_tag = coinc_tag;
            coinc_latency = cyc + 1;
            cyc = max_cycles; // break
        end
    end
end
endtask

// Task: Flush pipeline (wait enough cycles for any pending output)
task flush_pipeline;
begin
    repeat(12) @(posedge clk_coarse);
end
endtask

// ============================================================================
// Main Stimulus
// ============================================================================
initial begin
    // Initialize
    rst_n = 0;
    tag_valid_in = 0;
    clear_inputs;
    init_groups;

    // Reset sequence
    #100;
    rst_n = 1;
    repeat(10) @(posedge clk_coarse);

    // ================================================================
    // TEST 1: Coincidence detected when events within window
    // Requirement 5.1
    // ================================================================
    test_num = 1;
    $display("--- Test %0d: Coincidence within window ---", test_num);

    // Configure group 0: channels 0 and 1, window = 100 (1 ns)
    group_mask[0] = 8'b00000011;
    window[0] = 10'd100;
    group_enable[0] = 1'b1;
    repeat(2) @(posedge clk_coarse);

    // Inject events on channels 0 and 1 with timestamps within window
    @(posedge clk_coarse);
    tag_in[0] = make_tag(64'd1000, 8'd0, 8'd1, 16'd0);
    tag_in[1] = make_tag(64'd1050, 8'd1, 8'd1, 16'd0);
    tag_valid_in = 8'b00000011;
    @(posedge clk_coarse);
    clear_inputs;

    // Wait for coincidence output
    wait_for_coinc(10);

    if (!got_coinc) begin
        $display("[FAIL] Test %0d: No coincidence detected when events within window", test_num);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test %0d: Coincidence detected when events within window", test_num);
    end

    init_groups;
    flush_pipeline;

    // ================================================================
    // TEST 2: No coincidence when events exceed window
    // Requirement 5.2
    // ================================================================
    test_num = 2;
    $display("--- Test %0d: No coincidence when events exceed window ---", test_num);

    group_mask[0] = 8'b00000011;
    window[0] = 10'd100;
    group_enable[0] = 1'b1;
    repeat(2) @(posedge clk_coarse);

    // Timestamp difference = 200 > window of 100
    @(posedge clk_coarse);
    tag_in[0] = make_tag(64'd2000, 8'd0, 8'd1, 16'd0);
    tag_in[1] = make_tag(64'd2200, 8'd1, 8'd1, 16'd0);
    tag_valid_in = 8'b00000011;
    @(posedge clk_coarse);
    clear_inputs;

    wait_for_coinc(10);

    if (got_coinc) begin
        $display("[FAIL] Test %0d: Coincidence detected when events exceed window", test_num);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test %0d: No coincidence when events exceed window", test_num);
    end

    init_groups;
    flush_pipeline;

    // ================================================================
    // TEST 3: Coincidence output within 8 clock cycles of last event
    // Requirement 5.3
    // ================================================================
    test_num = 3;
    $display("--- Test %0d: Coincidence output within 8 cycles ---", test_num);

    group_mask[0] = 8'b00001100; // channels 2, 3
    window[0] = 10'd500;
    group_enable[0] = 1'b1;
    repeat(2) @(posedge clk_coarse);

    @(posedge clk_coarse);
    tag_in[2] = make_tag(64'd3000, 8'd2, 8'd1, 16'd0);
    tag_in[3] = make_tag(64'd3100, 8'd3, 8'd1, 16'd0);
    tag_valid_in = 8'b00001100;
    @(posedge clk_coarse);
    clear_inputs;

    wait_for_coinc(10);

    if (got_coinc && coinc_latency <= 8) begin
        $display("[PASS] Test %0d: Coincidence output within %0d cycles (<=8)", test_num, coinc_latency);
    end else if (got_coinc) begin
        $display("[FAIL] Test %0d: Coincidence took %0d cycles (expected <=8)", test_num, coinc_latency);
        error_count = error_count + 1;
    end else begin
        $display("[FAIL] Test %0d: No coincidence detected", test_num);
        error_count = error_count + 1;
    end

    init_groups;
    flush_pipeline;

    // ================================================================
    // TEST 4: Tag_Record format verification
    // Requirement 5.4
    // channel_id=0xFF, group ID in flags[4:3], channel bitmask in reserved
    // ================================================================
    test_num = 4;
    $display("--- Test %0d: Tag_Record format verification ---", test_num);

    // Configure group 1: channels 4 and 5, window = 200
    group_mask[1] = 8'b00110000;
    window[1] = 10'd200;
    group_enable[1] = 1'b1;
    repeat(2) @(posedge clk_coarse);

    @(posedge clk_coarse);
    tag_in[4] = make_tag(64'd5000, 8'd4, 8'd1, 16'd0);
    tag_in[5] = make_tag(64'd5100, 8'd5, 8'd1, 16'd0);
    tag_valid_in = 8'b00110000;
    @(posedge clk_coarse);
    clear_inputs;

    wait_for_coinc(10);

    if (!got_coinc) begin
        $display("[FAIL] Test %0d: No coincidence detected for format check", test_num);
        error_count = error_count + 1;
    end else begin
        // Check channel_id = 0xFF
        if (captured_tag[`TAG_CHANNEL_ID_MSB:`TAG_CHANNEL_ID_LSB] !== 8'hFF) begin
            $display("[FAIL] Test %0d: channel_id = %h, expected 0xFF",
                     test_num, captured_tag[`TAG_CHANNEL_ID_MSB:`TAG_CHANNEL_ID_LSB]);
            error_count = error_count + 1;
        end else begin
            $display("[PASS] Test %0d: channel_id = 0xFF", test_num);
        end

        // Check group ID in flags[4:3] = 1 (group 1)
        // RTL encodes as: {3'b0, 2'd<group>, 3'b0} = 8'b00001000 for group 1
        if (captured_tag[`TAG_FLAGS_MSB:`TAG_FLAGS_LSB] !== 8'b00001000) begin
            $display("[FAIL] Test %0d: flags = %b, expected 00001000 (group 1)",
                     test_num, captured_tag[`TAG_FLAGS_MSB:`TAG_FLAGS_LSB]);
            error_count = error_count + 1;
        end else begin
            $display("[PASS] Test %0d: flags correctly encode group 1", test_num);
        end

        // Check channel bitmask in reserved field
        if (captured_tag[`TAG_RESERVED_MSB:`TAG_RESERVED_LSB] !== 16'h0030) begin
            $display("[FAIL] Test %0d: reserved = %h, expected 0030",
                     test_num, captured_tag[`TAG_RESERVED_MSB:`TAG_RESERVED_LSB]);
            error_count = error_count + 1;
        end else begin
            $display("[PASS] Test %0d: channel bitmask correct in reserved", test_num);
        end
    end

    init_groups;
    flush_pipeline;

    // ================================================================
    // TEST 5: config_error on invalid window values (< 10)
    // Requirement 5.5
    // ================================================================
    test_num = 5;
    $display("--- Test %0d: config_error on invalid window (< 10) ---", test_num);

    group_mask[0] = 8'b00000011;
    window[0] = 10'd5;
    group_enable[0] = 1'b1;
    repeat(3) @(posedge clk_coarse);

    if (config_error !== 1'b1) begin
        $display("[FAIL] Test %0d: config_error not asserted for window=5", test_num);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test %0d: config_error asserted for window=5", test_num);
    end

    // Verify no coincidence detection with invalid window
    @(posedge clk_coarse);
    tag_in[0] = make_tag(64'd6000, 8'd0, 8'd1, 16'd0);
    tag_in[1] = make_tag(64'd6001, 8'd1, 8'd1, 16'd0);
    tag_valid_in = 8'b00000011;
    @(posedge clk_coarse);
    clear_inputs;

    wait_for_coinc(10);

    if (got_coinc) begin
        $display("[FAIL] Test %0d: Coincidence detected with invalid window", test_num);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test %0d: No coincidence with invalid window", test_num);
    end

    init_groups;
    flush_pipeline;

    // ================================================================
    // TEST 6: config_error on invalid window values (> 1000)
    // Requirement 5.5
    // ================================================================
    test_num = 6;
    $display("--- Test %0d: config_error on invalid window (> 1000) ---", test_num);

    group_mask[2] = 8'b00001100;
    window[2] = 10'd1023;
    group_enable[2] = 1'b1;
    repeat(3) @(posedge clk_coarse);

    if (config_error !== 1'b1) begin
        $display("[FAIL] Test %0d: config_error not asserted for window=1023", test_num);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test %0d: config_error asserted for window=1023", test_num);
    end

    init_groups;
    flush_pipeline;

    // ================================================================
    // TEST 7: config_error deasserted for valid window values
    // Requirement 5.6
    // ================================================================
    test_num = 7;
    $display("--- Test %0d: config_error deasserted for valid window ---", test_num);

    group_mask[0] = 8'b00000011;
    window[0] = 10'd500;
    group_enable[0] = 1'b1;
    repeat(3) @(posedge clk_coarse);

    if (config_error !== 1'b0) begin
        $display("[FAIL] Test %0d: config_error asserted for valid window=500", test_num);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test %0d: config_error deasserted for valid window=500", test_num);
    end

    init_groups;
    flush_pipeline;

    // ================================================================
    // TEST 8: Group 0 priority over other groups
    // Requirement 5.7
    // ================================================================
    test_num = 8;
    $display("--- Test %0d: Group 0 priority over other groups ---", test_num);

    // Configure group 0: channels 0,1 window=500
    // Configure group 1: channels 2,3 window=500
    group_mask[0] = 8'b00000011;
    window[0] = 10'd500;
    group_enable[0] = 1'b1;

    group_mask[1] = 8'b00001100;
    window[1] = 10'd500;
    group_enable[1] = 1'b1;
    repeat(2) @(posedge clk_coarse);

    // Inject events on both groups simultaneously
    @(posedge clk_coarse);
    tag_in[0] = make_tag(64'd7000, 8'd0, 8'd1, 16'd0);
    tag_in[1] = make_tag(64'd7050, 8'd1, 8'd1, 16'd0);
    tag_in[2] = make_tag(64'd7000, 8'd2, 8'd1, 16'd0);
    tag_in[3] = make_tag(64'd7050, 8'd3, 8'd1, 16'd0);
    tag_valid_in = 8'b00001111;
    @(posedge clk_coarse);
    clear_inputs;

    wait_for_coinc(10);

    if (!got_coinc) begin
        $display("[FAIL] Test %0d: No coincidence detected", test_num);
        error_count = error_count + 1;
    end else begin
        // Check flags[4:3] = 0 (group 0 has priority)
        // RTL: {3'b0, 2'd0, 3'b0} = 8'b00000000
        if (captured_tag[`TAG_FLAGS_MSB:`TAG_FLAGS_LSB] !== 8'b00000000) begin
            $display("[FAIL] Test %0d: flags = %b, expected 00000000 (group 0 priority)",
                     test_num, captured_tag[`TAG_FLAGS_MSB:`TAG_FLAGS_LSB]);
            error_count = error_count + 1;
        end else begin
            $display("[PASS] Test %0d: Group 0 has priority (flags=00000000)", test_num);
        end
    end

    init_groups;
    flush_pipeline;

    // ================================================================
    // TEST 9: Original tag_valid signals unaffected
    // Requirement 5.8
    // ================================================================
    test_num = 9;
    $display("--- Test %0d: Original tag_valid unaffected ---", test_num);

    group_mask[0] = 8'b00000011;
    window[0] = 10'd500;
    group_enable[0] = 1'b1;
    repeat(2) @(posedge clk_coarse);

    // Inject events and verify tag_valid_in is not consumed by DUT
    @(posedge clk_coarse);
    tag_in[0] = make_tag(64'd8000, 8'd0, 8'd1, 16'd0);
    tag_in[1] = make_tag(64'd8050, 8'd1, 8'd1, 16'd0);
    tag_valid_in = 8'b00000011;

    // DUT has no output that modifies tag_valid_in (it's a pure input wire)
    @(posedge clk_coarse);
    if (tag_valid_in !== 8'b00000011) begin
        $display("[FAIL] Test %0d: tag_valid_in was modified by DUT", test_num);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test %0d: tag_valid_in unaffected by coincidence detection", test_num);
    end

    clear_inputs;
    init_groups;
    flush_pipeline;

    // ================================================================
    // TEST 10: Coincidence with 3+ channels in a group
    // Additional coverage for Requirement 5.1
    // ================================================================
    test_num = 10;
    $display("--- Test %0d: Coincidence with 3 channels ---", test_num);

    group_mask[2] = 8'b00000111; // channels 0,1,2
    window[2] = 10'd300;
    group_enable[2] = 1'b1;
    repeat(2) @(posedge clk_coarse);

    @(posedge clk_coarse);
    tag_in[0] = make_tag(64'd9000, 8'd0, 8'd1, 16'd0);
    tag_in[1] = make_tag(64'd9100, 8'd1, 8'd1, 16'd0);
    tag_in[2] = make_tag(64'd9200, 8'd2, 8'd1, 16'd0);
    tag_valid_in = 8'b00000111;
    @(posedge clk_coarse);
    clear_inputs;

    wait_for_coinc(10);

    if (!got_coinc) begin
        $display("[FAIL] Test %0d: No coincidence with 3 channels within window", test_num);
        error_count = error_count + 1;
    end else begin
        if (captured_tag[`TAG_RESERVED_MSB:`TAG_RESERVED_LSB] !== 16'h0007) begin
            $display("[FAIL] Test %0d: channel bitmask = %h, expected 0007",
                     test_num, captured_tag[`TAG_RESERVED_MSB:`TAG_RESERVED_LSB]);
            error_count = error_count + 1;
        end else begin
            $display("[PASS] Test %0d: 3-channel coincidence with correct bitmask", test_num);
        end
    end

    init_groups;
    flush_pipeline;

    // ================================================================
    // TEST 11: No coincidence with only 1 channel active in group
    // Requirement 5.1 (need at least 2 events)
    // ================================================================
    test_num = 11;
    $display("--- Test %0d: No coincidence with single channel ---", test_num);

    group_mask[0] = 8'b00000011;
    window[0] = 10'd500;
    group_enable[0] = 1'b1;
    repeat(2) @(posedge clk_coarse);

    @(posedge clk_coarse);
    tag_in[0] = make_tag(64'd10000, 8'd0, 8'd1, 16'd0);
    tag_valid_in = 8'b00000001; // only channel 0
    @(posedge clk_coarse);
    clear_inputs;

    wait_for_coinc(10);

    if (got_coinc) begin
        $display("[FAIL] Test %0d: Coincidence detected with only 1 channel", test_num);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test %0d: No coincidence with single channel", test_num);
    end

    init_groups;
    flush_pipeline;

    // ================================================================
    // TEST 12: Disabled group does not produce coincidence
    // ================================================================
    test_num = 12;
    $display("--- Test %0d: Disabled group no coincidence ---", test_num);

    group_mask[0] = 8'b00000011;
    window[0] = 10'd500;
    group_enable[0] = 1'b0; // disabled
    repeat(2) @(posedge clk_coarse);

    @(posedge clk_coarse);
    tag_in[0] = make_tag(64'd11000, 8'd0, 8'd1, 16'd0);
    tag_in[1] = make_tag(64'd11010, 8'd1, 8'd1, 16'd0);
    tag_valid_in = 8'b00000011;
    @(posedge clk_coarse);
    clear_inputs;

    wait_for_coinc(10);

    if (got_coinc) begin
        $display("[FAIL] Test %0d: Coincidence detected on disabled group", test_num);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test %0d: No coincidence on disabled group", test_num);
    end

    init_groups;
    flush_pipeline;

    // ================================================================
    // TEST 13: Boundary - events exactly at window edge (spread == window)
    // Requirement 5.1
    // ================================================================
    test_num = 13;
    $display("--- Test %0d: Events exactly at window boundary ---", test_num);

    group_mask[0] = 8'b00000011;
    window[0] = 10'd100;
    group_enable[0] = 1'b1;
    repeat(2) @(posedge clk_coarse);

    // spread = 100 == window = 100 (should be coincidence: spread <= window)
    @(posedge clk_coarse);
    tag_in[0] = make_tag(64'd12000, 8'd0, 8'd1, 16'd0);
    tag_in[1] = make_tag(64'd12100, 8'd1, 8'd1, 16'd0);
    tag_valid_in = 8'b00000011;
    @(posedge clk_coarse);
    clear_inputs;

    wait_for_coinc(10);

    if (!got_coinc) begin
        $display("[FAIL] Test %0d: No coincidence at exact window boundary", test_num);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test %0d: Coincidence at exact window boundary (spread==window)", test_num);
    end

    init_groups;
    flush_pipeline;

    // ================================================================
    // TEST 14: Boundary - events just beyond window (spread = window+1)
    // Requirement 5.2
    // ================================================================
    test_num = 14;
    $display("--- Test %0d: Events just beyond window ---", test_num);

    group_mask[0] = 8'b00000011;
    window[0] = 10'd100;
    group_enable[0] = 1'b1;
    repeat(2) @(posedge clk_coarse);

    // spread = 101 > window = 100
    @(posedge clk_coarse);
    tag_in[0] = make_tag(64'd13000, 8'd0, 8'd1, 16'd0);
    tag_in[1] = make_tag(64'd13101, 8'd1, 8'd1, 16'd0);
    tag_valid_in = 8'b00000011;
    @(posedge clk_coarse);
    clear_inputs;

    wait_for_coinc(10);

    if (got_coinc) begin
        $display("[FAIL] Test %0d: Coincidence detected beyond window (spread=101, window=100)", test_num);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test %0d: No coincidence just beyond window", test_num);
    end

    init_groups;
    flush_pipeline;

    // ================================================================
    // TEST 15: Timestamp in coincidence tag is latest event timestamp
    // Requirement 5.4
    // ================================================================
    test_num = 15;
    $display("--- Test %0d: Coincidence timestamp is latest event ---", test_num);

    group_mask[0] = 8'b00000011;
    window[0] = 10'd500;
    group_enable[0] = 1'b1;
    repeat(2) @(posedge clk_coarse);

    @(posedge clk_coarse);
    tag_in[0] = make_tag(64'd14000, 8'd0, 8'd1, 16'd0);
    tag_in[1] = make_tag(64'd14200, 8'd1, 8'd1, 16'd0);
    tag_valid_in = 8'b00000011;
    @(posedge clk_coarse);
    clear_inputs;

    wait_for_coinc(10);

    if (!got_coinc) begin
        $display("[FAIL] Test %0d: No coincidence detected", test_num);
        error_count = error_count + 1;
    end else begin
        if (captured_tag[`TAG_TIMESTAMP_MSB:`TAG_TIMESTAMP_LSB] !== 64'd14200) begin
            $display("[FAIL] Test %0d: timestamp = %0d, expected 14200",
                     test_num, captured_tag[`TAG_TIMESTAMP_MSB:`TAG_TIMESTAMP_LSB]);
            error_count = error_count + 1;
        end else begin
            $display("[PASS] Test %0d: Coincidence timestamp is latest event (14200)", test_num);
        end
    end

    init_groups;
    flush_pipeline;

    // ================================================================
    // Final Summary
    // ================================================================
    #100;
    if (error_count == 0) begin
        $display("=== ALL TESTS PASSED ===");
        $finish(0);
    end else begin
        $display("=== %0d TESTS FAILED ===", error_count);
        $finish(1);
    end
end

endmodule
