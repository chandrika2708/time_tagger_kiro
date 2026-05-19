//-----------------------------------------------------------------------------
// coincidence_detector.v
// Hardware coincidence detection for correlated photon pair identification
//-----------------------------------------------------------------------------
// Supports 4 independent coincidence groups, each configurable with any
// subset of 8 channels. Uses a pipelined comparator tree to identify events
// within a programmable sliding window (100 ps to 10 ns in 10 ps steps).
// Generates coincidence Tag_Records within 8 coarse clock cycles of the last
// participating event. Operates on copies of tag data so it does not reduce
// maximum event rate on any channel.
//-----------------------------------------------------------------------------

`include "time_tagger_pkg.v"

module coincidence_detector #(
    parameter NUM_CHANNELS = 8,
    parameter NUM_GROUPS   = 4,
    parameter WINDOW_BITS  = 10   // 10 bits for window value (0-1023 × 10ps)
)(
    input  wire        clk_coarse,
    input  wire        rst_n,
    // Tag inputs (copies - does not consume originals)
    input  wire [95:0] tag_in [NUM_CHANNELS-1:0],
    input  wire [NUM_CHANNELS-1:0] tag_valid_in,
    // Group configuration
    input  wire [NUM_CHANNELS-1:0] group_mask [NUM_GROUPS-1:0],
    input  wire [WINDOW_BITS-1:0]  window [NUM_GROUPS-1:0],
    input  wire [NUM_GROUPS-1:0]   group_enable,
    // Outputs
    output wire [95:0] coinc_tag,
    output wire        coinc_valid,
    output wire        config_error   // Window out of range
);

// ============================================================================
// Local Parameters
// ============================================================================

// Window range validation: valid range is 10 to 1000 (100 ps to 10 ns in 10 ps steps)
localparam [WINDOW_BITS-1:0] WINDOW_MIN = 10'd10;
localparam [WINDOW_BITS-1:0] WINDOW_MAX = 10'd1000;

// Special channel ID for coincidence records
localparam [7:0] COINC_CHANNEL_ID = 8'hFF;

// ============================================================================
// Window Validation (combinational with registered output)
// ============================================================================

reg [NUM_GROUPS-1:0] window_valid_reg;
reg config_error_reg;

wire [NUM_GROUPS-1:0] window_in_range;

genvar gv;
generate
    for (gv = 0; gv < NUM_GROUPS; gv = gv + 1) begin : gen_window_check
        assign window_in_range[gv] = (window[gv] >= WINDOW_MIN) &&
                                     (window[gv] <= WINDOW_MAX);
    end
endgenerate

always @(posedge clk_coarse or negedge rst_n) begin
    if (!rst_n) begin
        window_valid_reg <= {NUM_GROUPS{1'b0}};
        config_error_reg <= 1'b0;
    end else begin
        config_error_reg <= 1'b0;
        for (integer g = 0; g < NUM_GROUPS; g = g + 1) begin
            if (group_enable[g]) begin
                window_valid_reg[g] <= window_in_range[g];
                if (!window_in_range[g]) begin
                    config_error_reg <= 1'b1;
                end
            end else begin
                window_valid_reg[g] <= 1'b0;
            end
        end
    end
end

assign config_error = config_error_reg;

// ============================================================================
// Pipeline Stage 1: Register input tags and valid signals
// (Operates on copies of tag data - does not affect source throughput)
// ============================================================================

reg [95:0] tag_s1 [NUM_CHANNELS-1:0];
reg [NUM_CHANNELS-1:0] valid_s1;

always @(posedge clk_coarse or negedge rst_n) begin
    if (!rst_n) begin
        valid_s1 <= {NUM_CHANNELS{1'b0}};
        for (integer i = 0; i < NUM_CHANNELS; i = i + 1) begin
            tag_s1[i] <= 96'd0;
        end
    end else begin
        valid_s1 <= tag_valid_in;
        for (integer i = 0; i < NUM_CHANNELS; i = i + 1) begin
            tag_s1[i] <= tag_in[i];
        end
    end
end

// ============================================================================
// Pipeline Stage 2: Extract 64-bit timestamps from registered tags
// ============================================================================

reg [63:0] timestamp_s2 [NUM_CHANNELS-1:0];
reg [NUM_CHANNELS-1:0] valid_s2;

always @(posedge clk_coarse or negedge rst_n) begin
    if (!rst_n) begin
        valid_s2 <= {NUM_CHANNELS{1'b0}};
        for (integer i = 0; i < NUM_CHANNELS; i = i + 1) begin
            timestamp_s2[i] <= 64'd0;
        end
    end else begin
        valid_s2 <= valid_s1;
        for (integer i = 0; i < NUM_CHANNELS; i = i + 1) begin
            timestamp_s2[i] <= tag_s1[i][`TAG_TIMESTAMP_MSB:`TAG_TIMESTAMP_LSB];
        end
    end
end

// ============================================================================
// Pipeline Stage 3: Compute min and max timestamps per group
// Uses combinational reduction tree, then registers the result.
// ============================================================================

// Combinational min/max computation per group
wire [63:0] ts_min_comb [NUM_GROUPS-1:0];
wire [63:0] ts_max_comb [NUM_GROUPS-1:0];
wire [NUM_CHANNELS-1:0] group_active_comb [NUM_GROUPS-1:0];
wire [3:0] active_count_comb [NUM_GROUPS-1:0];

generate
    for (gv = 0; gv < NUM_GROUPS; gv = gv + 1) begin : gen_minmax
        // Determine which channels are active in this group
        wire [NUM_CHANNELS-1:0] ch_active;
        assign ch_active = group_mask[gv] & valid_s2;
        assign group_active_comb[gv] = ch_active;

        // Count active channels
        wire [3:0] cnt;
        assign cnt = ch_active[0] + ch_active[1] + ch_active[2] + ch_active[3] +
                     ch_active[4] + ch_active[5] + ch_active[6] + ch_active[7];
        assign active_count_comb[gv] = cnt;

        // Min/max tree using intermediate wires
        // Layer 1: pairs (0,1), (2,3), (4,5), (6,7)
        wire [63:0] min_01, min_23, min_45, min_67;
        wire [63:0] max_01, max_23, max_45, max_67;

        // Helper: select valid timestamp or sentinel for min/max
        // For min: inactive channels get MAX sentinel (won't affect minimum)
        // For max: inactive channels get 0 sentinel (won't affect maximum)
        wire [63:0] ts_min_eff [NUM_CHANNELS-1:0];
        wire [63:0] ts_max_eff [NUM_CHANNELS-1:0];

        for (genvar c = 0; c < NUM_CHANNELS; c = c + 1) begin : gen_eff_ts
            assign ts_min_eff[c] = ch_active[c] ? timestamp_s2[c] : 64'hFFFFFFFFFFFFFFFF;
            assign ts_max_eff[c] = ch_active[c] ? timestamp_s2[c] : 64'd0;
        end

        // Layer 1 min
        assign min_01 = (ts_min_eff[0] <= ts_min_eff[1]) ? ts_min_eff[0] : ts_min_eff[1];
        assign min_23 = (ts_min_eff[2] <= ts_min_eff[3]) ? ts_min_eff[2] : ts_min_eff[3];
        assign min_45 = (ts_min_eff[4] <= ts_min_eff[5]) ? ts_min_eff[4] : ts_min_eff[5];
        assign min_67 = (ts_min_eff[6] <= ts_min_eff[7]) ? ts_min_eff[6] : ts_min_eff[7];

        // Layer 2 min
        wire [63:0] min_0123, min_4567;
        assign min_0123 = (min_01 <= min_23) ? min_01 : min_23;
        assign min_4567 = (min_45 <= min_67) ? min_45 : min_67;

        // Layer 3 min
        assign ts_min_comb[gv] = (min_0123 <= min_4567) ? min_0123 : min_4567;

        // Layer 1 max
        assign max_01 = (ts_max_eff[0] >= ts_max_eff[1]) ? ts_max_eff[0] : ts_max_eff[1];
        assign max_23 = (ts_max_eff[2] >= ts_max_eff[3]) ? ts_max_eff[2] : ts_max_eff[3];
        assign max_45 = (ts_max_eff[4] >= ts_max_eff[5]) ? ts_max_eff[4] : ts_max_eff[5];
        assign max_67 = (ts_max_eff[6] >= ts_max_eff[7]) ? ts_max_eff[6] : ts_max_eff[7];

        // Layer 2 max
        wire [63:0] max_0123, max_4567;
        assign max_0123 = (max_01 >= max_23) ? max_01 : max_23;
        assign max_4567 = (max_45 >= max_67) ? max_45 : max_67;

        // Layer 3 max
        assign ts_max_comb[gv] = (max_0123 >= max_4567) ? max_0123 : max_4567;
    end
endgenerate

// Register stage 3 outputs
reg [63:0] ts_min_s3 [NUM_GROUPS-1:0];
reg [63:0] ts_max_s3 [NUM_GROUPS-1:0];
reg [NUM_CHANNELS-1:0] group_active_s3 [NUM_GROUPS-1:0];
reg [3:0] active_count_s3 [NUM_GROUPS-1:0];
reg [NUM_CHANNELS-1:0] valid_s3;

always @(posedge clk_coarse or negedge rst_n) begin
    if (!rst_n) begin
        valid_s3 <= {NUM_CHANNELS{1'b0}};
        for (integer g = 0; g < NUM_GROUPS; g = g + 1) begin
            ts_min_s3[g] <= 64'hFFFFFFFFFFFFFFFF;
            ts_max_s3[g] <= 64'd0;
            group_active_s3[g] <= {NUM_CHANNELS{1'b0}};
            active_count_s3[g] <= 4'd0;
        end
    end else begin
        valid_s3 <= valid_s2;
        for (integer g = 0; g < NUM_GROUPS; g = g + 1) begin
            ts_min_s3[g] <= ts_min_comb[g];
            ts_max_s3[g] <= ts_max_comb[g];
            group_active_s3[g] <= group_active_comb[g];
            active_count_s3[g] <= active_count_comb[g];
        end
    end
end

// ============================================================================
// Pipeline Stage 4: Compute time spread (max - min) per group
// ============================================================================

reg [63:0] time_spread_s4 [NUM_GROUPS-1:0];
reg [NUM_CHANNELS-1:0] group_active_s4 [NUM_GROUPS-1:0];
reg [3:0] active_count_s4 [NUM_GROUPS-1:0];
reg [63:0] ts_max_s4 [NUM_GROUPS-1:0];
reg [NUM_GROUPS-1:0] has_multi_event_s4;

always @(posedge clk_coarse or negedge rst_n) begin
    if (!rst_n) begin
        for (integer g = 0; g < NUM_GROUPS; g = g + 1) begin
            time_spread_s4[g] <= 64'd0;
            group_active_s4[g] <= {NUM_CHANNELS{1'b0}};
            active_count_s4[g] <= 4'd0;
            ts_max_s4[g] <= 64'd0;
            has_multi_event_s4[g] <= 1'b0;
        end
    end else begin
        for (integer g = 0; g < NUM_GROUPS; g = g + 1) begin
            time_spread_s4[g] <= ts_max_s3[g] - ts_min_s3[g];
            group_active_s4[g] <= group_active_s3[g];
            active_count_s4[g] <= active_count_s3[g];
            ts_max_s4[g] <= ts_max_s3[g];
            has_multi_event_s4[g] <= (active_count_s3[g] >= 4'd2);
        end
    end
end

// ============================================================================
// Pipeline Stage 5: Compare spread against window, determine coincidence
// A coincidence occurs when:
//   - Group is enabled and window is valid
//   - At least 2 channels in the group have valid events
//   - Time spread <= window value (in 10 ps units)
// ============================================================================

reg [NUM_GROUPS-1:0] coincidence_detected_s5;
reg [NUM_CHANNELS-1:0] coinc_channels_s5 [NUM_GROUPS-1:0];
reg [63:0] coinc_timestamp_s5 [NUM_GROUPS-1:0];

always @(posedge clk_coarse or negedge rst_n) begin
    if (!rst_n) begin
        coincidence_detected_s5 <= {NUM_GROUPS{1'b0}};
        for (integer g = 0; g < NUM_GROUPS; g = g + 1) begin
            coinc_channels_s5[g] <= {NUM_CHANNELS{1'b0}};
            coinc_timestamp_s5[g] <= 64'd0;
        end
    end else begin
        for (integer g = 0; g < NUM_GROUPS; g = g + 1) begin
            // Window value is in units of 10 ps; the fine timestamp field is
            // also in 10 ps units. Compare spread directly against window.
            if (group_enable[g] && window_valid_reg[g] &&
                has_multi_event_s4[g] &&
                (time_spread_s4[g] <= {{(64-WINDOW_BITS){1'b0}}, window[g]})) begin
                coincidence_detected_s5[g] <= 1'b1;
                coinc_channels_s5[g] <= group_active_s4[g];
                coinc_timestamp_s5[g] <= ts_max_s4[g]; // Use latest timestamp
            end else begin
                coincidence_detected_s5[g] <= 1'b0;
                coinc_channels_s5[g] <= {NUM_CHANNELS{1'b0}};
                coinc_timestamp_s5[g] <= 64'd0;
            end
        end
    end
end

// ============================================================================
// Pipeline Stage 6: Generate coincidence Tag_Record
// Priority encode across groups (group 0 has highest priority).
// Format: [95:32] = timestamp of latest participating event
//         [31:24] = 0xFF (coincidence channel ID)
//         [23:16] = flags: bits[4:3] = group ID, others zero
//         [15:0]  = participating channel bitmask (in reserved field)
// ============================================================================

reg [95:0] coinc_tag_s6;
reg        coinc_valid_s6;

always @(posedge clk_coarse or negedge rst_n) begin
    if (!rst_n) begin
        coinc_tag_s6 <= 96'd0;
        coinc_valid_s6 <= 1'b0;
    end else begin
        coinc_valid_s6 <= 1'b0;
        coinc_tag_s6 <= 96'd0;

        // Priority encoder: lowest group index has highest priority
        // Iterate from highest to lowest so lowest index overwrites
        if (coincidence_detected_s5[3]) begin
            coinc_tag_s6[`TAG_TIMESTAMP_MSB:`TAG_TIMESTAMP_LSB] <= coinc_timestamp_s5[3];
            coinc_tag_s6[`TAG_CHANNEL_ID_MSB:`TAG_CHANNEL_ID_LSB] <= COINC_CHANNEL_ID;
            coinc_tag_s6[`TAG_FLAGS_MSB:`TAG_FLAGS_LSB] <= {3'b0, 2'd3, 3'b0};
            coinc_tag_s6[`TAG_RESERVED_MSB:`TAG_RESERVED_LSB] <= {{(16-NUM_CHANNELS){1'b0}}, coinc_channels_s5[3]};
            coinc_valid_s6 <= 1'b1;
        end
        if (coincidence_detected_s5[2]) begin
            coinc_tag_s6[`TAG_TIMESTAMP_MSB:`TAG_TIMESTAMP_LSB] <= coinc_timestamp_s5[2];
            coinc_tag_s6[`TAG_CHANNEL_ID_MSB:`TAG_CHANNEL_ID_LSB] <= COINC_CHANNEL_ID;
            coinc_tag_s6[`TAG_FLAGS_MSB:`TAG_FLAGS_LSB] <= {3'b0, 2'd2, 3'b0};
            coinc_tag_s6[`TAG_RESERVED_MSB:`TAG_RESERVED_LSB] <= {{(16-NUM_CHANNELS){1'b0}}, coinc_channels_s5[2]};
            coinc_valid_s6 <= 1'b1;
        end
        if (coincidence_detected_s5[1]) begin
            coinc_tag_s6[`TAG_TIMESTAMP_MSB:`TAG_TIMESTAMP_LSB] <= coinc_timestamp_s5[1];
            coinc_tag_s6[`TAG_CHANNEL_ID_MSB:`TAG_CHANNEL_ID_LSB] <= COINC_CHANNEL_ID;
            coinc_tag_s6[`TAG_FLAGS_MSB:`TAG_FLAGS_LSB] <= {3'b0, 2'd1, 3'b0};
            coinc_tag_s6[`TAG_RESERVED_MSB:`TAG_RESERVED_LSB] <= {{(16-NUM_CHANNELS){1'b0}}, coinc_channels_s5[1]};
            coinc_valid_s6 <= 1'b1;
        end
        if (coincidence_detected_s5[0]) begin
            coinc_tag_s6[`TAG_TIMESTAMP_MSB:`TAG_TIMESTAMP_LSB] <= coinc_timestamp_s5[0];
            coinc_tag_s6[`TAG_CHANNEL_ID_MSB:`TAG_CHANNEL_ID_LSB] <= COINC_CHANNEL_ID;
            coinc_tag_s6[`TAG_FLAGS_MSB:`TAG_FLAGS_LSB] <= {3'b0, 2'd0, 3'b0};
            coinc_tag_s6[`TAG_RESERVED_MSB:`TAG_RESERVED_LSB] <= {{(16-NUM_CHANNELS){1'b0}}, coinc_channels_s5[0]};
            coinc_valid_s6 <= 1'b1;
        end
    end
end

// ============================================================================
// Pipeline Stage 7: Output register
// ============================================================================

reg [95:0] coinc_tag_out;
reg        coinc_valid_out;

always @(posedge clk_coarse or negedge rst_n) begin
    if (!rst_n) begin
        coinc_tag_out <= 96'd0;
        coinc_valid_out <= 1'b0;
    end else begin
        coinc_tag_out <= coinc_tag_s6;
        coinc_valid_out <= coinc_valid_s6;
    end
end

assign coinc_tag = coinc_tag_out;
assign coinc_valid = coinc_valid_out;

endmodule
