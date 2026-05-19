//-----------------------------------------------------------------------------
// tag_fifo.v
// Per-channel BRAM-based asynchronous FIFO with gray-code pointer CDC
//-----------------------------------------------------------------------------
// This module implements a 16384-entry × 96-bit asynchronous FIFO for
// buffering Tag_Records between the clk_coarse (500 MHz write) and
// clk_dma (250 MHz read) clock domains.
//
// Features:
//   - Gray-code pointer synchronization for safe CDC
//   - High-watermark flag at 75% occupancy (configurable via HWM_LEVEL)
//   - Circular buffer overflow: discards oldest entry, sets overflow flag
//   - 14-bit occupancy counter output
//
// Circular Buffer Overflow Strategy:
//   The FIFO uses an (ADDR_WIDTH+1)-bit pointer scheme where the MSB
//   distinguishes full from empty. On overflow (wr_en while full), the
//   write always proceeds and the read pointer is advanced in the write
//   domain via a separate "min read pointer" register. The read domain
//   ensures its pointer never falls behind this minimum.
//-----------------------------------------------------------------------------

`include "time_tagger_pkg.v"

module tag_fifo #(
    parameter DEPTH     = 16384,
    parameter WIDTH     = 96,
    parameter HWM_LEVEL = 12288
)(
    input  wire             wr_clk,       // clk_coarse (500 MHz)
    input  wire             rd_clk,       // clk_dma (250 MHz)
    input  wire             rst_n,
    input  wire [WIDTH-1:0] wr_data,
    input  wire             wr_en,
    output wire [WIDTH-1:0] rd_data,
    input  wire             rd_en,
    output wire             full,
    output wire             empty,
    output wire             high_watermark,
    output wire             overflow_flag,
    output wire [13:0]      occupancy
);

    // ========================================================================
    // Local Parameters
    // ========================================================================

    localparam ADDR_WIDTH = 14;  // log2(16384)

    // ========================================================================
    // Write Domain Signals
    // ========================================================================

    reg  [ADDR_WIDTH:0] wr_ptr_bin;
    reg  [ADDR_WIDTH:0] wr_ptr_gray;
    wire [ADDR_WIDTH:0] wr_ptr_bin_next;
    wire [ADDR_WIDTH:0] wr_ptr_gray_next;

    // Minimum read pointer (write domain) - tracks overflow-forced advances
    reg  [ADDR_WIDTH:0] min_rd_ptr_bin;
    reg  [ADDR_WIDTH:0] min_rd_ptr_gray;
    wire [ADDR_WIDTH:0] min_rd_ptr_bin_next;
    wire [ADDR_WIDTH:0] min_rd_ptr_gray_next;

    // ========================================================================
    // Read Domain Signals
    // ========================================================================

    reg  [ADDR_WIDTH:0] rd_ptr_bin;
    reg  [ADDR_WIDTH:0] rd_ptr_gray;

    // ========================================================================
    // CDC Synchronizer Registers
    // ========================================================================

    // Read pointer gray -> write domain (2-stage sync)
    reg  [ADDR_WIDTH:0] rd_ptr_gray_wr_s1;
    reg  [ADDR_WIDTH:0] rd_ptr_gray_wr_s2;

    // Write pointer gray -> read domain (2-stage sync)
    reg  [ADDR_WIDTH:0] wr_ptr_gray_rd_s1;
    reg  [ADDR_WIDTH:0] wr_ptr_gray_rd_s2;

    // Min read pointer gray -> read domain (2-stage sync)
    reg  [ADDR_WIDTH:0] min_rd_ptr_gray_rd_s1;
    reg  [ADDR_WIDTH:0] min_rd_ptr_gray_rd_s2;

    // ========================================================================
    // Gray-to-Binary Conversion Wires
    // ========================================================================

    wire [ADDR_WIDTH:0] rd_ptr_bin_in_wr;     // Read ptr (binary) in write domain
    wire [ADDR_WIDTH:0] wr_ptr_bin_in_rd;     // Write ptr (binary) in read domain
    wire [ADDR_WIDTH:0] min_rd_ptr_bin_in_rd; // Min read ptr (binary) in read domain

    // ========================================================================
    // Status Signals
    // ========================================================================

    wire fifo_full;
    wire fifo_empty;
    wire overflow_condition;
    reg  overflow_flag_reg;

    // ========================================================================
    // BRAM Storage
    // ========================================================================

    (* ram_style = "block" *)
    reg [WIDTH-1:0] mem [0:DEPTH-1];

    wire [ADDR_WIDTH-1:0] wr_addr;
    wire [ADDR_WIDTH-1:0] rd_addr;

    assign wr_addr = wr_ptr_bin[ADDR_WIDTH-1:0];
    assign rd_addr = rd_ptr_bin[ADDR_WIDTH-1:0];

    // Write port: always write when wr_en (circular buffer overwrites on full)
    always @(posedge wr_clk) begin
        if (wr_en) begin
            mem[wr_addr] <= wr_data;
        end
    end

    // Read port: synchronous read for BRAM inference
    reg [WIDTH-1:0] rd_data_reg;

    always @(posedge rd_clk) begin
        if (rd_en && !fifo_empty) begin
            rd_data_reg <= mem[rd_addr];
        end
    end

    assign rd_data = rd_data_reg;

    // ========================================================================
    // Write Pointer (wr_clk domain)
    // ========================================================================

    // Write pointer always advances on wr_en (circular buffer behavior)
    assign wr_ptr_bin_next  = wr_en ? (wr_ptr_bin + 1'b1) : wr_ptr_bin;
    assign wr_ptr_gray_next = wr_ptr_bin_next ^ (wr_ptr_bin_next >> 1);

    always @(posedge wr_clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr_bin  <= {(ADDR_WIDTH+1){1'b0}};
            wr_ptr_gray <= {(ADDR_WIDTH+1){1'b0}};
        end else begin
            wr_ptr_bin  <= wr_ptr_bin_next;
            wr_ptr_gray <= wr_ptr_gray_next;
        end
    end

    // ========================================================================
    // Minimum Read Pointer (wr_clk domain)
    // ========================================================================
    // On overflow, the oldest entry is discarded. This is modeled by advancing
    // the minimum read pointer. The read domain must respect this minimum.

    assign overflow_condition = fifo_full && wr_en;

    assign min_rd_ptr_bin_next  = overflow_condition ?
        (min_rd_ptr_bin + 1'b1) : min_rd_ptr_bin;
    assign min_rd_ptr_gray_next = min_rd_ptr_bin_next ^
        (min_rd_ptr_bin_next >> 1);

    always @(posedge wr_clk or negedge rst_n) begin
        if (!rst_n) begin
            min_rd_ptr_bin  <= {(ADDR_WIDTH+1){1'b0}};
            min_rd_ptr_gray <= {(ADDR_WIDTH+1){1'b0}};
        end else begin
            min_rd_ptr_bin  <= min_rd_ptr_bin_next;
            min_rd_ptr_gray <= min_rd_ptr_gray_next;
        end
    end

    // ========================================================================
    // CDC Synchronizers (dual flip-flop)
    // ========================================================================

    // Sync read pointer gray to write domain
    always @(posedge wr_clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr_gray_wr_s1 <= {(ADDR_WIDTH+1){1'b0}};
            rd_ptr_gray_wr_s2 <= {(ADDR_WIDTH+1){1'b0}};
        end else begin
            rd_ptr_gray_wr_s1 <= rd_ptr_gray;
            rd_ptr_gray_wr_s2 <= rd_ptr_gray_wr_s1;
        end
    end

    // Sync write pointer gray to read domain
    always @(posedge rd_clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr_gray_rd_s1 <= {(ADDR_WIDTH+1){1'b0}};
            wr_ptr_gray_rd_s2 <= {(ADDR_WIDTH+1){1'b0}};
        end else begin
            wr_ptr_gray_rd_s1 <= wr_ptr_gray;
            wr_ptr_gray_rd_s2 <= wr_ptr_gray_rd_s1;
        end
    end

    // Sync min read pointer gray to read domain
    always @(posedge rd_clk or negedge rst_n) begin
        if (!rst_n) begin
            min_rd_ptr_gray_rd_s1 <= {(ADDR_WIDTH+1){1'b0}};
            min_rd_ptr_gray_rd_s2 <= {(ADDR_WIDTH+1){1'b0}};
        end else begin
            min_rd_ptr_gray_rd_s1 <= min_rd_ptr_gray;
            min_rd_ptr_gray_rd_s2 <= min_rd_ptr_gray_rd_s1;
        end
    end

    // ========================================================================
    // Gray-to-Binary Conversion
    // ========================================================================

    genvar i;

    // Read pointer in write domain
    generate
        for (i = 0; i <= ADDR_WIDTH; i = i + 1) begin : g2b_rd_wr
            assign rd_ptr_bin_in_wr[i] = ^(rd_ptr_gray_wr_s2 >> i);
        end
    endgenerate

    // Write pointer in read domain
    generate
        for (i = 0; i <= ADDR_WIDTH; i = i + 1) begin : g2b_wr_rd
            assign wr_ptr_bin_in_rd[i] = ^(wr_ptr_gray_rd_s2 >> i);
        end
    endgenerate

    // Min read pointer in read domain
    generate
        for (i = 0; i <= ADDR_WIDTH; i = i + 1) begin : g2b_min_rd
            assign min_rd_ptr_bin_in_rd[i] = ^(min_rd_ptr_gray_rd_s2 >> i);
        end
    endgenerate

    // ========================================================================
    // Read Pointer (rd_clk domain)
    // ========================================================================
    // The read pointer advances on rd_en when not empty.
    // It also must be pushed forward if min_rd_ptr has advanced past it
    // (due to overflow in the write domain discarding oldest entries).

    wire [ADDR_WIDTH:0] rd_ptr_candidate;
    wire                rd_behind_min;
    wire [ADDR_WIDTH:0] rd_ptr_bin_next_val;
    wire [ADDR_WIDTH:0] rd_ptr_gray_next_val;

    // Candidate: normal advance on read
    assign rd_ptr_candidate = (rd_en && !fifo_empty) ?
        (rd_ptr_bin + 1'b1) : rd_ptr_bin;

    // Check if read pointer is behind the minimum (overflow pushed it forward)
    // "Behind" means: (min - rd) interpreted as unsigned is in range (0, DEPTH]
    // i.e., min_rd_ptr is ahead of rd_ptr in the circular sense
    wire [ADDR_WIDTH:0] min_minus_candidate;
    assign min_minus_candidate = min_rd_ptr_bin_in_rd - rd_ptr_candidate;

    // rd is behind min if the difference is non-zero and less than or equal to DEPTH
    // Since pointers use ADDR_WIDTH+1 bits, a positive difference < 2*DEPTH means behind
    assign rd_behind_min = (min_minus_candidate != {(ADDR_WIDTH+1){1'b0}}) &&
                           (min_minus_candidate[ADDR_WIDTH] == 1'b0);

    // If behind minimum, snap to minimum; otherwise use candidate
    assign rd_ptr_bin_next_val  = rd_behind_min ? min_rd_ptr_bin_in_rd : rd_ptr_candidate;
    assign rd_ptr_gray_next_val = rd_ptr_bin_next_val ^ (rd_ptr_bin_next_val >> 1);

    always @(posedge rd_clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr_bin  <= {(ADDR_WIDTH+1){1'b0}};
            rd_ptr_gray <= {(ADDR_WIDTH+1){1'b0}};
        end else begin
            rd_ptr_bin  <= rd_ptr_bin_next_val;
            rd_ptr_gray <= rd_ptr_gray_next_val;
        end
    end

    // ========================================================================
    // Full Flag (wr_clk domain)
    // ========================================================================
    // Full when write pointer has wrapped around relative to the effective
    // read pointer. The effective read pointer is the maximum of:
    //   - The synced actual read pointer (from rd_clk domain)
    //   - The min_rd_ptr (overflow-forced advances, local to wr_clk)
    // This ensures correct full detection even before the read domain
    // has had time to snap its pointer forward after overflow.

    wire [ADDR_WIDTH:0] effective_rd_ptr_wr;
    wire [ADDR_WIDTH:0] min_minus_synced_rd;
    wire                min_ahead_of_synced;

    // Check if min_rd_ptr is ahead of the synced read pointer
    assign min_minus_synced_rd = min_rd_ptr_bin - rd_ptr_bin_in_wr;
    assign min_ahead_of_synced = (min_minus_synced_rd != {(ADDR_WIDTH+1){1'b0}}) &&
                                 (min_minus_synced_rd[ADDR_WIDTH] == 1'b0);

    // Use whichever is further ahead
    assign effective_rd_ptr_wr = min_ahead_of_synced ? min_rd_ptr_bin : rd_ptr_bin_in_wr;

    assign fifo_full = (wr_ptr_bin[ADDR_WIDTH] != effective_rd_ptr_wr[ADDR_WIDTH]) &&
                       (wr_ptr_bin[ADDR_WIDTH-1:0] == effective_rd_ptr_wr[ADDR_WIDTH-1:0]);

    assign full = fifo_full;

    // ========================================================================
    // Empty Flag (rd_clk domain)
    // ========================================================================
    // Empty when read pointer equals write pointer in read domain.

    assign fifo_empty = (rd_ptr_bin == wr_ptr_bin_in_rd);

    assign empty = fifo_empty;

    // ========================================================================
    // Occupancy (wr_clk domain)
    // ========================================================================
    // Occupancy = wr_ptr - effective_rd_ptr (accounts for overflow advances)

    wire [ADDR_WIDTH:0] occupancy_calc;
    assign occupancy_calc = wr_ptr_bin - effective_rd_ptr_wr;
    assign occupancy = occupancy_calc[ADDR_WIDTH-1:0];

    // ========================================================================
    // High-Watermark Flag (wr_clk domain)
    // ========================================================================

    assign high_watermark = (occupancy_calc[ADDR_WIDTH-1:0] >= HWM_LEVEL[ADDR_WIDTH-1:0]);

    // ========================================================================
    // Overflow Flag (wr_clk domain)
    // ========================================================================
    // Set on overflow, held until cleared by reset.
    // In the full system, clearable via AXI control register write.

    always @(posedge wr_clk or negedge rst_n) begin
        if (!rst_n) begin
            overflow_flag_reg <= 1'b0;
        end else if (overflow_condition) begin
            overflow_flag_reg <= 1'b1;
        end
    end

    assign overflow_flag = overflow_flag_reg;

endmodule
