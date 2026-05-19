//-----------------------------------------------------------------------------
// time_tagger_top.v
// Top-level module for the FPGA Time Tagger on Xilinx ZCU216
//-----------------------------------------------------------------------------
// This module instantiates and interconnects all sub-modules:
//   - Clock Manager (MMCM/PLL)
//   - 8× TDC Channels (fine interpolator + coarse counter + tag formatter)
//   - 8× Tag FIFOs (per-channel buffering)
//   - 1× Tag FIFO (coincidence)
//   - Tag Multiplexer/Arbiter (9 sources)
//   - Coincidence Detector
//   - Calibration Module
//   - AXI4-Lite Register File
//   - AXI DMA Engine
//   - Rate Monitor
//-----------------------------------------------------------------------------

`include "time_tagger_pkg.v"

module time_tagger_top (
    // ========================================================================
    // Clock and Reset
    // ========================================================================
    input  wire        clk_board,          // On-board reference clock
    input  wire        clk_ext_10mhz,     // External 10 MHz reference clock
    input  wire        ext_clk_valid,     // External clock present indicator
    input  wire        rst_n,             // Active-low system reset

    // ========================================================================
    // Input Channels (8 channels)
    // ========================================================================
    input  wire [7:0]  event_in,          // 8 input channel signals (LVDS/LVCMOS)

    // ========================================================================
    // Synchronization
    // ========================================================================
    input  wire        sync_pulse,        // External sync pulse (resets coarse counters)

    // ========================================================================
    // AXI4-Lite Slave Interface (Configuration/Status Registers)
    // ========================================================================
    // Write Address Channel
    input  wire [11:0] s_axi_awaddr,      // Write address (4 KB space)
    input  wire [2:0]  s_axi_awprot,      // Write protection type
    input  wire        s_axi_awvalid,     // Write address valid
    output wire        s_axi_awready,     // Write address ready

    // Write Data Channel
    input  wire [31:0] s_axi_wdata,       // Write data
    input  wire [3:0]  s_axi_wstrb,       // Write strobes
    input  wire        s_axi_wvalid,      // Write data valid
    output wire        s_axi_wready,      // Write data ready

    // Write Response Channel
    output wire [1:0]  s_axi_bresp,       // Write response
    output wire        s_axi_bvalid,      // Write response valid
    input  wire        s_axi_bready,      // Write response ready

    // Read Address Channel
    input  wire [11:0] s_axi_araddr,      // Read address
    input  wire [2:0]  s_axi_arprot,      // Read protection type
    input  wire        s_axi_arvalid,     // Read address valid
    output wire        s_axi_arready,     // Read address ready

    // Read Data Channel
    output wire [31:0] s_axi_rdata,       // Read data
    output wire [1:0]  s_axi_rresp,       // Read response
    output wire        s_axi_rvalid,      // Read data valid
    input  wire        s_axi_rready,      // Read data ready

    // ========================================================================
    // AXI4 Master Interface (DMA for bulk Tag_Record readout)
    // ========================================================================
    // Write Address Channel
    output wire [31:0] m_axi_awaddr,      // Write address
    output wire [7:0]  m_axi_awlen,       // Burst length
    output wire [2:0]  m_axi_awsize,      // Burst size
    output wire [1:0]  m_axi_awburst,     // Burst type
    output wire        m_axi_awvalid,     // Write address valid
    input  wire        m_axi_awready,     // Write address ready

    // Write Data Channel
    output wire [127:0] m_axi_wdata,      // Write data (128-bit for efficiency)
    output wire [15:0]  m_axi_wstrb,      // Write strobes
    output wire         m_axi_wlast,      // Write last
    output wire         m_axi_wvalid,     // Write data valid
    input  wire         m_axi_wready,     // Write data ready

    // Write Response Channel
    input  wire [1:0]  m_axi_bresp,       // Write response
    input  wire        m_axi_bvalid,      // Write response valid
    output wire        m_axi_bready,      // Write response ready

    // Read Address Channel (for DMA descriptor fetch if needed)
    output wire [31:0] m_axi_araddr,      // Read address
    output wire [7:0]  m_axi_arlen,       // Burst length
    output wire [2:0]  m_axi_arsize,      // Burst size
    output wire [1:0]  m_axi_arburst,     // Burst type
    output wire        m_axi_arvalid,     // Read address valid
    input  wire        m_axi_arready,     // Read address ready

    // Read Data Channel
    input  wire [127:0] m_axi_rdata,      // Read data
    input  wire [1:0]   m_axi_rresp,      // Read response
    input  wire         m_axi_rlast,      // Read last
    input  wire         m_axi_rvalid,     // Read data valid
    output wire         m_axi_rready,     // Read data ready

    // ========================================================================
    // Status Outputs (directly accessible, active-high)
    // ========================================================================
    output wire        locked,            // Clock PLL locked
    output wire        clk_loss_error,    // External clock lost
    output wire        cal_busy,          // Calibration in progress
    output wire [7:0]  overflow_flags     // Per-channel FIFO overflow flags
);

// ============================================================================
// Internal Clock Domain Signals
// ============================================================================

wire clk_coarse;    // 500 MHz
wire clk_axi;      // 250 MHz
wire clk_dma;      // 250 MHz
wire clk_cal;      // 100 MHz
wire clk_locked;
wire clk_loss;

// ============================================================================
// Register File Configuration Outputs
// ============================================================================

wire [31:0] cfg_ctrl;
wire [7:0]  cfg_ch_enable;
wire [7:0]  cfg_edge_config;
wire [31:0] cfg_cal_ctrl;
wire [31:0] cfg_coinc_group  [0:3];
wire [31:0] cfg_coinc_window [0:3];
wire [31:0] cfg_dma_ctrl;
wire [31:0] cfg_dead_time;
wire        err_clear_strobe;
wire        fifo_rd_en_regfile;

// ============================================================================
// Register File Status Inputs
// ============================================================================

wire [31:0] sts_status;
wire [31:0] sts_clk_status;
wire [31:0] sts_cal_status;
wire [31:0] sts_temp;
wire [31:0] sts_ch_status  [0:7];
wire [31:0] sts_tag_rate   [0:7];
wire [31:0] sts_err_count  [0:7];
wire [31:0] sts_fifo_data;
wire [31:0] sts_fifo_status;
wire [31:0] sts_dma_status;
wire [31:0] sts_rate_ovf;

// ============================================================================
// TDC Channel Signals
// ============================================================================

wire [95:0] tdc_tag_record [0:7];
wire [7:0]  tdc_tag_valid;
wire [7:0]  tdc_overflow;

// ============================================================================
// Calibration Signals
// ============================================================================

wire [`NUM_TAPS*8-1:0] cal_lut_data [0:`NUM_CHANNELS-1];
wire [`NUM_CHANNELS-1:0] cal_lut_wr;
wire        cal_busy_w;
wire        cal_done_w;
wire        cal_fail_w;

// ============================================================================
// FIFO Signals (8 channel FIFOs + 1 coincidence FIFO)
// ============================================================================

wire [95:0] fifo_wr_data [0:8];
wire [8:0]  fifo_wr_en;
wire [95:0] fifo_rd_data [0:8];
wire [8:0]  fifo_rd_en;
wire [8:0]  fifo_full;
wire [8:0]  fifo_empty;
wire [8:0]  fifo_high_watermark;
wire [8:0]  fifo_overflow;
wire [13:0] fifo_occupancy [0:8];

// ============================================================================
// Coincidence Detector Signals
// ============================================================================

wire [95:0] coinc_tag;
wire        coinc_valid;
wire        coinc_config_error;

// Coincidence group configuration (extract from register file outputs)
wire [7:0]  coinc_group_mask [0:3];
wire [9:0]  coinc_window     [0:3];
wire [3:0]  coinc_group_enable;

// ============================================================================
// Tag Mux Signals
// ============================================================================

wire [95:0] mux_tag_out;
wire        mux_tag_valid;
wire        mux_tag_ready;

// ============================================================================
// DMA Engine Signals
// ============================================================================

wire [7:0]  dma_actual_count;
wire        dma_busy;
wire        dma_error;
wire [31:0] dma_tag_count;

// ============================================================================
// Rate Monitor Signals
// ============================================================================

wire [31:0] rate_tag_rate  [0:7];
wire [31:0] rate_err_count [0:7];
wire [31:0] rate_ch_status [0:7];
wire        rate_ovf_flag;

// ============================================================================
// Sync Pulse Synchronization (into clk_coarse domain)
// ============================================================================

reg [1:0] sync_pulse_sync;
wire      sync_pulse_coarse;

always @(posedge clk_coarse or negedge rst_n) begin
    if (!rst_n)
        sync_pulse_sync <= 2'b00;
    else
        sync_pulse_sync <= {sync_pulse_sync[0], sync_pulse};
end

assign sync_pulse_coarse = sync_pulse_sync[1];

// ============================================================================
// Clock Manager
// ============================================================================

clock_manager u_clock_manager (
    .clk_board      (clk_board),
    .clk_ext_10mhz (clk_ext_10mhz),
    .ext_clk_valid  (ext_clk_valid),
    .rst_n          (rst_n),
    .clk_coarse     (clk_coarse),
    .clk_axi        (clk_axi),
    .clk_dma        (clk_dma),
    .clk_cal        (clk_cal),
    .locked         (clk_locked),
    .clk_loss_error (clk_loss)
);

// ============================================================================
// TDC Channels (8 instances)
// ============================================================================

genvar ch;
generate
    for (ch = 0; ch < 8; ch = ch + 1) begin : gen_tdc_channel
        tdc_channel #(
            .CHANNEL_ID (ch),
            .NUM_TAPS   (`NUM_TAPS),
            .FINE_BITS  (`FINE_BITS)
        ) u_tdc_channel (
            .clk_coarse   (clk_coarse),
            .rst_n        (rst_n),
            .event_in     (event_in[ch]),
            .enable       (cfg_ch_enable[ch]),
            .falling_en   (cfg_edge_config[ch]),
            .sync_reset   (sync_pulse_coarse),
            .cal_lut_data (cal_lut_data[ch][`NUM_TAPS-1:0]),
            .cal_lut_wr   (cal_lut_wr[ch]),
            .tag_record   (tdc_tag_record[ch]),
            .tag_valid    (tdc_tag_valid[ch]),
            .overflow_flag(tdc_overflow[ch])
        );
    end
endgenerate

// ============================================================================
// Per-Channel Tag FIFOs (8 instances)
// ============================================================================

generate
    for (ch = 0; ch < 8; ch = ch + 1) begin : gen_tag_fifo
        assign fifo_wr_data[ch] = tdc_tag_record[ch];
        assign fifo_wr_en[ch]   = tdc_tag_valid[ch];

        tag_fifo #(
            .DEPTH     (`FIFO_DEPTH),
            .WIDTH     (`TAG_WIDTH),
            .HWM_LEVEL (`FIFO_HWM_LEVEL)
        ) u_tag_fifo (
            .wr_clk        (clk_coarse),
            .rd_clk        (clk_dma),
            .rst_n         (rst_n),
            .wr_data       (fifo_wr_data[ch]),
            .wr_en         (fifo_wr_en[ch]),
            .rd_data       (fifo_rd_data[ch]),
            .rd_en         (fifo_rd_en[ch]),
            .full          (fifo_full[ch]),
            .empty         (fifo_empty[ch]),
            .high_watermark(fifo_high_watermark[ch]),
            .overflow_flag (fifo_overflow[ch]),
            .occupancy     (fifo_occupancy[ch])
        );
    end
endgenerate

// ============================================================================
// Coincidence Detector
// ============================================================================

// Extract coincidence configuration from register file
// cfg_coinc_group[n][7:0] = channel bitmask for group n
// cfg_coinc_window[n][9:0] = window value for group n
// cfg_coinc_group[n][31] = group enable

generate
    for (ch = 0; ch < 4; ch = ch + 1) begin : gen_coinc_cfg
        assign coinc_group_mask[ch]   = cfg_coinc_group[ch][7:0];
        assign coinc_window[ch]       = cfg_coinc_window[ch][9:0];
        assign coinc_group_enable[ch] = cfg_coinc_group[ch][31];
    end
endgenerate

// Coincidence detector input arrays (copies of tag data)
wire [95:0] coinc_tag_in [0:7];
wire [7:0]  coinc_tag_valid_in;

generate
    for (ch = 0; ch < 8; ch = ch + 1) begin : gen_coinc_in
        assign coinc_tag_in[ch] = tdc_tag_record[ch];
    end
endgenerate

assign coinc_tag_valid_in = tdc_tag_valid;

coincidence_detector #(
    .NUM_CHANNELS (`NUM_CHANNELS),
    .NUM_GROUPS   (`NUM_COINC_GROUPS),
    .WINDOW_BITS  (`COINC_WINDOW_BITS)
) u_coincidence_detector (
    .clk_coarse   (clk_coarse),
    .rst_n        (rst_n),
    .tag_in       (coinc_tag_in),
    .tag_valid_in (coinc_tag_valid_in),
    .group_mask   (coinc_group_mask),
    .window       (coinc_window),
    .group_enable (coinc_group_enable),
    .coinc_tag    (coinc_tag),
    .coinc_valid  (coinc_valid),
    .config_error (coinc_config_error)
);

// ============================================================================
// Coincidence FIFO (9th FIFO, index 8)
// ============================================================================

assign fifo_wr_data[8] = coinc_tag;
assign fifo_wr_en[8]   = coinc_valid;

tag_fifo #(
    .DEPTH     (`FIFO_DEPTH),
    .WIDTH     (`TAG_WIDTH),
    .HWM_LEVEL (`FIFO_HWM_LEVEL)
) u_coinc_fifo (
    .wr_clk        (clk_coarse),
    .rd_clk        (clk_dma),
    .rst_n         (rst_n),
    .wr_data       (fifo_wr_data[8]),
    .wr_en         (fifo_wr_en[8]),
    .rd_data       (fifo_rd_data[8]),
    .rd_en         (fifo_rd_en[8]),
    .full          (fifo_full[8]),
    .empty         (fifo_empty[8]),
    .high_watermark(fifo_high_watermark[8]),
    .overflow_flag (fifo_overflow[8]),
    .occupancy     (fifo_occupancy[8])
);

// ============================================================================
// Tag Multiplexer (9 sources: 8 channels + 1 coincidence)
// ============================================================================

tag_mux #(
    .NUM_SOURCES (9),
    .TAG_WIDTH   (`TAG_WIDTH)
) u_tag_mux (
    .clk          (clk_dma),
    .rst_n        (rst_n),
    .fifo_rd_data (fifo_rd_data),
    .fifo_empty   (fifo_empty),
    .fifo_rd_en   (fifo_rd_en),
    .tag_out      (mux_tag_out),
    .tag_valid    (mux_tag_valid),
    .tag_ready    (mux_tag_ready)
);

// ============================================================================
// Calibration Module
// ============================================================================

// Extract calibration control signals from register file
wire cal_trigger  = cfg_cal_ctrl[0];   // Bit 0: manual trigger
wire auto_cal_en  = cfg_cal_ctrl[1];   // Bit 1: auto-calibration enable

calibration_module #(
    .NUM_CHANNELS (`NUM_CHANNELS),
    .NUM_TAPS     (`NUM_TAPS),
    .SAMPLES_MIN  (10000)
) u_calibration_module (
    .clk_cal      (clk_cal),
    .clk_coarse   (clk_coarse),
    .rst_n        (rst_n),
    .cal_trigger  (cal_trigger),
    .auto_cal_en  (auto_cal_en),
    .temperature  (12'd0),             // XADC temperature (placeholder - connect to SYSMONE4)
    .cal_lut      (cal_lut_data),
    .cal_lut_wr   (cal_lut_wr),
    .cal_busy     (cal_busy_w),
    .cal_done     (cal_done_w),
    .cal_fail     (cal_fail_w)
);

// ============================================================================
// AXI Register File
// ============================================================================

axi_register_file u_axi_register_file (
    .clk_axi          (clk_axi),
    .rst_n            (rst_n),

    // AXI4-Lite Slave Interface
    .s_axi_awaddr    (s_axi_awaddr),
    .s_axi_awprot    (s_axi_awprot),
    .s_axi_awvalid   (s_axi_awvalid),
    .s_axi_awready   (s_axi_awready),
    .s_axi_wdata     (s_axi_wdata),
    .s_axi_wstrb     (s_axi_wstrb),
    .s_axi_wvalid    (s_axi_wvalid),
    .s_axi_wready    (s_axi_wready),
    .s_axi_bresp     (s_axi_bresp),
    .s_axi_bvalid    (s_axi_bvalid),
    .s_axi_bready    (s_axi_bready),
    .s_axi_araddr    (s_axi_araddr),
    .s_axi_arprot    (s_axi_arprot),
    .s_axi_arvalid   (s_axi_arvalid),
    .s_axi_arready   (s_axi_arready),
    .s_axi_rdata     (s_axi_rdata),
    .s_axi_rresp     (s_axi_rresp),
    .s_axi_rvalid    (s_axi_rvalid),
    .s_axi_rready    (s_axi_rready),

    // Configuration Outputs
    .cfg_ctrl         (cfg_ctrl),
    .cfg_ch_enable    (cfg_ch_enable),
    .cfg_edge_config  (cfg_edge_config),
    .cfg_cal_ctrl     (cfg_cal_ctrl),
    .cfg_coinc_group  (cfg_coinc_group),
    .cfg_coinc_window (cfg_coinc_window),
    .cfg_dma_ctrl     (cfg_dma_ctrl),
    .cfg_dead_time    (cfg_dead_time),

    // Status Inputs
    .sts_status       (sts_status),
    .sts_clk_status   (sts_clk_status),
    .sts_cal_status   (sts_cal_status),
    .sts_temp         (sts_temp),
    .sts_ch_status    (sts_ch_status),
    .sts_tag_rate     (sts_tag_rate),
    .sts_err_count    (sts_err_count),
    .sts_fifo_data    (sts_fifo_data),
    .sts_fifo_status  (sts_fifo_status),
    .sts_dma_status   (sts_dma_status),
    .sts_rate_ovf     (sts_rate_ovf),

    // Error Clear Strobe
    .err_clear_strobe (err_clear_strobe),

    // FIFO Read Strobe
    .fifo_rd_en       (fifo_rd_en_regfile)
);

// ============================================================================
// AXI DMA Engine
// ============================================================================

// Extract DMA control signals from register file
wire        dma_enable    = cfg_dma_ctrl[0];           // Bit 0: DMA enable
wire [7:0]  dma_burst_len = cfg_dma_ctrl[15:8];       // Bits 15:8: burst length - 1
wire [31:0] dma_base_addr = cfg_dma_ctrl;             // Base address from separate field (simplified: use ctrl[31:0])
wire [31:0] dma_buf_size  = 32'h0010_0000;            // 1 MB default buffer size

axi_dma_engine #(
    .AXI_DATA_WIDTH (128),
    .AXI_ADDR_WIDTH (32),
    .TAG_WIDTH      (`TAG_WIDTH),
    .MAX_BURST_LEN  (256)
) u_axi_dma_engine (
    .clk             (clk_dma),
    .rst_n           (rst_n),

    // Control/Status
    .dma_enable      (dma_enable),
    .dma_base_addr   (32'h1000_0000),   // Fixed base address (configurable via register in full design)
    .dma_buf_size    (dma_buf_size),
    .dma_burst_len   (dma_burst_len),
    .dma_actual_count(dma_actual_count),
    .dma_busy        (dma_busy),
    .dma_error       (dma_error),
    .dma_tag_count   (dma_tag_count),

    // Tag Input (from tag_mux)
    .tag_in          (mux_tag_out),
    .tag_valid       (mux_tag_valid),
    .tag_ready       (mux_tag_ready),

    // AXI4 Master Write Interface
    .m_axi_awaddr    (m_axi_awaddr),
    .m_axi_awlen     (m_axi_awlen),
    .m_axi_awsize    (m_axi_awsize),
    .m_axi_awburst   (m_axi_awburst),
    .m_axi_awvalid   (m_axi_awvalid),
    .m_axi_awready   (m_axi_awready),
    .m_axi_wdata     (m_axi_wdata),
    .m_axi_wstrb     (m_axi_wstrb),
    .m_axi_wlast     (m_axi_wlast),
    .m_axi_wvalid    (m_axi_wvalid),
    .m_axi_wready    (m_axi_wready),
    .m_axi_bresp     (m_axi_bresp),
    .m_axi_bvalid    (m_axi_bvalid),
    .m_axi_bready    (m_axi_bready)
);

// AXI4 Master Read Interface (unused by DMA write engine - tie off)
assign m_axi_araddr  = 32'h0;
assign m_axi_arlen   = 8'h0;
assign m_axi_arsize  = 3'b0;
assign m_axi_arburst = 2'b0;
assign m_axi_arvalid = 1'b0;
assign m_axi_rready  = 1'b1;

// ============================================================================
// Rate Monitor
// ============================================================================

rate_monitor #(
    .NUM_CHANNELS (`NUM_CHANNELS)
) u_rate_monitor (
    .clk_coarse      (clk_coarse),
    .rst_n           (rst_n),
    .tag_valid       (tdc_tag_valid),
    .ch_enable       (cfg_ch_enable),
    .cdc_error       (8'b0),              // CDC error detection (placeholder)
    .fifo_overflow   (fifo_overflow[7:0]),
    .err_clear_strobe(err_clear_strobe),
    .tag_rate        (rate_tag_rate),
    .err_count       (rate_err_count),
    .ch_status       (rate_ch_status),
    .rate_ovf_flag   (rate_ovf_flag)
);

// ============================================================================
// Status Signal Assembly
// ============================================================================

// Global status register: [7:0] channel overflow flags, [8] rate overflow,
// [9] cal_busy, [10] cal_done, [11] cal_fail, [12] coinc_config_error
assign sts_status = {
    19'b0,
    coinc_config_error,     // Bit 12
    cal_fail_w,             // Bit 11
    cal_done_w,             // Bit 10
    cal_busy_w,             // Bit 9
    rate_ovf_flag,          // Bit 8
    fifo_overflow[7:0]      // Bits 7:0
};

// Clock status: [0] locked, [1] ext_clk_valid, [2] clk_loss_error
assign sts_clk_status = {29'b0, clk_loss, ext_clk_valid, clk_locked};

// Calibration status: [0] busy, [1] done, [2] fail
assign sts_cal_status = {29'b0, cal_fail_w, cal_done_w, cal_busy_w};

// Temperature: placeholder (connect to XADC in full design)
assign sts_temp = 32'd0;

// Per-channel status from rate monitor
generate
    for (ch = 0; ch < 8; ch = ch + 1) begin : gen_sts_ch
        assign sts_ch_status[ch] = rate_ch_status[ch];
        assign sts_tag_rate[ch]  = rate_tag_rate[ch];
        assign sts_err_count[ch] = rate_err_count[ch];
    end
endgenerate

// FIFO data: provide first available channel FIFO read data (simplified)
// In full design, this would be muxed based on a channel select register
assign sts_fifo_data = {fifo_rd_data[0][95:64]};

// FIFO status: aggregate occupancy info
// [13:0] = channel 0 occupancy, [14] = any overflow, [15] = any high watermark
assign sts_fifo_status = {
    16'b0,
    fifo_high_watermark[7:0] != 8'b0,  // Bit 15: any HWM
    fifo_overflow[7:0] != 8'b0,         // Bit 14: any overflow
    fifo_occupancy[0]                   // Bits 13:0: ch0 occupancy
};

// DMA status: [0] busy, [1] error, [15:8] actual count, [31:16] reserved
assign sts_dma_status = {16'b0, dma_actual_count, 6'b0, dma_error, dma_busy};

// Rate overflow status
assign sts_rate_ovf = {31'b0, rate_ovf_flag};

// ============================================================================
// Top-Level Output Assignments
// ============================================================================

assign locked         = clk_locked;
assign clk_loss_error = clk_loss;
assign cal_busy       = cal_busy_w;
assign overflow_flags = fifo_overflow[7:0];

endmodule
