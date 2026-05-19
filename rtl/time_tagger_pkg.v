//-----------------------------------------------------------------------------
// time_tagger_pkg.v
// Shared parameters and constants for the FPGA Time Tagger
//-----------------------------------------------------------------------------
// This file defines global parameters, the 96-bit Tag_Record wire format,
// and flags field bit positions used across all modules.
//-----------------------------------------------------------------------------

`ifndef TIME_TAGGER_PKG_V
`define TIME_TAGGER_PKG_V

// ============================================================================
// System Parameters
// ============================================================================

// Number of independent input channels
`define NUM_CHANNELS    8

// Fine interpolator tapped delay line depth (CARRY8 cells × 8 taps)
`define NUM_TAPS        256

// Bit width of the fine timestamp value
`define FINE_BITS       16

// Per-channel FIFO depth in Tag_Records
`define FIFO_DEPTH      16384

// Total width of a Tag_Record in bits
`define TAG_WIDTH       96

// Coarse counter width (48 bits at 500 MHz → ~1.56 hours before rollover)
`define COARSE_BITS     48

// Channel ID width
`define CHANNEL_ID_BITS 8

// Flags field width
`define FLAGS_BITS      8

// Reserved field width
`define RESERVED_BITS   16

// FIFO high-watermark level (75% of FIFO_DEPTH)
`define FIFO_HWM_LEVEL  12288

// Number of coincidence groups
`define NUM_COINC_GROUPS 4

// Coincidence window configuration bits
`define COINC_WINDOW_BITS 10

// Dead time in coarse clock cycles (4 ns / 2 ns = 2 cycles at 500 MHz)
`define DEAD_TIME_CYCLES 2

// ============================================================================
// Tag_Record Format (96 bits)
// ============================================================================
//
//  Bit Position:  [95:32]       [31:24]        [23:16]     [15:0]
//  Field:         Timestamp     Channel_ID     Flags       Reserved
//  Width:         64 bits       8 bits         8 bits      16 bits
//
// Timestamp composition (64 bits):
//  [63:16] = Coarse_Count (48 bits)
//  [15:0]  = Fine_Value   (16 bits)
//

// Tag_Record field positions (bit offsets within 96-bit record)
`define TAG_TIMESTAMP_MSB   95
`define TAG_TIMESTAMP_LSB   32
`define TAG_CHANNEL_ID_MSB  31
`define TAG_CHANNEL_ID_LSB  24
`define TAG_FLAGS_MSB       23
`define TAG_FLAGS_LSB       16
`define TAG_RESERVED_MSB    15
`define TAG_RESERVED_LSB    0

// Timestamp sub-field positions (within the 64-bit timestamp)
`define TS_COARSE_MSB       63
`define TS_COARSE_LSB       16
`define TS_FINE_MSB         15
`define TS_FINE_LSB         0

// ============================================================================
// Flags Field Bit Definitions (8 bits)
// ============================================================================
//
//  Bit 7: overflow         - Coarse counter rollover occurred
//  Bit 6: invalid          - Fine interpolator out-of-range bin
//  Bit 5: reduced_accuracy - Generated during recalibration
//  Bit 4:1: reserved       - Set to 0
//  Bit 0: edge_polarity    - 1 = rising edge, 0 = falling edge
//

`define FLAG_OVERFLOW           7
`define FLAG_INVALID            6
`define FLAG_REDUCED_ACCURACY   5
`define FLAG_EDGE_POLARITY      0

// Flag field masks (for use in assignments)
`define FLAG_OVERFLOW_MASK          8'h80
`define FLAG_INVALID_MASK           8'h40
`define FLAG_REDUCED_ACCURACY_MASK  8'h20
`define FLAG_EDGE_POLARITY_MASK     8'h01

// ============================================================================
// Clock Frequencies (for reference/documentation)
// ============================================================================

// Coarse clock period in picoseconds (500 MHz → 2000 ps)
`define CLK_COARSE_PERIOD_PS 2000

// Target fine resolution in picoseconds
`define FINE_RESOLUTION_PS   10

`endif // TIME_TAGGER_PKG_V
