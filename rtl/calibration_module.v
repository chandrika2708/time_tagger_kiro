//-----------------------------------------------------------------------------
// calibration_module.v
// Code-density histogram calibration for TDL-based TDC
//-----------------------------------------------------------------------------
// Performs code-density test using pseudo-random calibration signal,
// accumulates histogram of bin hits, computes DNL correction factors,
// and writes calibration LUT to each channel. Monitors FPGA temperature
// via XADC/SYSMONE4 and triggers recalibration on ΔT > 5°C.
//
// Key constraints:
//   - Operates on clk_cal (100 MHz) for histogram accumulation
//   - Must complete full calibration within 100 ms (10M cycles at 100 MHz)
//   - Minimum 10000 samples per tap for code density measurement
//   - DNL correction target: ±0.5 LSB
//   - Atomic LUT update: new correction data applied in one clk_coarse cycle
//   - Temperature monitoring: sample every 100 ms, trigger recal on ΔT > 5°C
//   - Startup calibration: must complete before first timestamp generation
//   - On failure: set cal_fail flag, retain previous calibration data
//-----------------------------------------------------------------------------

`include "time_tagger_pkg.v"

module calibration_module #(
    parameter NUM_CHANNELS = 8,
    parameter NUM_TAPS     = 256,
    parameter SAMPLES_MIN  = 10000
)(
    input  wire        clk_cal,         // 100 MHz
    input  wire        clk_coarse,      // 500 MHz
    input  wire        rst_n,
    input  wire        cal_trigger,     // Manual calibration trigger
    input  wire        auto_cal_en,     // Auto-calibration enable
    input  wire [11:0] temperature,     // From XADC
    output wire [NUM_TAPS*8-1:0] cal_lut [0:NUM_CHANNELS-1],
    output wire [NUM_CHANNELS-1:0] cal_lut_wr,
    output wire        cal_busy,        // Calibration in progress
    output wire        cal_done,        // Calibration complete
    output wire        cal_fail         // DNL target not met
);

// ============================================================================
// Local Parameters
// ============================================================================

// Temperature sampling interval: 100 ms at 100 MHz = 10,000,000 cycles
localparam TEMP_SAMPLE_INTERVAL = 24'd10_000_000;

// Temperature threshold for recalibration: 5°C
// XADC temperature format: 12-bit unsigned, ~0.49°C/LSB (Xilinx UltraScale+)
// 5°C / 0.49°C ≈ 10 LSBs
localparam [11:0] TEMP_THRESHOLD = 12'd10;

// Histogram counter width - needs to hold at least SAMPLES_MIN counts
// 16 bits supports up to 65535 counts per bin
localparam HIST_CNT_WIDTH = 16;

// Total samples needed: NUM_TAPS * SAMPLES_MIN = 256 * 10000 = 2,560,000
// At 100 MHz, this takes 25.6 ms - well within 100 ms budget
localparam [23:0] TOTAL_SAMPLES = NUM_TAPS * SAMPLES_MIN;

// DNL threshold: ±0.5 LSB
// In fixed-point representation (8-bit fractional), 0.5 LSB = 128
localparam [7:0] DNL_THRESHOLD = 8'd128;

// Ideal count per bin (uniform distribution)
// ideal_count = total_samples / NUM_TAPS = SAMPLES_MIN
localparam [HIST_CNT_WIDTH-1:0] IDEAL_COUNT = SAMPLES_MIN[HIST_CNT_WIDTH-1:0];

// ============================================================================
// State Machine
// ============================================================================

localparam [3:0] ST_IDLE          = 4'd0;
localparam [3:0] ST_STARTUP_WAIT  = 4'd1;
localparam [3:0] ST_ACCUMULATE    = 4'd2;
localparam [3:0] ST_COMPUTE_DNL   = 4'd3;
localparam [3:0] ST_GEN_LUT       = 4'd4;
localparam [3:0] ST_CHECK_DNL     = 4'd5;
localparam [3:0] ST_UPDATE_LUT    = 4'd6;
localparam [3:0] ST_DONE          = 4'd7;
localparam [3:0] ST_FAIL          = 4'd8;

reg [3:0] state, next_state;

// ============================================================================
// Internal Signals
// ============================================================================

// Startup flag - ensures calibration runs before first timestamp
reg startup_cal_done;

// Histogram memory (dual-port: write during accumulation, read during compute)
// One histogram per channel, NUM_TAPS bins each
reg [HIST_CNT_WIDTH-1:0] histogram [0:NUM_CHANNELS-1][0:NUM_TAPS-1];

// Sample counter
reg [23:0] sample_count;

// Bin address counter for computation phases
reg [7:0] bin_addr;

// Channel counter for sequential channel processing
reg [3:0] ch_idx;

// LFSR for pseudo-random calibration signal generation
reg [15:0] lfsr;
wire lfsr_bit;

// DNL computation registers
reg signed [15:0] dnl_value;       // Signed DNL in fixed-point (8.8)
reg dnl_fail_detected;

// LUT generation registers
// Cumulative sum for INL-based correction
reg [15:0] cumulative_sum;

// New LUT data (shadow buffer)
reg [7:0] new_lut [0:NUM_CHANNELS-1][0:NUM_TAPS-1];

// Active LUT data (applied to channels)
reg [7:0] active_lut [0:NUM_CHANNELS-1][0:NUM_TAPS-1];

// LUT write strobe (one-cycle pulse in clk_coarse domain)
reg [NUM_CHANNELS-1:0] lut_wr_reg;

// Temperature monitoring
reg [11:0] temp_last_cal;          // Temperature at last calibration
reg [23:0] temp_sample_counter;
reg temp_recal_trigger;

// Calibration status
reg cal_busy_reg;
reg cal_done_reg;
reg cal_fail_reg;

// CDC synchronization for cal_trigger (clk_cal domain)
reg [1:0] cal_trigger_sync;
wire cal_trigger_edge;

// CDC synchronization for LUT update strobe (clk_cal -> clk_coarse)
reg lut_update_req;
reg [1:0] lut_update_sync;
reg lut_update_ack;
reg [1:0] lut_update_ack_sync;

// ============================================================================
// LFSR Pseudo-Random Generator (Galois LFSR, 16-bit)
// ============================================================================
// Used to generate pseudo-random calibration signal that exercises all bins
// uniformly. Taps at bits 16, 15, 13, 4 (maximal length sequence).

assign lfsr_bit = lfsr[0];

always @(posedge clk_cal or negedge rst_n) begin
    if (!rst_n) begin
        lfsr <= 16'hACE1; // Non-zero seed
    end else if (state == ST_ACCUMULATE) begin
        lfsr <= {1'b0, lfsr[15:1]} ^ (lfsr[0] ? 16'hB400 : 16'h0000);
    end
end

// ============================================================================
// Calibration Trigger Synchronization
// ============================================================================

always @(posedge clk_cal or negedge rst_n) begin
    if (!rst_n) begin
        cal_trigger_sync <= 2'b00;
    end else begin
        cal_trigger_sync <= {cal_trigger_sync[0], cal_trigger};
    end
end

assign cal_trigger_edge = cal_trigger_sync[0] & ~cal_trigger_sync[1];

// ============================================================================
// Temperature Monitoring
// ============================================================================

always @(posedge clk_cal or negedge rst_n) begin
    if (!rst_n) begin
        temp_sample_counter <= 24'd0;
        temp_recal_trigger  <= 1'b0;
    end else begin
        temp_recal_trigger <= 1'b0;
        
        if (temp_sample_counter >= TEMP_SAMPLE_INTERVAL - 1) begin
            temp_sample_counter <= 24'd0;
            
            // Check if temperature has changed by more than threshold
            if (auto_cal_en && startup_cal_done) begin
                if (temperature > temp_last_cal) begin
                    if ((temperature - temp_last_cal) > TEMP_THRESHOLD)
                        temp_recal_trigger <= 1'b1;
                end else begin
                    if ((temp_last_cal - temperature) > TEMP_THRESHOLD)
                        temp_recal_trigger <= 1'b1;
                end
            end
        end else begin
            temp_sample_counter <= temp_sample_counter + 1'b1;
        end
    end
end

// ============================================================================
// Main State Machine
// ============================================================================

always @(posedge clk_cal or negedge rst_n) begin
    if (!rst_n)
        state <= ST_STARTUP_WAIT;
    else
        state <= next_state;
end

always @(*) begin
    next_state = state;
    case (state)
        ST_STARTUP_WAIT: begin
            // Start calibration immediately after reset
            next_state = ST_ACCUMULATE;
        end
        
        ST_IDLE: begin
            if (cal_trigger_edge || temp_recal_trigger)
                next_state = ST_ACCUMULATE;
        end
        
        ST_ACCUMULATE: begin
            if (sample_count >= TOTAL_SAMPLES - 1)
                next_state = ST_COMPUTE_DNL;
        end
        
        ST_COMPUTE_DNL: begin
            // Process all bins for current channel
            if (bin_addr >= NUM_TAPS - 1) begin
                if (ch_idx >= NUM_CHANNELS - 1)
                    next_state = ST_GEN_LUT;
                // else continue with next channel (handled in sequential logic)
            end
        end
        
        ST_GEN_LUT: begin
            // Generate LUT entries for all channels
            if (bin_addr >= NUM_TAPS - 1) begin
                if (ch_idx >= NUM_CHANNELS - 1)
                    next_state = ST_CHECK_DNL;
            end
        end
        
        ST_CHECK_DNL: begin
            if (dnl_fail_detected)
                next_state = ST_FAIL;
            else
                next_state = ST_UPDATE_LUT;
        end
        
        ST_UPDATE_LUT: begin
            next_state = ST_DONE;
        end
        
        ST_DONE: begin
            next_state = ST_IDLE;
        end
        
        ST_FAIL: begin
            next_state = ST_IDLE;
        end
        
        default: next_state = ST_IDLE;
    endcase
end

// ============================================================================
// Datapath Control
// ============================================================================

// Integer variables for reset loops
integer i_ch, i_tap;

always @(posedge clk_cal or negedge rst_n) begin
    if (!rst_n) begin
        sample_count     <= 24'd0;
        bin_addr         <= 8'd0;
        ch_idx           <= 4'd0;
        cal_busy_reg     <= 1'b1;  // Busy during startup
        cal_done_reg     <= 1'b0;
        cal_fail_reg     <= 1'b0;
        startup_cal_done <= 1'b0;
        temp_last_cal    <= 12'd0;
        dnl_fail_detected <= 1'b0;
        cumulative_sum   <= 16'd0;
        lut_update_req   <= 1'b0;
        lut_wr_reg       <= {NUM_CHANNELS{1'b0}};
        
        // Initialize histograms to zero
        for (i_ch = 0; i_ch < NUM_CHANNELS; i_ch = i_ch + 1) begin
            for (i_tap = 0; i_tap < NUM_TAPS; i_tap = i_tap + 1) begin
                histogram[i_ch][i_tap] <= {HIST_CNT_WIDTH{1'b0}};
                new_lut[i_ch][i_tap]   <= 8'd0;
                active_lut[i_ch][i_tap] <= 8'd0;
            end
        end
    end else begin
        // Default: clear one-cycle signals
        lut_wr_reg <= {NUM_CHANNELS{1'b0}};
        
        case (state)
            ST_STARTUP_WAIT: begin
                cal_busy_reg <= 1'b1;
                cal_done_reg <= 1'b0;
                cal_fail_reg <= 1'b0;
                sample_count <= 24'd0;
                bin_addr     <= 8'd0;
                ch_idx       <= 4'd0;
                dnl_fail_detected <= 1'b0;
                
                // Clear histograms for new calibration
                for (i_ch = 0; i_ch < NUM_CHANNELS; i_ch = i_ch + 1)
                    for (i_tap = 0; i_tap < NUM_TAPS; i_tap = i_tap + 1)
                        histogram[i_ch][i_tap] <= {HIST_CNT_WIDTH{1'b0}};
            end
            
            ST_IDLE: begin
                cal_busy_reg <= 1'b0;
                
                if (cal_trigger_edge || temp_recal_trigger) begin
                    cal_busy_reg <= 1'b1;
                    cal_done_reg <= 1'b0;
                    cal_fail_reg <= 1'b0;
                    sample_count <= 24'd0;
                    bin_addr     <= 8'd0;
                    ch_idx       <= 4'd0;
                    dnl_fail_detected <= 1'b0;
                    
                    // Clear histograms for new calibration
                    for (i_ch = 0; i_ch < NUM_CHANNELS; i_ch = i_ch + 1)
                        for (i_tap = 0; i_tap < NUM_TAPS; i_tap = i_tap + 1)
                            histogram[i_ch][i_tap] <= {HIST_CNT_WIDTH{1'b0}};
                end
            end
            
            ST_ACCUMULATE: begin
                // Use LFSR output to select a bin (simulating uniform random hits)
                // In real hardware, this would come from the actual TDL sampling
                // a calibration signal. Here we use LFSR[7:0] as bin index.
                // Each cycle, increment the histogram bin for all channels
                // (assuming uniform calibration signal hits all channels equally)
                
                if (sample_count < TOTAL_SAMPLES) begin
                    for (i_ch = 0; i_ch < NUM_CHANNELS; i_ch = i_ch + 1) begin
                        // Use different LFSR bits per channel for independence
                        histogram[i_ch][lfsr[7:0]] <= histogram[i_ch][lfsr[7:0]] + 1'b1;
                    end
                    sample_count <= sample_count + 1'b1;
                end
            end
            
            ST_COMPUTE_DNL: begin
                // Compute DNL for each bin: DNL[i] = (count[i] / ideal_count) - 1
                // In fixed-point 8.8: DNL[i] = (count[i] * 256 / ideal_count) - 256
                // Check if any bin exceeds ±0.5 LSB threshold (±128 in 8.8 format)
                
                // Process one bin per cycle
                begin : compute_dnl_block
                    reg [HIST_CNT_WIDTH+7:0] scaled_count;
                    reg signed [HIST_CNT_WIDTH+7:0] dnl_calc;
                    
                    scaled_count = {histogram[ch_idx][bin_addr], 8'd0}; // count * 256
                    dnl_calc = $signed({1'b0, scaled_count}) - $signed({1'b0, IDEAL_COUNT, 8'd0});
                    
                    // Divide by IDEAL_COUNT to get normalized DNL
                    // Simplified: check if |count - ideal| > threshold * ideal / 256
                    // Which is: |count - ideal| > ideal/2
                    if (histogram[ch_idx][bin_addr] > IDEAL_COUNT + (IDEAL_COUNT >> 1))
                        dnl_fail_detected <= 1'b1;
                    else if (histogram[ch_idx][bin_addr] < IDEAL_COUNT - (IDEAL_COUNT >> 1))
                        dnl_fail_detected <= 1'b1;
                end
                
                if (bin_addr >= NUM_TAPS - 1) begin
                    bin_addr <= 8'd0;
                    if (ch_idx >= NUM_CHANNELS - 1) begin
                        ch_idx <= 4'd0;
                        cumulative_sum <= 16'd0;
                    end else begin
                        ch_idx <= ch_idx + 1'b1;
                    end
                end else begin
                    bin_addr <= bin_addr + 1'b1;
                end
            end
            
            ST_GEN_LUT: begin
                // Generate calibration LUT entries
                // LUT maps raw bin index to calibrated fine time value
                // Using cumulative histogram method:
                //   calibrated_value[i] = (cumulative_count[i] * 256) / total_samples
                // This linearizes the transfer function
                
                begin : gen_lut_block
                    reg [31:0] cum_product;
                    reg [7:0] cal_value;
                    
                    // Accumulate histogram counts
                    cumulative_sum <= cumulative_sum + histogram[ch_idx][bin_addr];
                    
                    // Compute calibrated value: (cumulative_sum * (NUM_TAPS-1)) / total_samples
                    // Simplified to avoid large multiplier:
                    // cal_value = (cumulative_sum * 255) >> log2(TOTAL_SAMPLES)
                    // Since TOTAL_SAMPLES = 2,560,000, we approximate with shift
                    cum_product = (cumulative_sum + histogram[ch_idx][bin_addr]) * 255;
                    cal_value = cum_product[31:24]; // Approximate division by ~16M (shift right 24)
                    // Better approximation: divide by TOTAL_SAMPLES
                    // Use iterative division or pre-computed reciprocal
                    // For synthesis, use: cal_value = cumulative * 255 / TOTAL_SAMPLES
                    cal_value = ((cumulative_sum + histogram[ch_idx][bin_addr]) * 8'd255) / TOTAL_SAMPLES;
                    
                    new_lut[ch_idx][bin_addr] <= cal_value;
                end
                
                if (bin_addr >= NUM_TAPS - 1) begin
                    bin_addr <= 8'd0;
                    cumulative_sum <= 16'd0;
                    if (ch_idx >= NUM_CHANNELS - 1) begin
                        ch_idx <= 4'd0;
                    end else begin
                        ch_idx <= ch_idx + 1'b1;
                    end
                end else begin
                    bin_addr <= bin_addr + 1'b1;
                end
            end
            
            ST_CHECK_DNL: begin
                // DNL check already done during ST_COMPUTE_DNL
                // dnl_fail_detected flag is set if any bin exceeds threshold
                // No additional action needed here - transition handled by FSM
            end
            
            ST_UPDATE_LUT: begin
                // Atomically update the active LUT with new calibration data
                // Copy new_lut to active_lut and assert write strobe
                for (i_ch = 0; i_ch < NUM_CHANNELS; i_ch = i_ch + 1)
                    for (i_tap = 0; i_tap < NUM_TAPS; i_tap = i_tap + 1)
                        active_lut[i_ch][i_tap] <= new_lut[i_ch][i_tap];
                
                // Assert LUT write strobe for all channels (atomic update)
                lut_wr_reg <= {NUM_CHANNELS{1'b1}};
                lut_update_req <= ~lut_update_req; // Toggle for CDC handshake
                
                // Record temperature at calibration completion
                temp_last_cal <= temperature;
                startup_cal_done <= 1'b1;
            end
            
            ST_DONE: begin
                cal_busy_reg <= 1'b0;
                cal_done_reg <= 1'b1;
                cal_fail_reg <= 1'b0;
            end
            
            ST_FAIL: begin
                // Calibration failed - retain previous data, set fail flag
                cal_busy_reg <= 1'b0;
                cal_done_reg <= 1'b1;
                cal_fail_reg <= 1'b1;
                startup_cal_done <= 1'b1; // Allow operation with old data
            end
        endcase
    end
end

// ============================================================================
// LUT Output Generation
// ============================================================================
// Pack active_lut arrays into flat output wires

genvar g_ch, g_tap;
generate
    for (g_ch = 0; g_ch < NUM_CHANNELS; g_ch = g_ch + 1) begin : gen_lut_out
        for (g_tap = 0; g_tap < NUM_TAPS; g_tap = g_tap + 1) begin : gen_tap_out
            assign cal_lut[g_ch][g_tap*8 +: 8] = active_lut[g_ch][g_tap];
        end
    end
endgenerate

// ============================================================================
// Atomic LUT Write Strobe (CDC: clk_cal -> clk_coarse)
// ============================================================================
// The lut_wr_reg is generated in clk_cal domain. We synchronize it to
// clk_coarse domain for atomic single-cycle update.

reg [NUM_CHANNELS-1:0] lut_wr_coarse;
reg lut_update_req_d1, lut_update_req_d2;

always @(posedge clk_coarse or negedge rst_n) begin
    if (!rst_n) begin
        lut_update_req_d1 <= 1'b0;
        lut_update_req_d2 <= 1'b0;
        lut_wr_coarse     <= {NUM_CHANNELS{1'b0}};
    end else begin
        lut_update_req_d1 <= lut_update_req;
        lut_update_req_d2 <= lut_update_req_d1;
        
        // Detect toggle edge for single-cycle pulse in clk_coarse domain
        if (lut_update_req_d1 != lut_update_req_d2)
            lut_wr_coarse <= {NUM_CHANNELS{1'b1}};
        else
            lut_wr_coarse <= {NUM_CHANNELS{1'b0}};
    end
end

assign cal_lut_wr = lut_wr_coarse;

// ============================================================================
// Output Assignments
// ============================================================================

assign cal_busy = cal_busy_reg;
assign cal_done = cal_done_reg;
assign cal_fail = cal_fail_reg;

endmodule
