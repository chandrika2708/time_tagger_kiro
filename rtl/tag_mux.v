//-----------------------------------------------------------------------------
// tag_mux.v
// Tag Multiplexer and Round-Robin Arbiter
//-----------------------------------------------------------------------------
// This module implements a round-robin arbiter that selects from 8 channel
// FIFOs plus 1 coincidence FIFO (9 sources total), producing a continuous
// stream of Tag_Records for the AXI DMA engine.
//
// Features:
//   - Fair round-robin arbitration across all 9 sources
//   - Maintains chronological ordering within each channel (FIFO order)
//   - Single-cycle grant when a source has data available
//   - Valid/ready handshake interface to downstream DMA engine
//   - Sustains 80 Mtags/s aggregate throughput at 250 MHz (1 tag/cycle max)
//
// Architecture:
//   The arbiter uses a rotating priority scheme. Each cycle, it checks
//   sources starting from the one after the last granted source. The first
//   non-empty source encountered is granted. This ensures fairness and
//   prevents starvation of any single channel.
//
//   Chronological ordering within each channel is inherently maintained
//   because each source FIFO delivers tags in write order, and the arbiter
//   never reorders tags from the same source.
//
// Throughput:
//   At 250 MHz with 1 tag per clock cycle maximum throughput, the arbiter
//   can deliver up to 250 Mtags/s, well exceeding the 80 Mtags/s requirement.
//   The output pipeline register adds 1 cycle of latency but does not reduce
//   sustained throughput when the downstream DMA is continuously ready.
//-----------------------------------------------------------------------------

`include "time_tagger_pkg.v"

module tag_mux #(
    parameter NUM_SOURCES = 9,   // 8 channels + 1 coincidence
    parameter TAG_WIDTH   = `TAG_WIDTH
)(
    input  wire                          clk,        // clk_dma (250 MHz)
    input  wire                          rst_n,

    // FIFO read interfaces (active-low empty, active-high rd_en)
    // Sources 0-7: channel FIFOs, Source 8: coincidence FIFO
    input  wire [TAG_WIDTH-1:0]          fifo_rd_data  [0:NUM_SOURCES-1],
    input  wire [NUM_SOURCES-1:0]        fifo_empty,
    output wire [NUM_SOURCES-1:0]        fifo_rd_en,

    // Output interface to AXI DMA engine (valid/ready handshake)
    output wire [TAG_WIDTH-1:0]          tag_out,
    output wire                          tag_valid,
    input  wire                          tag_ready
);

    // ========================================================================
    // Internal Signals
    // ========================================================================

    // Round-robin priority pointer (points to the next source to check first)
    reg  [3:0] rr_ptr;  // 4 bits to hold values 0..8

    // Grant signals
    wire [NUM_SOURCES-1:0]  request;       // Which sources have data
    reg  [NUM_SOURCES-1:0]  grant_comb;    // One-hot grant (combinational)
    wire [NUM_SOURCES-1:0]  grant;         // Final grant gated by output_accept
    wire                    any_grant;     // At least one source granted
    reg  [3:0]              grant_idx;     // Binary index of granted source

    // Output pipeline register
    reg  [TAG_WIDTH-1:0]    tag_out_reg;
    reg                     tag_valid_reg;

    // ========================================================================
    // Request Generation
    // ========================================================================
    // A source requests service when its FIFO is not empty.

    assign request = ~fifo_empty;

    // ========================================================================
    // Round-Robin Arbiter Logic
    // ========================================================================
    // Scan sources starting from rr_ptr, wrapping around. The first source
    // with a pending request (non-empty FIFO) is granted.
    //
    // This uses a simple iterative scan in a combinational block. For 9
    // sources this synthesizes to a small priority mux tree.

    reg  found;
    integer i;
    reg  [3:0] scan_idx;

    always @(*) begin
        grant_comb = {NUM_SOURCES{1'b0}};
        grant_idx  = 4'd0;
        found      = 1'b0;

        for (i = 0; i < NUM_SOURCES; i = i + 1) begin
            // Calculate the source index to check: (rr_ptr + i) mod NUM_SOURCES
            // Use a temporary variable for clarity
            scan_idx = (rr_ptr + i[3:0]);
            // Modulo NUM_SOURCES for non-power-of-2
            if (scan_idx >= NUM_SOURCES)
                scan_idx = scan_idx - NUM_SOURCES[3:0];

            if (!found && request[scan_idx]) begin
                grant_comb[scan_idx] = 1'b1;
                grant_idx = scan_idx;
                found = 1'b1;
            end
        end
    end

    // ========================================================================
    // Output Accept Logic
    // ========================================================================
    // The arbiter can issue a grant when the output register is empty
    // (tag_valid_reg == 0) or when the downstream consumer accepts the
    // current output (tag_ready == 1).

    wire output_accept;
    assign output_accept = !tag_valid_reg || tag_ready;

    // Gate grant by output_accept to implement backpressure
    assign grant     = output_accept ? grant_comb : {NUM_SOURCES{1'b0}};
    assign any_grant = |grant;

    // ========================================================================
    // FIFO Read Enable Generation
    // ========================================================================
    // Assert rd_en for the granted source to pop the tag from its FIFO.

    assign fifo_rd_en = grant;

    // ========================================================================
    // Output Data Multiplexer
    // ========================================================================
    // Select the read data from the granted FIFO source.

    reg [TAG_WIDTH-1:0] mux_data;

    integer m;
    always @(*) begin
        mux_data = {TAG_WIDTH{1'b0}};
        for (m = 0; m < NUM_SOURCES; m = m + 1) begin
            if (grant[m])
                mux_data = fifo_rd_data[m];
        end
    end

    // ========================================================================
    // Output Pipeline Register
    // ========================================================================
    // Single pipeline stage to break timing path between FIFO read and
    // DMA engine. Uses valid/ready handshake protocol.
    //
    // When output_accept is high:
    //   - If any_grant: latch new data, assert valid
    //   - If no grant:  de-assert valid (no data available)
    // When output_accept is low (backpressure): hold current output

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tag_out_reg   <= {TAG_WIDTH{1'b0}};
            tag_valid_reg <= 1'b0;
        end else if (output_accept) begin
            if (any_grant) begin
                tag_out_reg   <= mux_data;
                tag_valid_reg <= 1'b1;
            end else begin
                tag_valid_reg <= 1'b0;
            end
        end
    end

    assign tag_out   = tag_out_reg;
    assign tag_valid = tag_valid_reg;

    // ========================================================================
    // Round-Robin Pointer Update
    // ========================================================================
    // After a successful grant, advance the pointer to the source after
    // the one just granted. This ensures fair rotation across all sources.

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rr_ptr <= 4'd0;
        end else if (any_grant) begin
            // Advance to next source after the granted one (mod NUM_SOURCES)
            if (grant_idx == NUM_SOURCES - 1)
                rr_ptr <= 4'd0;
            else
                rr_ptr <= grant_idx + 4'd1;
        end
    end

endmodule
