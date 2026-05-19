//-----------------------------------------------------------------------------
// axi_dma_engine.v
// AXI4 DMA Engine for bulk Tag_Record transfer to PS DDR4
//-----------------------------------------------------------------------------
// This module implements an AXI4 Master write engine that transfers
// Tag_Records from the tag_mux output to PS DDR4 memory via an AXI HP port.
//
// Features:
//   - Burst writes of up to 256 Tag_Records per AXI transaction
//   - 128-bit data width (one 96-bit Tag_Record per beat, zero-padded)
//   - Round-robin arbitration via tag_mux (upstream module)
//   - Partial burst handling: returns actual count when fewer records available
//   - Sustains 80 Mtags/s aggregate throughput at 250 MHz clock
//   - Software-configurable base address and burst length
//   - Circular buffer mode with configurable buffer size
//
// Architecture:
//   The DMA engine operates as a state machine:
//   1. IDLE: Wait for enable and available tags
//   2. COLLECT: Gather tags from tag_mux into internal buffer
//   3. ADDR: Issue AXI write address with burst length
//   4. DATA: Stream buffered tags as AXI write data beats
//   5. RESP: Wait for write response, update status
//
// Throughput:
//   At 250 MHz with 128-bit data bus, one tag per beat:
//   Max throughput = 250 Mtags/s (well above 80 Mtags/s requirement)
//   Burst of 256 tags completes in ~260 cycles (256 data + overhead)
//
// Interface to tag_mux:
//   The tag_mux provides tags via valid/ready handshake. This engine
//   asserts tag_ready to accept tags during the COLLECT phase.
//-----------------------------------------------------------------------------

`include "time_tagger_pkg.v"

module axi_dma_engine #(
    parameter AXI_DATA_WIDTH  = 128,
    parameter AXI_ADDR_WIDTH  = 32,
    parameter TAG_WIDTH       = `TAG_WIDTH,   // 96 bits
    parameter MAX_BURST_LEN   = 256           // Max tags per burst (AXI4 max)
)(
    input  wire                         clk,          // clk_dma (250 MHz)
    input  wire                         rst_n,

    // ========================================================================
    // Control/Status Interface (from register file)
    // ========================================================================
    input  wire                         dma_enable,       // DMA engine enable
    input  wire [AXI_ADDR_WIDTH-1:0]    dma_base_addr,    // Buffer base address in DDR
    input  wire [AXI_ADDR_WIDTH-1:0]    dma_buf_size,     // Buffer size in bytes (circular)
    input  wire [7:0]                   dma_burst_len,    // Configured burst length - 1 (0-255)
    output reg  [7:0]                   dma_actual_count, // Actual tags transferred in last burst
    output reg                          dma_busy,         // DMA transfer in progress
    output reg                          dma_error,        // AXI error response received
    output reg  [31:0]                  dma_tag_count,    // Total tags transferred (32-bit)

    // ========================================================================
    // Tag Input Interface (from tag_mux)
    // ========================================================================
    input  wire [TAG_WIDTH-1:0]         tag_in,           // Tag data from mux
    input  wire                         tag_valid,        // Tag available
    output wire                         tag_ready,        // Backpressure to mux

    // ========================================================================
    // AXI4 Master Write Interface (to PS DDR4 via HP port)
    // ========================================================================
    // Write Address Channel
    output reg  [AXI_ADDR_WIDTH-1:0]    m_axi_awaddr,
    output reg  [7:0]                   m_axi_awlen,      // Burst length - 1
    output wire [2:0]                   m_axi_awsize,     // 4 = 16 bytes (128-bit)
    output wire [1:0]                   m_axi_awburst,    // INCR
    output reg                          m_axi_awvalid,
    input  wire                         m_axi_awready,

    // Write Data Channel
    output wire [AXI_DATA_WIDTH-1:0]    m_axi_wdata,
    output wire [AXI_DATA_WIDTH/8-1:0]  m_axi_wstrb,
    output wire                         m_axi_wlast,
    output reg                          m_axi_wvalid,
    input  wire                         m_axi_wready,

    // Write Response Channel
    input  wire [1:0]                   m_axi_bresp,
    input  wire                         m_axi_bvalid,
    output reg                          m_axi_bready
);

    // ========================================================================
    // Constants
    // ========================================================================

    // AXI burst parameters
    localparam AXI_SIZE_16B  = 3'b100;   // 16 bytes per beat (128-bit)
    localparam AXI_BURST_INCR = 2'b01;   // Incrementing burst
    localparam BYTES_PER_BEAT = AXI_DATA_WIDTH / 8;  // 16 bytes

    // Fixed AXI signals
    assign m_axi_awsize  = AXI_SIZE_16B;
    assign m_axi_awburst = AXI_BURST_INCR;

    // Write strobes: all bytes valid (96-bit tag in lower 12 bytes, upper 4 zero)
    // We write all 16 bytes per beat (upper 32 bits are zero padding)
    assign m_axi_wstrb = {(AXI_DATA_WIDTH/8){1'b1}};

    // ========================================================================
    // State Machine
    // ========================================================================

    localparam [2:0] ST_IDLE    = 3'd0,
                     ST_COLLECT = 3'd1,
                     ST_ADDR    = 3'd2,
                     ST_DATA    = 3'd3,
                     ST_RESP    = 3'd4;

    reg [2:0] state, state_next;

    // ========================================================================
    // Internal Signals
    // ========================================================================

    // Collection buffer (dual-port RAM for tag storage during burst)
    // Store up to 256 tags
    reg [TAG_WIDTH-1:0] tag_buffer [0:MAX_BURST_LEN-1];

    // Collection counter: how many tags collected so far
    reg [8:0] collect_count;  // 9 bits to count 0..256

    // Target burst length (configured burst length + 1, capped at MAX_BURST_LEN)
    wire [8:0] target_burst;
    assign target_burst = {1'b0, dma_burst_len} + 9'd1;  // 1 to 256

    // Timeout counter for partial burst (don't wait forever for tags)
    reg [7:0] timeout_count;
    localparam TIMEOUT_CYCLES = 8'd64;  // Flush partial burst after 64 idle cycles

    // Data phase beat counter
    reg [8:0] beat_count;

    // Current write address (advances through circular buffer)
    reg [AXI_ADDR_WIDTH-1:0] write_addr;

    // Write data output from buffer
    reg [TAG_WIDTH-1:0] wdata_tag;
    assign m_axi_wdata = {{(AXI_DATA_WIDTH - TAG_WIDTH){1'b0}}, wdata_tag};

    // Last beat indicator
    assign m_axi_wlast = (beat_count == {1'b0, m_axi_awlen});

    // Tag ready: accept tags only during COLLECT phase
    assign tag_ready = (state == ST_COLLECT) && dma_enable;

    // ========================================================================
    // State Machine - Sequential
    // ========================================================================

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= ST_IDLE;
        else
            state <= state_next;
    end

    // ========================================================================
    // State Machine - Combinational Next State
    // ========================================================================

    always @(*) begin
        state_next = state;

        case (state)
            ST_IDLE: begin
                if (dma_enable && tag_valid)
                    state_next = ST_COLLECT;
            end

            ST_COLLECT: begin
                if (!dma_enable) begin
                    // Disabled mid-collection: flush what we have
                    if (collect_count > 0)
                        state_next = ST_ADDR;
                    else
                        state_next = ST_IDLE;
                end else if (collect_count >= target_burst) begin
                    // Full burst collected
                    state_next = ST_ADDR;
                end else if (timeout_count >= TIMEOUT_CYCLES && collect_count > 0) begin
                    // Partial burst: timeout with some data
                    state_next = ST_ADDR;
                end
            end

            ST_ADDR: begin
                if (m_axi_awvalid && m_axi_awready)
                    state_next = ST_DATA;
            end

            ST_DATA: begin
                if (m_axi_wvalid && m_axi_wready && m_axi_wlast)
                    state_next = ST_RESP;
            end

            ST_RESP: begin
                if (m_axi_bvalid && m_axi_bready)
                    state_next = dma_enable ? (tag_valid ? ST_COLLECT : ST_IDLE) : ST_IDLE;
            end

            default: state_next = ST_IDLE;
        endcase
    end

    // ========================================================================
    // Tag Collection Logic
    // ========================================================================

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            collect_count <= 9'd0;
            timeout_count <= 8'd0;
        end else begin
            case (state)
                ST_IDLE: begin
                    collect_count <= 9'd0;
                    timeout_count <= 8'd0;
                end

                ST_COLLECT: begin
                    if (tag_valid && tag_ready) begin
                        tag_buffer[collect_count[7:0]] <= tag_in;
                        collect_count <= collect_count + 9'd1;
                        timeout_count <= 8'd0;  // Reset timeout on each tag
                    end else begin
                        // No tag available this cycle, increment timeout
                        if (timeout_count < TIMEOUT_CYCLES)
                            timeout_count <= timeout_count + 8'd1;
                    end
                end

                ST_ADDR: begin
                    // Hold collection count stable during address phase
                    timeout_count <= 8'd0;
                end

                ST_RESP: begin
                    // Reset for next burst
                    collect_count <= 9'd0;
                    timeout_count <= 8'd0;
                end

                default: begin
                    collect_count <= 9'd0;
                    timeout_count <= 8'd0;
                end
            endcase
        end
    end

    // ========================================================================
    // AXI Write Address Channel
    // ========================================================================

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axi_awaddr  <= {AXI_ADDR_WIDTH{1'b0}};
            m_axi_awlen   <= 8'd0;
            m_axi_awvalid <= 1'b0;
        end else begin
            case (state)
                ST_ADDR: begin
                    if (!m_axi_awvalid) begin
                        // Issue address with actual collected count
                        m_axi_awaddr  <= write_addr;
                        m_axi_awlen   <= collect_count[7:0] - 8'd1;  // AXI len = count - 1
                        m_axi_awvalid <= 1'b1;
                    end else if (m_axi_awready) begin
                        m_axi_awvalid <= 1'b0;
                    end
                end

                default: begin
                    m_axi_awvalid <= 1'b0;
                end
            endcase
        end
    end

    // ========================================================================
    // AXI Write Data Channel
    // ========================================================================

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            beat_count  <= 9'd0;
            m_axi_wvalid <= 1'b0;
            wdata_tag   <= {TAG_WIDTH{1'b0}};
        end else begin
            case (state)
                ST_DATA: begin
                    m_axi_wvalid <= 1'b1;
                    wdata_tag    <= tag_buffer[beat_count[7:0]];

                    if (m_axi_wvalid && m_axi_wready) begin
                        if (m_axi_wlast) begin
                            beat_count  <= 9'd0;
                            m_axi_wvalid <= 1'b0;
                        end else begin
                            beat_count <= beat_count + 9'd1;
                            wdata_tag  <= tag_buffer[beat_count[7:0] + 8'd1];
                        end
                    end
                end

                ST_ADDR: begin
                    // Pre-load first beat data
                    beat_count  <= 9'd0;
                    wdata_tag   <= tag_buffer[0];
                    m_axi_wvalid <= 1'b0;
                end

                default: begin
                    beat_count  <= 9'd0;
                    m_axi_wvalid <= 1'b0;
                end
            endcase
        end
    end

    // ========================================================================
    // AXI Write Response Channel
    // ========================================================================

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axi_bready <= 1'b0;
        end else begin
            case (state)
                ST_RESP: begin
                    m_axi_bready <= 1'b1;
                end
                default: begin
                    m_axi_bready <= 1'b0;
                end
            endcase
        end
    end

    // ========================================================================
    // Write Address Management (Circular Buffer)
    // ========================================================================

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_addr <= {AXI_ADDR_WIDTH{1'b0}};
        end else if (!dma_enable) begin
            // Reset write pointer when disabled
            write_addr <= dma_base_addr;
        end else if (state == ST_RESP && m_axi_bvalid && m_axi_bready) begin
            // Advance write address after successful burst
            // Each tag occupies BYTES_PER_BEAT bytes in memory (128-bit aligned)
            if ((write_addr + (collect_count * BYTES_PER_BEAT) - dma_base_addr) >= dma_buf_size)
                write_addr <= dma_base_addr;  // Wrap around
            else
                write_addr <= write_addr + (collect_count * BYTES_PER_BEAT);
        end
    end

    // ========================================================================
    // Status Outputs
    // ========================================================================

    // DMA busy flag
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            dma_busy <= 1'b0;
        else
            dma_busy <= (state != ST_IDLE);
    end

    // Actual count of last burst transfer
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            dma_actual_count <= 8'd0;
        else if (state == ST_RESP && m_axi_bvalid && m_axi_bready)
            dma_actual_count <= collect_count[7:0];
    end

    // Error flag (set on SLVERR or DECERR response)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            dma_error <= 1'b0;
        else if (!dma_enable)
            dma_error <= 1'b0;  // Clear on disable
        else if (state == ST_RESP && m_axi_bvalid && m_axi_bready && m_axi_bresp != 2'b00)
            dma_error <= 1'b1;
    end

    // Total tag count (cumulative, wraps at 32-bit max)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            dma_tag_count <= 32'd0;
        else if (!dma_enable)
            dma_tag_count <= 32'd0;  // Reset on disable
        else if (state == ST_RESP && m_axi_bvalid && m_axi_bready)
            dma_tag_count <= dma_tag_count + {23'd0, collect_count};
    end

endmodule
