//-----------------------------------------------------------------------------
// rate_monitor.v
// Rate Monitoring and Error Detection Module for the FPGA Time Tagger
//-----------------------------------------------------------------------------
// This module implements:
//   1. 16-bit tag-rate counter per channel (tags per 1 ms interval)
//   2. Rate-overflow flag assertion within 10 µs when sustained rate exceeds
//      80 Mtags/s for >1 µs
//   3. Rate-overflow flag clearing within 10 µs when rate drops below threshold
//   4. 32-bit saturating error counters for CDC errors
//   5. Channel status state machine (enabled/disabled/overflow/error)
//
// Requirements: 9.4, 9.5, 10.1, 10.2, 10.3, 10.5
//-----------------------------------------------------------------------------

`include "time_tagger_pkg.v"

module rate_monitor #(
    parameter NUM_CHANNELS = `NUM_CHANNELS  // 8
)(
    // ========================================================================
    // Clock and Reset
    // ========================================================================
    input  wire        clk_coarse,        // 500 MHz system clock
    input  wire        rst_n,             // Active-low reset

    // ========================================================================
    // Tag Event Inputs (from TDC channels)
    // ========================================================================
    input  wire [NUM_CHANNELS-1:0] tag_valid,     // Per-channel tag valid strobes
    input  wire [NUM_CHANNELS-1:0] ch_enable,     // Per-channel enable from config

    // ========================================================================
    // Error Inputs
    // ========================================================================
    input  wire [NUM_CHANNELS-1:0] cdc_error,     // Per-channel CDC error pulse
    input  wire [NUM_CHANNELS-1:0] fifo_overflow, // Per-channel FIFO overflow flag

    // ========================================================================
    // Control Inputs
    // ========================================================================
    input  wire        err_clear_strobe,  // Clear all error flags and counters

    // ========================================================================
    // Status Outputs (to AXI register file)
    // ========================================================================
    output wire [31:0] tag_rate [0:NUM_CHANNELS-1],    // Per-channel tag rate (16-bit in [15:0])
    output wire [31:0] err_count [0:NUM_CHANNELS-1],   // Per-channel 32-bit error counters
    output wire [31:0] ch_status [0:NUM_CHANNELS-1],   // Per-channel status (2-bit state in [1:0])
    output reg         rate_ovf_flag                    // Global rate overflow flag
);

// ============================================================================
// Local Parameters
// ============================================================================

// At 500 MHz, 1 ms = 500,000 clock cycles
localparam INTERVAL_1MS_CYCLES = 500_000;
// Counter width to count up to 500,000
localparam INTERVAL_CNT_BITS   = 19;

// Rate overflow threshold: 80 Mtags/s across all channels
// At 500 MHz, 1 µs = 500 cycles
// 80 Mtags/s = 80 tags per µs = 80 tags per 500 cycles (aggregate)
// We use a sliding window of 500 cycles (1 µs) to measure aggregate rate
localparam RATE_WINDOW_CYCLES  = 500;
localparam RATE_WINDOW_BITS    = 9;  // ceil(log2(500))

// Threshold: 80 tags in 500 cycles (80 Mtags/s aggregate)
localparam RATE_OVF_THRESHOLD  = 80;

// Sustain duration: must exceed threshold for >1 µs = >500 cycles
localparam SUSTAIN_CYCLES      = 500;
localparam SUSTAIN_CNT_BITS    = 10;

// Assert/clear deadline: 10 µs = 5000 cycles (we assert/clear immediately
// once the sustain condition is met, well within the 10 µs deadline)

// Channel status encoding
localparam CH_STATE_ENABLED  = 2'b00;
localparam CH_STATE_DISABLED = 2'b01;
localparam CH_STATE_OVERFLOW = 2'b10;
localparam CH_STATE_ERROR    = 2'b11;

// ============================================================================
// 1. Tag Rate Counter (16-bit per channel, 1 ms interval)
// ============================================================================
// Each channel has a running counter that counts tags during the current 1 ms
// interval. At the end of each interval, the count is latched to the output
// register and the running counter resets.

reg [INTERVAL_CNT_BITS-1:0] interval_counter;  // Shared 1 ms interval timer
reg                          interval_tick;     // Pulse at end of each 1 ms

// Per-channel running tag counters (16-bit, saturating)
reg [15:0] tag_count_running [0:NUM_CHANNELS-1];
// Per-channel latched tag rate (output)
reg [15:0] tag_rate_latched [0:NUM_CHANNELS-1];

// Interval timer (shared across all channels)
always @(posedge clk_coarse or negedge rst_n) begin
    if (!rst_n) begin
        interval_counter <= {INTERVAL_CNT_BITS{1'b0}};
        interval_tick    <= 1'b0;
    end else begin
        if (interval_counter == INTERVAL_1MS_CYCLES - 1) begin
            interval_counter <= {INTERVAL_CNT_BITS{1'b0}};
            interval_tick    <= 1'b1;
        end else begin
            interval_counter <= interval_counter + 1'b1;
            interval_tick    <= 1'b0;
        end
    end
end

// Per-channel tag rate counting
genvar ch;
generate
    for (ch = 0; ch < NUM_CHANNELS; ch = ch + 1) begin : gen_tag_rate
        always @(posedge clk_coarse or negedge rst_n) begin
            if (!rst_n) begin
                tag_count_running[ch] <= 16'h0;
                tag_rate_latched[ch]  <= 16'h0;
            end else begin
                if (interval_tick) begin
                    // Latch current count and reset
                    tag_rate_latched[ch]  <= tag_count_running[ch];
                    // If a tag arrives on the same cycle as the tick, count it
                    // in the new interval
                    tag_count_running[ch] <= tag_valid[ch] ? 16'h1 : 16'h0;
                end else if (tag_valid[ch]) begin
                    // Saturating increment
                    if (tag_count_running[ch] != 16'hFFFF) begin
                        tag_count_running[ch] <= tag_count_running[ch] + 1'b1;
                    end
                end
            end
        end

        // Output assignment: tag rate in lower 16 bits
        assign tag_rate[ch] = {16'h0, tag_rate_latched[ch]};
    end
endgenerate

// ============================================================================
// 2. Rate Overflow Detection
// ============================================================================
// Monitors aggregate tag rate across all channels using a sliding window.
// If the aggregate rate exceeds 80 Mtags/s (80 tags per 500 cycles) sustained
// for more than 1 µs (500 cycles), assert the rate_ovf_flag.
// Clear the flag when the rate drops below threshold for >1 µs.

// Aggregate tag count in current measurement window
reg [RATE_WINDOW_BITS-1:0] window_counter;  // Cycles within current window
reg [7:0]                  window_tag_count; // Tags counted in current window
                                             // (max 80 threshold, 8 bits enough)

// Sustain counters for assertion and clearing
reg [SUSTAIN_CNT_BITS-1:0] ovf_sustain_counter;   // Counts consecutive windows above threshold
reg [SUSTAIN_CNT_BITS-1:0] clear_sustain_counter;  // Counts consecutive windows below threshold
reg                         window_exceeded;        // Current window exceeded threshold

// Count aggregate tags this cycle
wire [3:0] aggregate_tags;
assign aggregate_tags = tag_valid[0] + tag_valid[1] + tag_valid[2] + tag_valid[3] +
                        tag_valid[4] + tag_valid[5] + tag_valid[6] + tag_valid[7];

always @(posedge clk_coarse or negedge rst_n) begin
    if (!rst_n) begin
        window_counter       <= {RATE_WINDOW_BITS{1'b0}};
        window_tag_count     <= 8'h0;
        window_exceeded      <= 1'b0;
        ovf_sustain_counter  <= {SUSTAIN_CNT_BITS{1'b0}};
        clear_sustain_counter <= {SUSTAIN_CNT_BITS{1'b0}};
        rate_ovf_flag        <= 1'b0;
    end else if (err_clear_strobe) begin
        // Clear rate overflow flag on error clear
        window_counter       <= {RATE_WINDOW_BITS{1'b0}};
        window_tag_count     <= 8'h0;
        window_exceeded      <= 1'b0;
        ovf_sustain_counter  <= {SUSTAIN_CNT_BITS{1'b0}};
        clear_sustain_counter <= {SUSTAIN_CNT_BITS{1'b0}};
        rate_ovf_flag        <= 1'b0;
    end else begin
        if (window_counter == RATE_WINDOW_CYCLES - 1) begin
            // End of measurement window
            window_counter <= {RATE_WINDOW_BITS{1'b0}};

            // Check if this window exceeded the threshold
            // Include tags arriving this cycle
            if ((window_tag_count + {4'b0, aggregate_tags}) >= RATE_OVF_THRESHOLD[7:0]) begin
                window_exceeded <= 1'b1;
            end else begin
                window_exceeded <= 1'b0;
            end

            // Reset tag count for next window (include current cycle's tags)
            window_tag_count <= 8'h0;
        end else begin
            window_counter <= window_counter + 1'b1;
            // Accumulate tags (saturate at 255 to prevent overflow of 8-bit counter)
            if ((window_tag_count + {4'b0, aggregate_tags}) <= 8'hFF) begin
                window_tag_count <= window_tag_count + {4'b0, aggregate_tags};
            end else begin
                window_tag_count <= 8'hFF;
            end
        end

        // Sustain logic for flag assertion
        if (window_exceeded) begin
            clear_sustain_counter <= {SUSTAIN_CNT_BITS{1'b0}};
            if (ovf_sustain_counter < SUSTAIN_CYCLES) begin
                ovf_sustain_counter <= ovf_sustain_counter + 1'b1;
            end
            // Assert flag once sustained for >1 µs (>500 cycles counted in windows)
            if (ovf_sustain_counter >= SUSTAIN_CYCLES - 1) begin
                rate_ovf_flag <= 1'b1;
            end
        end else begin
            ovf_sustain_counter <= {SUSTAIN_CNT_BITS{1'b0}};
            if (rate_ovf_flag) begin
                // Count cycles below threshold for clearing
                if (clear_sustain_counter < SUSTAIN_CYCLES) begin
                    clear_sustain_counter <= clear_sustain_counter + 1'b1;
                end
                // Clear flag once sustained below threshold for >1 µs
                if (clear_sustain_counter >= SUSTAIN_CYCLES - 1) begin
                    rate_ovf_flag <= 1'b0;
                    clear_sustain_counter <= {SUSTAIN_CNT_BITS{1'b0}};
                end
            end else begin
                clear_sustain_counter <= {SUSTAIN_CNT_BITS{1'b0}};
            end
        end
    end
end

// ============================================================================
// 3. 32-bit Saturating Error Counters
// ============================================================================
// Per-channel error counter that increments on CDC error detection.
// Saturates at 0xFFFFFFFF (does not wrap).
// Cleared by err_clear_strobe (write to STATUS register).

reg [31:0] error_counter [0:NUM_CHANNELS-1];
reg [NUM_CHANNELS-1:0] error_flag;  // Sticky error flag per channel

generate
    for (ch = 0; ch < NUM_CHANNELS; ch = ch + 1) begin : gen_err_count
        always @(posedge clk_coarse or negedge rst_n) begin
            if (!rst_n) begin
                error_counter[ch] <= 32'h0;
                error_flag[ch]    <= 1'b0;
            end else if (err_clear_strobe) begin
                // Clear error counter and flag on status register write
                error_counter[ch] <= 32'h0;
                error_flag[ch]    <= 1'b0;
            end else if (cdc_error[ch]) begin
                // Set error flag
                error_flag[ch] <= 1'b1;
                // Saturating increment
                if (error_counter[ch] != 32'hFFFF_FFFF) begin
                    error_counter[ch] <= error_counter[ch] + 1'b1;
                end
            end
        end

        // Output assignment
        assign err_count[ch] = error_counter[ch];
    end
endgenerate

// ============================================================================
// 4. Channel Status State Machine
// ============================================================================
// Per-channel state machine with 4 states:
//   - enabled  (2'b00): Channel is active and operating normally
//   - disabled (2'b01): Channel is not enabled
//   - overflow (2'b10): Channel FIFO has overflowed
//   - error    (2'b11): CDC error or Fine_Interpolator out-of-range detected
//
// Priority (highest to lowest): error > overflow > disabled > enabled
// Transitions:
//   - disabled: when ch_enable[ch] is deasserted
//   - error:    when cdc_error[ch] is detected (sticky until cleared)
//   - overflow: when fifo_overflow[ch] is asserted
//   - enabled:  when channel is enabled and no error/overflow conditions

reg [1:0] channel_state [0:NUM_CHANNELS-1];

generate
    for (ch = 0; ch < NUM_CHANNELS; ch = ch + 1) begin : gen_ch_status
        always @(posedge clk_coarse or negedge rst_n) begin
            if (!rst_n) begin
                channel_state[ch] <= CH_STATE_DISABLED;
            end else if (err_clear_strobe) begin
                // On error clear, re-evaluate state based on current conditions
                if (!ch_enable[ch]) begin
                    channel_state[ch] <= CH_STATE_DISABLED;
                end else if (fifo_overflow[ch]) begin
                    channel_state[ch] <= CH_STATE_OVERFLOW;
                end else begin
                    channel_state[ch] <= CH_STATE_ENABLED;
                end
            end else begin
                // Priority-based state determination
                if (!ch_enable[ch]) begin
                    channel_state[ch] <= CH_STATE_DISABLED;
                end else if (error_flag[ch]) begin
                    channel_state[ch] <= CH_STATE_ERROR;
                end else if (fifo_overflow[ch]) begin
                    channel_state[ch] <= CH_STATE_OVERFLOW;
                end else begin
                    channel_state[ch] <= CH_STATE_ENABLED;
                end
            end
        end

        // Output assignment: channel status in lower 2 bits
        assign ch_status[ch] = {30'h0, channel_state[ch]};
    end
endgenerate

endmodule
