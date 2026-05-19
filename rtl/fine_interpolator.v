//-----------------------------------------------------------------------------
// fine_interpolator.v
// Fine time interpolator using CARRY8-based tapped delay line
//-----------------------------------------------------------------------------
// This module implements a Tapped Delay Line (TDL) for sub-clock-cycle time
// measurement on Xilinx UltraScale+ FPGAs. The input event propagates through
// a chain of CARRY8 primitives; the thermometer code is sampled by flip-flops
// on the rising edge of the 500 MHz clock.
//
// Architecture:
//   1. CARRY8 delay chain (32 cells = 256 taps)
//   2. Pipeline register stage (metastability hardening)
//   3. Bubble correction (removes spurious 0→1→0 or 1→0→1 transitions)
//   4. Thermometer-to-binary priority encoder (8-bit output)
//
// Requirements: 2.1 (10 ps resolution), 2.2 (≥200 bins)
//-----------------------------------------------------------------------------

`include "time_tagger_pkg.v"

module fine_interpolator #(
    parameter NUM_TAPS = 256
)(
    input  wire              clk,          // 500 MHz sampling clock
    input  wire              event_in,     // Signal to measure
    output reg  [NUM_TAPS-1:0] therm_code, // Raw thermometer code (after bubble correction)
    output wire [7:0]        fine_bin      // Encoded bin index (0 to NUM_TAPS-1)
);

    // ========================================================================
    // Local Parameters
    // ========================================================================
    localparam NUM_CARRY8 = NUM_TAPS / 8;  // 32 CARRY8 cells

    // ========================================================================
    // Signal Declarations
    // ========================================================================

    // CARRY8 chain signals
    wire [NUM_TAPS-1:0] carry_chain;       // Carry-out taps from delay line
    wire [NUM_CARRY8-1:0] co_unused;       // Unused carry-out from each CARRY8

    // Sampling and pipeline registers
    reg  [NUM_TAPS-1:0] sample_reg;        // First-stage sampling flip-flops
    reg  [NUM_TAPS-1:0] pipe_reg;          // Pipeline register (metastability guard)

    // Bubble-corrected thermometer code
    wire [NUM_TAPS-1:0] corrected_therm;

    // ========================================================================
    // Stage 1: CARRY8-Based Tapped Delay Line
    // ========================================================================
    // Each CARRY8 primitive provides 8 carry-out taps. The event_in signal
    // enters at the bottom of the chain and propagates upward. The position
    // where the signal has not yet arrived (still 0) marks the time of arrival.
    //
    // CARRY8 configuration:
    //   - DI[7:0] = 8'hFF (force carry generation at each stage)
    //   - S[7:0]  = 8'h00 (select DI path, propagate carry)
    //   - CI      = carry input from previous stage (or event_in for first)
    //   - CO[7:0] = tapped outputs (the delay line taps)

    genvar i;
    generate
        for (i = 0; i < NUM_CARRY8; i = i + 1) begin : gen_carry8

            wire ci_in;

            if (i == 0) begin : gen_first
                assign ci_in = event_in;
            end else begin : gen_chain
                assign ci_in = carry_chain[(i*8)-1];
            end

            // Xilinx UltraScale+ CARRY8 primitive instantiation
            (* DONT_TOUCH = "TRUE" *)
            CARRY8 #(
                .CARRY_TYPE("SINGLE_CY8")  // Single 8-bit carry chain
            ) carry8_inst (
                .CO     (carry_chain[i*8 +: 8]),  // 8 carry-out taps
                .O      (),                        // XOR outputs (unused)
                .CI     (ci_in),                   // Carry input
                .CI_TOP (1'b0),                    // Top carry input (unused in SINGLE_CY8)
                .DI     (8'hFF),                   // Data input (force carry generation)
                .S      (8'h00)                    // Select input (propagate carry)
            );

        end
    endgenerate

    // ========================================================================
    // Stage 2: Thermometer Code Sampling with Pipeline Register
    // ========================================================================
    // Two-stage sampling:
    //   - sample_reg: captures the raw carry chain state on clock edge
    //   - pipe_reg:   provides metastability settling time (one extra cycle)

    always @(posedge clk) begin
        sample_reg <= carry_chain;
    end

    always @(posedge clk) begin
        pipe_reg <= sample_reg;
    end

    // ========================================================================
    // Stage 3: Bubble Correction Logic
    // ========================================================================
    // Metastability in the sampling flip-flops can create "bubbles" — isolated
    // 0s within a run of 1s, or isolated 1s within a run of 0s. A valid
    // thermometer code has the form: 111...1000...0 (1s at bottom, 0s at top).
    //
    // Correction strategy: 3-tap median filter
    //   - For each tap position (except boundaries), examine the tap and its
    //     two neighbors. If the center tap disagrees with both neighbors,
    //     correct it to match the neighbors (majority vote).
    //   - Boundary taps: use 2-tap agreement with their single neighbor.

    assign corrected_therm[0] = pipe_reg[0];  // Bottom boundary: keep as-is

    generate
        for (i = 1; i < NUM_TAPS - 1; i = i + 1) begin : gen_bubble_correct
            // Majority vote of 3 adjacent taps
            assign corrected_therm[i] = (pipe_reg[i-1] & pipe_reg[i])   |
                                        (pipe_reg[i]   & pipe_reg[i+1]) |
                                        (pipe_reg[i-1] & pipe_reg[i+1]);
        end
    endgenerate

    // Top boundary: keep as-is (or agree with neighbor below)
    assign corrected_therm[NUM_TAPS-1] = pipe_reg[NUM_TAPS-1];

    // Register the corrected thermometer code as output
    always @(posedge clk) begin
        therm_code <= corrected_therm;
    end

    // ========================================================================
    // Stage 4: Thermometer-to-Binary Priority Encoder
    // ========================================================================
    // The thermometer code has 1s from bit 0 up to some position, then 0s.
    // The fine_bin output is the index of the highest '1' bit (i.e., how far
    // the signal propagated through the delay line).
    //
    // Implementation: priority encoder scanning from MSB to LSB to find the
    // leading edge (first 0-to-1 transition from the top).
    //
    // For a 256-tap line, the output is 8 bits (0 to 255).

    reg [7:0] bin_encoded;

    // Hierarchical priority encoder for timing efficiency
    // Split into 16 groups of 16 taps, then encode within group

    wire [15:0] group_any;  // Each bit indicates if any tap is set in that 16-tap group
    wire [3:0]  group_idx;  // Index of highest active group
    wire [3:0]  tap_idx;    // Index within the highest active group

    // Determine which 16-tap groups have at least one '1'
    generate
        for (i = 0; i < 16; i = i + 1) begin : gen_group_any
            assign group_any[i] = |therm_code[i*16 +: 16];
        end
    endgenerate

    // Find the highest group with a '1' (priority encode from MSB)
    // This gives the upper 4 bits of the result
    function [3:0] priority_encode_16;
        input [15:0] val;
        reg [3:0] result;
        reg found;
        integer k;
        begin
            result = 4'd0;
            found = 1'b0;
            for (k = 15; k >= 0; k = k - 1) begin
                if (val[k] && !found) begin
                    result = k[3:0];
                    found = 1'b1;
                end
            end
            priority_encode_16 = result;
        end
    endfunction

    // Find the highest set bit within a 16-bit group
    function [3:0] priority_encode_16_inner;
        input [15:0] val;
        reg [3:0] result;
        reg found;
        integer k;
        begin
            result = 4'd0;
            found = 1'b0;
            for (k = 15; k >= 0; k = k - 1) begin
                if (val[k] && !found) begin
                    result = k[3:0];
                    found = 1'b1;
                end
            end
            priority_encode_16_inner = result;
        end
    endfunction

    assign group_idx = priority_encode_16(group_any);

    // Mux to select the 16-tap group for inner encoding
    // Use a registered mux to avoid variable-index part-select issues
    reg [15:0] selected_group;

    always @(*) begin
        case (group_idx)
            4'd0:  selected_group = therm_code[  0 +: 16];
            4'd1:  selected_group = therm_code[ 16 +: 16];
            4'd2:  selected_group = therm_code[ 32 +: 16];
            4'd3:  selected_group = therm_code[ 48 +: 16];
            4'd4:  selected_group = therm_code[ 64 +: 16];
            4'd5:  selected_group = therm_code[ 80 +: 16];
            4'd6:  selected_group = therm_code[ 96 +: 16];
            4'd7:  selected_group = therm_code[112 +: 16];
            4'd8:  selected_group = therm_code[128 +: 16];
            4'd9:  selected_group = therm_code[144 +: 16];
            4'd10: selected_group = therm_code[160 +: 16];
            4'd11: selected_group = therm_code[176 +: 16];
            4'd12: selected_group = therm_code[192 +: 16];
            4'd13: selected_group = therm_code[208 +: 16];
            4'd14: selected_group = therm_code[224 +: 16];
            4'd15: selected_group = therm_code[240 +: 16];
            default: selected_group = 16'd0;
        endcase
    end

    assign tap_idx = priority_encode_16_inner(selected_group);

    // Combine group index and tap index for final 8-bit result
    always @(posedge clk) begin
        if (|therm_code) begin
            bin_encoded <= {group_idx, tap_idx};
        end else begin
            // No taps set — event hasn't arrived or no event
            bin_encoded <= 8'd0;
        end
    end

    assign fine_bin = bin_encoded;

endmodule
