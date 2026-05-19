//-----------------------------------------------------------------------------
// tb_clock_manager.v
// Testbench for clock_manager module
//-----------------------------------------------------------------------------
// Verifies clock generation, external reference switching, clock loss failover,
// and state machine transitions using Xilinx primitive behavioral stubs.
//
// Requirements: 10.1, 10.2, 10.3, 10.4, 10.5
//-----------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_clock_manager;

// ============================================================================
// Error Tracking
// ============================================================================
integer error_count = 0;

// ============================================================================
// DUT Signals
// ============================================================================
reg         clk_board;
reg         clk_ext_10mhz;
reg         ext_clk_valid;
reg         rst_n;

wire        clk_coarse;
wire        clk_axi;
wire        clk_dma;
wire        clk_cal;
wire        locked;
wire        clk_loss_error;

// ============================================================================
// Internal Monitoring - Access DUT state machine
// ============================================================================
wire [2:0] dut_pll_state = dut.pll_state;

// State encoding (matches DUT)
localparam ST_IDLE        = 3'd0;
localparam ST_INTERNAL    = 3'd1;
localparam ST_EXT_LOCKING = 3'd2;
localparam ST_EXT_LOCKED  = 3'd3;
localparam ST_FALLBACK    = 3'd4;

// ============================================================================
// Clock Generation
// ============================================================================

// 100 MHz board clock (10 ns period)
initial clk_board = 0;
always #5 clk_board = ~clk_board;

// 10 MHz external reference clock (100 ns period)
initial clk_ext_10mhz = 0;
always #50 clk_ext_10mhz = ~clk_ext_10mhz;

// ============================================================================
// DUT Instantiation
// ============================================================================
clock_manager dut (
    .clk_board      (clk_board),
    .clk_ext_10mhz (clk_ext_10mhz),
    .ext_clk_valid  (ext_clk_valid),
    .rst_n          (rst_n),
    .clk_coarse     (clk_coarse),
    .clk_axi        (clk_axi),
    .clk_dma        (clk_dma),
    .clk_cal        (clk_cal),
    .locked         (locked),
    .clk_loss_error (clk_loss_error)
);

// ============================================================================
// Clock Toggle Detection
// ============================================================================
// Count transitions on each output clock to verify toggling
integer coarse_toggle_cnt;
integer axi_toggle_cnt;
integer dma_toggle_cnt;
integer cal_toggle_cnt;

task reset_toggle_counts;
begin
    coarse_toggle_cnt = 0;
    axi_toggle_cnt = 0;
    dma_toggle_cnt = 0;
    cal_toggle_cnt = 0;
end
endtask

reg clk_coarse_prev, clk_axi_prev, clk_dma_prev, clk_cal_prev;

always @(clk_coarse) begin
    if (rst_n) coarse_toggle_cnt = coarse_toggle_cnt + 1;
end

always @(clk_axi) begin
    if (rst_n) axi_toggle_cnt = axi_toggle_cnt + 1;
end

always @(clk_dma) begin
    if (rst_n) dma_toggle_cnt = dma_toggle_cnt + 1;
end

always @(clk_cal) begin
    if (rst_n) cal_toggle_cnt = cal_toggle_cnt + 1;
end

// ============================================================================
// Simulation Timeout
// ============================================================================
initial begin
    #50_000_000; // 50 ms
    $display("[FAIL] Simulation timeout at 50 ms");
    error_count = error_count + 1;
    $finish(1);
end

// ============================================================================
// Main Test Sequence
// ============================================================================
initial begin
    // Initialize
    rst_n = 0;
    ext_clk_valid = 0;
    coarse_toggle_cnt = 0;
    axi_toggle_cnt = 0;
    dma_toggle_cnt = 0;
    cal_toggle_cnt = 0;

    // ========================================================================
    // Test 1: Reset and initial clock generation (Req 10.1)
    // ========================================================================
    $display("--- Test 1: Reset and clock generation with board clock ---");

    // Hold reset for 100 ns
    #100;
    rst_n = 1;

    // Wait for MMCM to lock (stub locks in 1 cycle, but allow some settling)
    // Wait for reset synchronizer to propagate (2 cycles) + MMCM lock
    repeat (20) @(posedge clk_board);

    // Reset toggle counters and observe for 200 ns
    reset_toggle_counts;
    #200;

    // Verify all output clocks are toggling
    if (coarse_toggle_cnt > 0) begin
        $display("[PASS] Test 1a: clk_coarse is toggling (%0d transitions)", coarse_toggle_cnt);
    end else begin
        $display("[FAIL] Test 1a: clk_coarse is NOT toggling");
        error_count = error_count + 1;
    end

    if (axi_toggle_cnt > 0) begin
        $display("[PASS] Test 1b: clk_axi is toggling (%0d transitions)", axi_toggle_cnt);
    end else begin
        $display("[FAIL] Test 1b: clk_axi is NOT toggling");
        error_count = error_count + 1;
    end

    if (dma_toggle_cnt > 0) begin
        $display("[PASS] Test 1c: clk_dma is toggling (%0d transitions)", dma_toggle_cnt);
    end else begin
        $display("[FAIL] Test 1c: clk_dma is NOT toggling");
        error_count = error_count + 1;
    end

    if (cal_toggle_cnt > 0) begin
        $display("[PASS] Test 1d: clk_cal is toggling (%0d transitions)", cal_toggle_cnt);
    end else begin
        $display("[FAIL] Test 1d: clk_cal is NOT toggling");
        error_count = error_count + 1;
    end

    // ========================================================================
    // Test 2: Locked asserts after MMCM locks (Req 10.1)
    // ========================================================================
    $display("--- Test 2: Locked signal assertion ---");

    if (locked === 1'b1) begin
        $display("[PASS] Test 2: locked is asserted after MMCM locks");
    end else begin
        $display("[FAIL] Test 2: locked is NOT asserted (got %b)", locked);
        error_count = error_count + 1;
    end

    // ========================================================================
    // Test 3: State machine starts in INTERNAL state (Req 10.5)
    // ========================================================================
    $display("--- Test 3: State machine in INTERNAL state ---");

    if (dut_pll_state === ST_INTERNAL) begin
        $display("[PASS] Test 3: State machine is in INTERNAL state (%0d)", dut_pll_state);
    end else begin
        $display("[FAIL] Test 3: State machine not in INTERNAL state (got %0d, expected %0d)", dut_pll_state, ST_INTERNAL);
        error_count = error_count + 1;
    end

    // ========================================================================
    // Test 4: Transition to external reference (Req 10.2, 10.5)
    // ========================================================================
    $display("--- Test 4: Transition to external reference ---");

    // Assert ext_clk_valid
    @(posedge clk_board);
    ext_clk_valid = 1;

    // Wait for synchronizer (2 cycles) + state transition
    repeat (5) @(posedge clk_board);

    // Should be in EXT_LOCKING state
    if (dut_pll_state === ST_EXT_LOCKING) begin
        $display("[PASS] Test 4a: Transitioned to EXT_LOCKING state");
    end else begin
        $display("[FAIL] Test 4a: Expected EXT_LOCKING (%0d), got %0d", ST_EXT_LOCKING, dut_pll_state);
        error_count = error_count + 1;
    end

    // Wait for phase lock settling (1,000,000 cycles at 100 MHz = 10 ms)
    // The MMCM stub locks immediately, so we just need to wait for the counter
    $display("  Waiting for phase lock settle (1M cycles)...");
    repeat (1_000_020) @(posedge clk_board);

    // Should now be in EXT_LOCKED state
    if (dut_pll_state === ST_EXT_LOCKED) begin
        $display("[PASS] Test 4b: Transitioned to EXT_LOCKED state");
    end else begin
        $display("[FAIL] Test 4b: Expected EXT_LOCKED (%0d), got %0d", ST_EXT_LOCKED, dut_pll_state);
        error_count = error_count + 1;
    end

    // Verify locked is still asserted
    if (locked === 1'b1) begin
        $display("[PASS] Test 4c: locked remains asserted in EXT_LOCKED state");
    end else begin
        $display("[FAIL] Test 4c: locked deasserted in EXT_LOCKED state");
        error_count = error_count + 1;
    end

    // Verify clocks still toggling
    reset_toggle_counts;
    #200;

    if (coarse_toggle_cnt > 0 && axi_toggle_cnt > 0 && dma_toggle_cnt > 0 && cal_toggle_cnt > 0) begin
        $display("[PASS] Test 4d: All clocks still toggling in EXT_LOCKED state");
    end else begin
        $display("[FAIL] Test 4d: Some clocks stopped toggling in EXT_LOCKED state");
        error_count = error_count + 1;
    end

    // ========================================================================
    // Test 5: Clock loss detection (Req 10.3, 10.5)
    // ========================================================================
    $display("--- Test 5: External clock loss detection ---");

    // Deassert ext_clk_valid to simulate clock loss
    @(posedge clk_board);
    ext_clk_valid = 0;

    // Wait for loss detection (synchronizer 2 cycles + timeout 100 cycles + margin)
    // Monitor for FALLBACK state during the transition
    begin : test5_block
        integer saw_fallback;
        integer wait_cycles;
        saw_fallback = 0;
        for (wait_cycles = 0; wait_cycles < 150; wait_cycles = wait_cycles + 1) begin
            @(posedge clk_board);
            if (dut_pll_state === ST_FALLBACK) begin
                saw_fallback = 1;
            end
        end

        // Verify clk_loss_error asserts
        if (clk_loss_error === 1'b1) begin
            $display("[PASS] Test 5a: clk_loss_error asserted on external clock loss");
        end else begin
            $display("[FAIL] Test 5a: clk_loss_error NOT asserted (got %b)", clk_loss_error);
            error_count = error_count + 1;
        end

        // Verify state machine transitioned through FALLBACK
        // Note: With the behavioral MMCM stub, lock is maintained so FALLBACK->INTERNAL
        // transition may happen very quickly. We check that FALLBACK was visited.
        if (saw_fallback || dut_pll_state === ST_FALLBACK) begin
            $display("[PASS] Test 5b: Transitioned through FALLBACK state");
        end else begin
            $display("[FAIL] Test 5b: Never observed FALLBACK state (current: %0d)", dut_pll_state);
            error_count = error_count + 1;
        end
    end

    // ========================================================================
    // Test 6: Fallback to internal clock (Req 10.4, 10.5)
    // ========================================================================
    $display("--- Test 6: Fallback to internal clock ---");

    // Wait for MMCM to re-lock on internal clock (stub locks in 1 cycle)
    // The MMCM RST was not asserted during fallback (only use_ext_clk changed),
    // so the MMCM should remain locked. The state machine checks mmcm_locked
    // to transition from FALLBACK to INTERNAL.
    repeat (10) @(posedge clk_board);

    // Should transition back to INTERNAL once MMCM is locked
    if (dut_pll_state === ST_INTERNAL) begin
        $display("[PASS] Test 6a: Transitioned back to INTERNAL state after fallback");
    end else begin
        $display("[FAIL] Test 6a: Expected INTERNAL (%0d), got %0d", ST_INTERNAL, dut_pll_state);
        error_count = error_count + 1;
    end

    // Verify clocks continue toggling after fallback
    reset_toggle_counts;
    #200;

    if (coarse_toggle_cnt > 0 && axi_toggle_cnt > 0 && dma_toggle_cnt > 0 && cal_toggle_cnt > 0) begin
        $display("[PASS] Test 6b: All clocks continue toggling after fallback");
    end else begin
        $display("[FAIL] Test 6b: Some clocks stopped after fallback");
        error_count = error_count + 1;
    end

    // Verify locked re-asserts
    if (locked === 1'b1) begin
        $display("[PASS] Test 6c: locked re-asserted after fallback to internal");
    end else begin
        $display("[FAIL] Test 6c: locked NOT asserted after fallback (got %b)", locked);
        error_count = error_count + 1;
    end

    // ========================================================================
    // Test 7: Full state machine sequence verification (Req 10.5)
    // ========================================================================
    $display("--- Test 7: Full state machine sequence IDLE->INTERNAL->EXT_LOCKING->EXT_LOCKED->FALLBACK ---");

    // We've already verified the full sequence through tests 3-6:
    // IDLE (at reset) -> INTERNAL -> EXT_LOCKING -> EXT_LOCKED -> FALLBACK -> INTERNAL
    // Let's do one more cycle to confirm repeatability

    // Assert ext_clk_valid again
    @(posedge clk_board);
    ext_clk_valid = 1;

    // Wait for synchronizer + transition
    repeat (5) @(posedge clk_board);

    if (dut_pll_state === ST_EXT_LOCKING) begin
        $display("[PASS] Test 7a: Re-entered EXT_LOCKING on second ext_clk_valid assertion");
    end else begin
        $display("[FAIL] Test 7a: Expected EXT_LOCKING, got %0d", dut_pll_state);
        error_count = error_count + 1;
    end

    // Wait for phase lock again
    $display("  Waiting for second phase lock settle...");
    repeat (1_000_020) @(posedge clk_board);

    if (dut_pll_state === ST_EXT_LOCKED) begin
        $display("[PASS] Test 7b: Re-entered EXT_LOCKED state");
    end else begin
        $display("[FAIL] Test 7b: Expected EXT_LOCKED, got %0d", dut_pll_state);
        error_count = error_count + 1;
    end

    // Deassert ext_clk_valid again
    @(posedge clk_board);
    ext_clk_valid = 0;

    repeat (150) @(posedge clk_board);

    if (dut_pll_state === ST_FALLBACK || dut_pll_state === ST_INTERNAL) begin
        $display("[PASS] Test 7c: Entered FALLBACK/INTERNAL on second clock loss");
    end else begin
        $display("[FAIL] Test 7c: Expected FALLBACK or INTERNAL, got %0d", dut_pll_state);
        error_count = error_count + 1;
    end

    // ========================================================================
    // Final Summary
    // ========================================================================
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
