//-----------------------------------------------------------------------------
// clock_manager.v
// Clock Manager for FPGA Time Tagger on Xilinx ZCU216 (UltraScale+)
//-----------------------------------------------------------------------------
// Generates all internal clocks from on-board reference or external 10 MHz.
// Uses MMCME4_ADV primitive for clock synthesis.
//
// Features:
//   - Generates clk_coarse (500 MHz), clk_axi (250 MHz), clk_dma (250 MHz),
//     clk_cal (100 MHz) from board reference clock
//   - Phase-locks to external 10 MHz reference (≤100 ps RMS, within 10 ms)
//   - Automatic fallback to internal clock on external reference loss (<1 µs)
//   - Locked/unlocked status and clock-loss error flag
//
// Requirements: 7.1, 7.3, 7.4, 7.5
//-----------------------------------------------------------------------------

`include "time_tagger_pkg.v"

module clock_manager (
    input  wire        clk_board,       // On-board reference clock (e.g., 100 MHz)
    input  wire        clk_ext_10mhz,   // External 10 MHz reference
    input  wire        ext_clk_valid,   // External clock present indicator
    input  wire        rst_n,           // Active-low system reset
    output wire        clk_coarse,      // 500 MHz coarse clock
    output wire        clk_axi,         // 250 MHz AXI register interface clock
    output wire        clk_dma,         // 250 MHz DMA data path clock
    output wire        clk_cal,         // 100 MHz calibration clock
    output wire        locked,          // PLL locked indicator
    output wire        clk_loss_error   // External clock lost flag
);

// ============================================================================
// Parameters
// ============================================================================

// Board reference clock frequency (100 MHz typical for ZCU216)
localparam BOARD_CLK_FREQ_MHZ = 100;

// MMCM configuration for 100 MHz input -> desired outputs
// VCO frequency target: 1000 MHz (must be in range 800-1600 MHz for MMCME4)
// CLKFBOUT_MULT_F = 10.0 -> VCO = 100 MHz * 10 = 1000 MHz
// CLKOUT0: 500 MHz -> DIVCLK_DIVIDE=1, CLKOUT0_DIVIDE_F = 2.0
// CLKOUT1: 250 MHz -> CLKOUT1_DIVIDE = 4
// CLKOUT2: 250 MHz -> CLKOUT2_DIVIDE = 4
// CLKOUT3: 100 MHz -> CLKOUT3_DIVIDE = 10
localparam real CLKFBOUT_MULT   = 10.0;
localparam      DIVCLK_DIVIDE   = 1;
localparam real CLKOUT0_DIVIDE  = 2.0;   // 500 MHz
localparam      CLKOUT1_DIVIDE  = 4;     // 250 MHz
localparam      CLKOUT2_DIVIDE  = 4;     // 250 MHz
localparam      CLKOUT3_DIVIDE  = 10;    // 100 MHz

// External clock loss detection timeout
// At 100 MHz board clock, 1 µs = 100 cycles
// Use a counter to detect loss within 1 µs
localparam EXT_LOSS_TIMEOUT_CYCLES = 100;
localparam EXT_LOSS_CNT_WIDTH      = 7;  // ceil(log2(100)) = 7

// Phase-lock settling time counter
// 10 ms at 100 MHz = 1,000,000 cycles
localparam PHASE_LOCK_SETTLE_CYCLES = 1_000_000;
localparam PHASE_LOCK_CNT_WIDTH     = 20;

// ============================================================================
// Internal Signals
// ============================================================================

// MMCM signals
wire        mmcm_clkfb_out;
wire        mmcm_clkfb_in;
wire        mmcm_clkout0;       // 500 MHz unbuffered
wire        mmcm_clkout1;       // 250 MHz unbuffered
wire        mmcm_clkout2;       // 250 MHz unbuffered
wire        mmcm_clkout3;       // 100 MHz unbuffered
wire        mmcm_locked;

// Buffered clock outputs
wire        clk_coarse_bufg;
wire        clk_axi_bufg;
wire        clk_dma_bufg;
wire        clk_cal_bufg;

// Clock source selection
wire        clkin_selected;     // Selected input clock to MMCM
reg         use_ext_clk;        // 1 = use external, 0 = use board clock

// External clock monitoring
reg  [EXT_LOSS_CNT_WIDTH-1:0] ext_loss_cnt;
reg         ext_clk_lost;       // External clock loss detected
reg         ext_clk_valid_sync1;
reg         ext_clk_valid_sync2;
wire        ext_clk_valid_s;    // Synchronized ext_clk_valid

// Phase-lock state machine
reg  [2:0]  pll_state;
reg  [PHASE_LOCK_CNT_WIDTH-1:0] phase_lock_cnt;
reg         phase_locked;       // Phase-lock achieved

// Clock loss error register
reg         clk_loss_error_reg;

// Reset synchronization
reg         rst_sync1, rst_sync2;
wire        rst_internal;

// ============================================================================
// State Machine States
// ============================================================================
localparam ST_IDLE          = 3'd0;  // Waiting for configuration
localparam ST_INTERNAL      = 3'd1;  // Running on internal board clock
localparam ST_EXT_LOCKING   = 3'd2;  // Switching to external, waiting for lock
localparam ST_EXT_LOCKED    = 3'd3;  // Phase-locked to external reference
localparam ST_FALLBACK      = 3'd4;  // Falling back to internal after loss

// ============================================================================
// Reset Synchronization
// ============================================================================
always @(posedge clk_board or negedge rst_n) begin
    if (!rst_n) begin
        rst_sync1 <= 1'b1;
        rst_sync2 <= 1'b1;
    end else begin
        rst_sync1 <= 1'b0;
        rst_sync2 <= rst_sync1;
    end
end

assign rst_internal = rst_sync2;

// ============================================================================
// External Clock Valid Synchronization (into clk_board domain)
// ============================================================================
always @(posedge clk_board or posedge rst_internal) begin
    if (rst_internal) begin
        ext_clk_valid_sync1 <= 1'b0;
        ext_clk_valid_sync2 <= 1'b0;
    end else begin
        ext_clk_valid_sync1 <= ext_clk_valid;
        ext_clk_valid_sync2 <= ext_clk_valid_sync1;
    end
end

assign ext_clk_valid_s = ext_clk_valid_sync2;

// ============================================================================
// External Clock Loss Detection
// ============================================================================
// Monitor ext_clk_valid signal. If it de-asserts, count cycles.
// If counter reaches timeout (1 µs), declare clock lost.
always @(posedge clk_board or posedge rst_internal) begin
    if (rst_internal) begin
        ext_loss_cnt <= {EXT_LOSS_CNT_WIDTH{1'b0}};
        ext_clk_lost <= 1'b0;
    end else begin
        if (ext_clk_valid_s) begin
            // External clock is present, reset counter
            ext_loss_cnt <= {EXT_LOSS_CNT_WIDTH{1'b0}};
            ext_clk_lost <= 1'b0;
        end else if (use_ext_clk) begin
            // External clock expected but not present
            if (ext_loss_cnt < EXT_LOSS_TIMEOUT_CYCLES[EXT_LOSS_CNT_WIDTH-1:0]) begin
                ext_loss_cnt <= ext_loss_cnt + 1'b1;
            end else begin
                ext_clk_lost <= 1'b1;
            end
        end
    end
end

// ============================================================================
// Phase-Lock / Clock Source State Machine
// ============================================================================
always @(posedge clk_board or posedge rst_internal) begin
    if (rst_internal) begin
        pll_state      <= ST_IDLE;
        use_ext_clk    <= 1'b0;
        phase_locked   <= 1'b0;
        phase_lock_cnt <= {PHASE_LOCK_CNT_WIDTH{1'b0}};
        clk_loss_error_reg <= 1'b0;
    end else begin
        case (pll_state)
            ST_IDLE: begin
                // Start with internal clock
                use_ext_clk <= 1'b0;
                pll_state   <= ST_INTERNAL;
            end

            ST_INTERNAL: begin
                // Running on internal clock
                phase_locked <= 1'b0;
                if (ext_clk_valid_s) begin
                    // External clock available, begin phase-lock process
                    use_ext_clk    <= 1'b1;
                    phase_lock_cnt <= {PHASE_LOCK_CNT_WIDTH{1'b0}};
                    pll_state      <= ST_EXT_LOCKING;
                end
            end

            ST_EXT_LOCKING: begin
                // Waiting for MMCM to lock to external reference
                if (!ext_clk_valid_s || ext_clk_lost) begin
                    // External clock lost during locking
                    use_ext_clk    <= 1'b0;
                    clk_loss_error_reg <= 1'b1;
                    pll_state      <= ST_FALLBACK;
                end else if (mmcm_locked) begin
                    // MMCM locked, wait for phase settling (10 ms)
                    if (phase_lock_cnt >= PHASE_LOCK_SETTLE_CYCLES[PHASE_LOCK_CNT_WIDTH-1:0]) begin
                        phase_locked <= 1'b1;
                        pll_state    <= ST_EXT_LOCKED;
                    end else begin
                        phase_lock_cnt <= phase_lock_cnt + 1'b1;
                    end
                end else begin
                    // MMCM not yet locked, reset settle counter
                    phase_lock_cnt <= {PHASE_LOCK_CNT_WIDTH{1'b0}};
                end
            end

            ST_EXT_LOCKED: begin
                // Phase-locked to external reference
                if (!ext_clk_valid_s || ext_clk_lost) begin
                    // External clock lost! Initiate fallback
                    use_ext_clk    <= 1'b0;
                    phase_locked   <= 1'b0;
                    clk_loss_error_reg <= 1'b1;
                    pll_state      <= ST_FALLBACK;
                end else if (!mmcm_locked) begin
                    // MMCM lost lock (shouldn't happen normally)
                    phase_locked   <= 1'b0;
                    phase_lock_cnt <= {PHASE_LOCK_CNT_WIDTH{1'b0}};
                    pll_state      <= ST_EXT_LOCKING;
                end
            end

            ST_FALLBACK: begin
                // Switched back to internal clock after loss
                use_ext_clk  <= 1'b0;
                phase_locked <= 1'b0;
                if (mmcm_locked) begin
                    // Re-locked on internal clock
                    pll_state <= ST_INTERNAL;
                end
            end

            default: begin
                pll_state <= ST_IDLE;
            end
        endcase
    end
end

// ============================================================================
// Clock Input MUX (BUFGMUX_CTRL for glitch-free switching)
// ============================================================================
// Use BUFGMUX_CTRL to select between board clock and external 10 MHz reference.
// The MMCM input clock is selected based on use_ext_clk.
// For external 10 MHz, the MMCM multiplier is adjusted via dynamic reconfiguration
// or we use a separate PLL to multiply 10 MHz to 100 MHz first.
//
// Design choice: Use a dedicated PLL (PLLE4_ADV) to multiply 10 MHz -> 100 MHz,
// then feed into the main MMCM. This keeps the MMCM configuration constant.

wire clk_ext_100mhz;    // 10 MHz multiplied to 100 MHz
wire ext_pll_locked;
wire ext_pll_fb;
wire clk_ext_100mhz_unbuf;

// External reference PLL: 10 MHz -> 100 MHz
// VCO = 10 MHz * 100 = 1000 MHz, CLKOUT0_DIVIDE = 10 -> 100 MHz
PLLE4_ADV #(
    .CLKFBOUT_MULT    (100),        // VCO = 10 MHz * 100 = 1000 MHz
    .CLKIN_PERIOD      (100.000),   // 10 MHz = 100 ns period
    .CLKOUT0_DIVIDE    (10),        // 1000 MHz / 10 = 100 MHz
    .CLKOUT0_PHASE     (0.000),
    .DIVCLK_DIVIDE     (1),
    .STARTUP_WAIT      ("FALSE")
) ext_pll_inst (
    .CLKIN       (clk_ext_10mhz),
    .CLKFBIN     (ext_pll_fb),
    .CLKFBOUT    (ext_pll_fb),
    .CLKOUT0     (clk_ext_100mhz_unbuf),
    .CLKOUT1     (),
    .LOCKED      (ext_pll_locked),
    .PWRDWN      (1'b0),
    .RST         (rst_internal || !ext_clk_valid_s),
    // Dynamic reconfiguration port (unused)
    .DADDR       (7'h0),
    .DCLK        (1'b0),
    .DEN         (1'b0),
    .DI          (16'h0),
    .DO          (),
    .DRDY        (),
    .DWE         (1'b0),
    // Phase shift (unused)
    .PSCLK       (1'b0),
    .PSEN        (1'b0),
    .PSINCDEC    (1'b0),
    .PSDONE      ()
);

// Buffer the external PLL output
BUFG ext_100mhz_bufg_inst (
    .I (clk_ext_100mhz_unbuf),
    .O (clk_ext_100mhz)
);

// Glitch-free clock MUX: select between board clock and external-derived 100 MHz
// S=0 selects I0 (board clock), S=1 selects I1 (external-derived)
BUFGMUX_CTRL clk_mux_inst (
    .O  (clkin_selected),
    .I0 (clk_board),
    .I1 (clk_ext_100mhz),
    .S  (use_ext_clk && ext_pll_locked),
    .CE (1'b1)
);

// ============================================================================
// Main MMCM: Generates all system clocks
// ============================================================================
// Input: 100 MHz (from board or external-derived)
// VCO = 100 MHz * 10 = 1000 MHz
// CLKOUT0: 1000/2 = 500 MHz (clk_coarse)
// CLKOUT1: 1000/4 = 250 MHz (clk_axi)
// CLKOUT2: 1000/4 = 250 MHz (clk_dma)
// CLKOUT3: 1000/10 = 100 MHz (clk_cal)

wire mmcm_clkout0_unbuf;
wire mmcm_clkout1_unbuf;
wire mmcm_clkout2_unbuf;
wire mmcm_clkout3_unbuf;
wire mmcm_clkfb_unbuf;

MMCME4_ADV #(
    .BANDWIDTH          ("OPTIMIZED"),
    .CLKFBOUT_MULT_F    (CLKFBOUT_MULT),    // 10.0 -> VCO = 1000 MHz
    .CLKFBOUT_PHASE     (0.000),
    .CLKIN1_PERIOD       (10.000),            // 100 MHz = 10 ns
    .CLKIN2_PERIOD       (10.000),
    .CLKOUT0_DIVIDE_F   (CLKOUT0_DIVIDE),   // 2.0 -> 500 MHz
    .CLKOUT0_PHASE      (0.000),
    .CLKOUT0_DUTY_CYCLE (0.500),
    .CLKOUT1_DIVIDE     (CLKOUT1_DIVIDE),   // 4 -> 250 MHz
    .CLKOUT1_PHASE      (0.000),
    .CLKOUT1_DUTY_CYCLE (0.500),
    .CLKOUT2_DIVIDE     (CLKOUT2_DIVIDE),   // 4 -> 250 MHz
    .CLKOUT2_PHASE      (0.000),
    .CLKOUT2_DUTY_CYCLE (0.500),
    .CLKOUT3_DIVIDE     (CLKOUT3_DIVIDE),   // 10 -> 100 MHz
    .CLKOUT3_PHASE      (0.000),
    .CLKOUT3_DUTY_CYCLE (0.500),
    .CLKOUT4_DIVIDE     (1),
    .CLKOUT5_DIVIDE     (1),
    .CLKOUT6_DIVIDE     (1),
    .DIVCLK_DIVIDE      (DIVCLK_DIVIDE),    // 1
    .REF_JITTER1        (0.010),
    .REF_JITTER2        (0.010),
    .STARTUP_WAIT       ("FALSE"),
    .SS_EN              ("FALSE"),
    .SS_MODE            ("CENTER_HIGH"),
    .SS_MOD_PERIOD      (10000),
    .COMPENSATION       ("AUTO")
) mmcm_inst (
    // Clock inputs
    .CLKIN1      (clkin_selected),
    .CLKIN2      (1'b0),
    .CLKINSEL    (1'b1),              // Always select CLKIN1

    // Feedback
    .CLKFBIN     (mmcm_clkfb_in),
    .CLKFBOUT    (mmcm_clkfb_unbuf),
    .CLKFBOUTB   (),

    // Clock outputs
    .CLKOUT0     (mmcm_clkout0_unbuf),
    .CLKOUT0B    (),
    .CLKOUT1     (mmcm_clkout1_unbuf),
    .CLKOUT1B    (),
    .CLKOUT2     (mmcm_clkout2_unbuf),
    .CLKOUT2B    (),
    .CLKOUT3     (mmcm_clkout3_unbuf),
    .CLKOUT3B    (),
    .CLKOUT4     (),
    .CLKOUT5     (),
    .CLKOUT6     (),

    // Status
    .LOCKED      (mmcm_locked),
    .CLKINSTOPPED (),
    .CLKFBSTOPPED (),

    // Control
    .PWRDWN      (1'b0),
    .RST         (rst_internal),

    // Dynamic reconfiguration (unused - static configuration)
    .DADDR       (7'h0),
    .DCLK        (1'b0),
    .DEN         (1'b0),
    .DI          (16'h0),
    .DO          (),
    .DRDY        (),
    .DWE         (1'b0),

    // Dynamic phase shift (unused)
    .PSCLK       (1'b0),
    .PSEN        (1'b0),
    .PSINCDEC    (1'b0),
    .PSDONE      (),

    // Clock divide reset (UltraScale+)
    .CDDCREQ     (1'b0),
    .CDDCDONE    ()
);

// ============================================================================
// Clock Output Buffers
// ============================================================================

// Feedback buffer (required for proper MMCM operation)
BUFG clkfb_bufg_inst (
    .I (mmcm_clkfb_unbuf),
    .O (mmcm_clkfb_in)
);

// 500 MHz coarse clock buffer
BUFG clk_coarse_bufg_inst (
    .I (mmcm_clkout0_unbuf),
    .O (clk_coarse_bufg)
);

// 250 MHz AXI clock buffer
BUFG clk_axi_bufg_inst (
    .I (mmcm_clkout1_unbuf),
    .O (clk_axi_bufg)
);

// 250 MHz DMA clock buffer
BUFG clk_dma_bufg_inst (
    .I (mmcm_clkout2_unbuf),
    .O (clk_dma_bufg)
);

// 100 MHz calibration clock buffer
BUFG clk_cal_bufg_inst (
    .I (mmcm_clkout3_unbuf),
    .O (clk_cal_bufg)
);

// ============================================================================
// Output Assignments
// ============================================================================

assign clk_coarse    = clk_coarse_bufg;
assign clk_axi      = clk_axi_bufg;
assign clk_dma      = clk_dma_bufg;
assign clk_cal      = clk_cal_bufg;
assign locked        = mmcm_locked && (!use_ext_clk || (use_ext_clk && ext_pll_locked));
assign clk_loss_error = clk_loss_error_reg;

endmodule
