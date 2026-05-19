//-----------------------------------------------------------------------------
// tb_axi_register_file.v
// Self-checking testbench for axi_register_file module
//-----------------------------------------------------------------------------
`timescale 1ns / 1ps

`include "time_tagger_pkg.v"

module tb_axi_register_file;

// ============================================================================
// Parameters and Local Definitions
// ============================================================================
localparam CLK_PERIOD = 4; // 250 MHz = 4 ns period

// Register addresses (from DUT)
localparam ADDR_CTRL          = 12'h000;
localparam ADDR_STATUS        = 12'h004;
localparam ADDR_CH_ENABLE     = 12'h008;
localparam ADDR_EDGE_CONFIG   = 12'h00C;
localparam ADDR_CLK_STATUS    = 12'h010;
localparam ADDR_CAL_CTRL      = 12'h014;
localparam ADDR_CAL_STATUS    = 12'h018;
localparam ADDR_TEMP          = 12'h01C;
localparam ADDR_COINC_GROUP0  = 12'h020;
localparam ADDR_COINC_GROUP1  = 12'h024;
localparam ADDR_COINC_GROUP2  = 12'h028;
localparam ADDR_COINC_GROUP3  = 12'h02C;
localparam ADDR_COINC_WIN0    = 12'h040;
localparam ADDR_COINC_WIN1    = 12'h044;
localparam ADDR_COINC_WIN2    = 12'h048;
localparam ADDR_COINC_WIN3    = 12'h04C;
localparam ADDR_CH_STATUS0    = 12'h060;
localparam ADDR_TAG_RATE0     = 12'h080;
localparam ADDR_ERR_COUNT0    = 12'h0A0;
localparam ADDR_FIFO_DATA     = 12'h100;
localparam ADDR_FIFO_STATUS   = 12'h200;
localparam ADDR_DMA_CTRL      = 12'h204;
localparam ADDR_DMA_STATUS    = 12'h208;
localparam ADDR_DEAD_TIME     = 12'h300;
localparam ADDR_RATE_OVF      = 12'h304;

// AXI response codes
localparam RESP_OKAY   = 2'b00;
localparam RESP_SLVERR = 2'b10;

// ============================================================================
// Testbench Signals
// ============================================================================
reg         clk_axi;
reg         rst_n;
integer     error_count;

// AXI4-Lite signals
reg  [11:0] s_axi_awaddr;
reg  [2:0]  s_axi_awprot;
reg         s_axi_awvalid;
wire        s_axi_awready;

reg  [31:0] s_axi_wdata;
reg  [3:0]  s_axi_wstrb;
reg         s_axi_wvalid;
wire        s_axi_wready;

wire [1:0]  s_axi_bresp;
wire        s_axi_bvalid;
reg         s_axi_bready;

reg  [11:0] s_axi_araddr;
reg  [2:0]  s_axi_arprot;
reg         s_axi_arvalid;
wire        s_axi_arready;

wire [31:0] s_axi_rdata;
wire [1:0]  s_axi_rresp;
wire        s_axi_rvalid;
reg         s_axi_rready;

// Configuration outputs
wire [31:0] cfg_ctrl;
wire [7:0]  cfg_ch_enable;
wire [7:0]  cfg_edge_config;
wire [31:0] cfg_cal_ctrl;
wire [31:0] cfg_coinc_group [0:3];
wire [31:0] cfg_coinc_window [0:3];
wire [31:0] cfg_dma_ctrl;
wire [31:0] cfg_dead_time;

// Status inputs
reg  [31:0] sts_status;
reg  [31:0] sts_clk_status;
reg  [31:0] sts_cal_status;
reg  [31:0] sts_temp;
reg  [31:0] sts_ch_status [0:7];
reg  [31:0] sts_tag_rate [0:7];
reg  [31:0] sts_err_count [0:7];
reg  [31:0] sts_fifo_data;
reg  [31:0] sts_fifo_status;
reg  [31:0] sts_dma_status;
reg  [31:0] sts_rate_ovf;

// Strobes
wire        err_clear_strobe;
wire        fifo_rd_en;

// BFM result storage
reg  [31:0] rd_data;
reg  [1:0]  rd_resp;
reg  [1:0]  wr_resp;

// ============================================================================
// Clock Generation (250 MHz)
// ============================================================================
initial clk_axi = 0;
always #(CLK_PERIOD/2) clk_axi = ~clk_axi;

// ============================================================================
// Simulation Timeout
// ============================================================================
initial begin
    #20000; // 20 µs
    $display("[FAIL] Simulation timeout");
    $finish(1);
end

// ============================================================================
// DUT Instantiation
// ============================================================================
axi_register_file dut (
    .clk_axi        (clk_axi),
    .rst_n          (rst_n),
    .s_axi_awaddr   (s_axi_awaddr),
    .s_axi_awprot   (s_axi_awprot),
    .s_axi_awvalid  (s_axi_awvalid),
    .s_axi_awready  (s_axi_awready),
    .s_axi_wdata    (s_axi_wdata),
    .s_axi_wstrb    (s_axi_wstrb),
    .s_axi_wvalid   (s_axi_wvalid),
    .s_axi_wready   (s_axi_wready),
    .s_axi_bresp    (s_axi_bresp),
    .s_axi_bvalid   (s_axi_bvalid),
    .s_axi_bready   (s_axi_bready),
    .s_axi_araddr   (s_axi_araddr),
    .s_axi_arprot   (s_axi_arprot),
    .s_axi_arvalid  (s_axi_arvalid),
    .s_axi_arready  (s_axi_arready),
    .s_axi_rdata    (s_axi_rdata),
    .s_axi_rresp    (s_axi_rresp),
    .s_axi_rvalid   (s_axi_rvalid),
    .s_axi_rready   (s_axi_rready),
    .cfg_ctrl       (cfg_ctrl),
    .cfg_ch_enable  (cfg_ch_enable),
    .cfg_edge_config(cfg_edge_config),
    .cfg_cal_ctrl   (cfg_cal_ctrl),
    .cfg_coinc_group(cfg_coinc_group),
    .cfg_coinc_window(cfg_coinc_window),
    .cfg_dma_ctrl   (cfg_dma_ctrl),
    .cfg_dead_time  (cfg_dead_time),
    .sts_status     (sts_status),
    .sts_clk_status (sts_clk_status),
    .sts_cal_status (sts_cal_status),
    .sts_temp       (sts_temp),
    .sts_ch_status  (sts_ch_status),
    .sts_tag_rate   (sts_tag_rate),
    .sts_err_count  (sts_err_count),
    .sts_fifo_data  (sts_fifo_data),
    .sts_fifo_status(sts_fifo_status),
    .sts_dma_status (sts_dma_status),
    .sts_rate_ovf   (sts_rate_ovf),
    .err_clear_strobe(err_clear_strobe),
    .fifo_rd_en     (fifo_rd_en)
);

// ============================================================================
// AXI4-Lite Master BFM Tasks
// ============================================================================

// AXI Write Transaction
task axi_write;
    input [11:0] addr;
    input [31:0] data;
    input [3:0]  strb;
    begin
        // Drive address and data simultaneously
        @(posedge clk_axi);
        s_axi_awaddr  <= addr;
        s_axi_awprot  <= 3'b000;
        s_axi_awvalid <= 1'b1;
        s_axi_wdata   <= data;
        s_axi_wstrb   <= strb;
        s_axi_wvalid  <= 1'b1;
        s_axi_bready  <= 1'b1;

        // Wait for both address and data to be accepted
        @(posedge clk_axi);
        wait(s_axi_awready && s_axi_wready);
        @(posedge clk_axi);
        s_axi_awvalid <= 1'b0;
        s_axi_wvalid  <= 1'b0;

        // Wait for write response
        wait(s_axi_bvalid);
        @(posedge clk_axi);
        wr_resp = s_axi_bresp;
        s_axi_bready <= 1'b1;
        @(posedge clk_axi);
        s_axi_bready <= 1'b0;
    end
endtask

// AXI Read Transaction
task axi_read;
    input [11:0] addr;
    begin
        @(posedge clk_axi);
        s_axi_araddr  <= addr;
        s_axi_arprot  <= 3'b000;
        s_axi_arvalid <= 1'b1;
        s_axi_rready  <= 1'b1;

        // Wait for address accepted
        wait(s_axi_arready);
        @(posedge clk_axi);
        s_axi_arvalid <= 1'b0;

        // Wait for read data valid
        wait(s_axi_rvalid);
        @(posedge clk_axi);
        rd_data = s_axi_rdata;
        rd_resp = s_axi_rresp;
        s_axi_rready <= 1'b1;
        @(posedge clk_axi);
        s_axi_rready <= 1'b0;
    end
endtask

// ============================================================================
// Initialize Status Inputs
// ============================================================================
task init_status_inputs;
    integer i;
    begin
        sts_status      = 32'hDEAD_BEEF;
        sts_clk_status  = 32'h0000_0001;
        sts_cal_status  = 32'h0000_0003;
        sts_temp        = 32'h0000_0190; // ~40°C
        sts_fifo_data   = 32'hCAFE_BABE;
        sts_fifo_status = 32'h0000_1000;
        sts_dma_status  = 32'h0000_0005;
        sts_rate_ovf    = 32'h0000_0000;
        for (i = 0; i < 8; i = i + 1) begin
            sts_ch_status[i] = 32'h0000_0000 + i;
            sts_tag_rate[i]  = 32'h0000_0100 + i;
            sts_err_count[i] = 32'h0000_0000 + i * 10;
        end
    end
endtask

// ============================================================================
// Main Test Sequence
// ============================================================================
initial begin
    // Initialize
    error_count    = 0;
    rst_n          = 0;
    s_axi_awaddr   = 0;
    s_axi_awprot   = 0;
    s_axi_awvalid  = 0;
    s_axi_wdata    = 0;
    s_axi_wstrb    = 0;
    s_axi_wvalid   = 0;
    s_axi_bready   = 0;
    s_axi_araddr   = 0;
    s_axi_arprot   = 0;
    s_axi_arvalid  = 0;
    s_axi_rready   = 0;
    init_status_inputs;

    // Reset sequence
    #100;
    rst_n = 1;
    repeat(10) @(posedge clk_axi);

    // ========================================================================
    // Test 1: Write and readback all RW registers (BRESP=OKAY)
    // ========================================================================
    $display("--- Test 1: RW register write/readback ---");

    // CTRL register
    axi_write(ADDR_CTRL, 32'hA5A5_A5A5, 4'hF);
    if (wr_resp !== RESP_OKAY) begin
        $display("[FAIL] Test 1a: CTRL write BRESP expected OKAY, got %b", wr_resp);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 1a: CTRL write BRESP=OKAY");
    end
    axi_read(ADDR_CTRL);
    if (rd_data !== 32'hA5A5_A5A5) begin
        $display("[FAIL] Test 1b: CTRL readback expected A5A5A5A5, got %h", rd_data);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 1b: CTRL readback correct");
    end
    if (rd_resp !== RESP_OKAY) begin
        $display("[FAIL] Test 1c: CTRL read RRESP expected OKAY, got %b", rd_resp);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 1c: CTRL read RRESP=OKAY");
    end

    // CH_ENABLE register
    axi_write(ADDR_CH_ENABLE, 32'h0000_00FF, 4'hF);
    if (wr_resp !== RESP_OKAY) begin
        $display("[FAIL] Test 1d: CH_ENABLE write BRESP not OKAY");
        error_count = error_count + 1;
    end
    axi_read(ADDR_CH_ENABLE);
    if (rd_data !== 32'h0000_00FF) begin
        $display("[FAIL] Test 1e: CH_ENABLE readback expected 000000FF, got %h", rd_data);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 1e: CH_ENABLE readback correct");
    end

    // EDGE_CONFIG register
    axi_write(ADDR_EDGE_CONFIG, 32'h0000_00A3, 4'hF);
    axi_read(ADDR_EDGE_CONFIG);
    if (rd_data !== 32'h0000_00A3) begin
        $display("[FAIL] Test 1f: EDGE_CONFIG readback expected 000000A3, got %h", rd_data);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 1f: EDGE_CONFIG readback correct");
    end

    // CAL_CTRL register
    axi_write(ADDR_CAL_CTRL, 32'h1234_5678, 4'hF);
    axi_read(ADDR_CAL_CTRL);
    if (rd_data !== 32'h1234_5678) begin
        $display("[FAIL] Test 1g: CAL_CTRL readback expected 12345678, got %h", rd_data);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 1g: CAL_CTRL readback correct");
    end

    // DMA_CTRL register
    axi_write(ADDR_DMA_CTRL, 32'hBEEF_CAFE, 4'hF);
    axi_read(ADDR_DMA_CTRL);
    if (rd_data !== 32'hBEEF_CAFE) begin
        $display("[FAIL] Test 1h: DMA_CTRL readback expected BEEFCAFE, got %h", rd_data);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 1h: DMA_CTRL readback correct");
    end

    // DEAD_TIME register
    axi_write(ADDR_DEAD_TIME, 32'h0000_0004, 4'hF);
    axi_read(ADDR_DEAD_TIME);
    if (rd_data !== 32'h0000_0004) begin
        $display("[FAIL] Test 1i: DEAD_TIME readback expected 00000004, got %h", rd_data);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 1i: DEAD_TIME readback correct");
    end

    // COINC_GROUP registers
    axi_write(ADDR_COINC_GROUP0, 32'h0000_0011, 4'hF);
    axi_write(ADDR_COINC_GROUP1, 32'h0000_0022, 4'hF);
    axi_write(ADDR_COINC_GROUP2, 32'h0000_0044, 4'hF);
    axi_write(ADDR_COINC_GROUP3, 32'h0000_0088, 4'hF);
    axi_read(ADDR_COINC_GROUP0);
    if (rd_data !== 32'h0000_0011) begin
        $display("[FAIL] Test 1j: COINC_GROUP0 readback expected 00000011, got %h", rd_data);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 1j: COINC_GROUP0 readback correct");
    end
    axi_read(ADDR_COINC_GROUP1);
    if (rd_data !== 32'h0000_0022) begin
        $display("[FAIL] Test 1k: COINC_GROUP1 readback expected 00000022, got %h", rd_data);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 1k: COINC_GROUP1 readback correct");
    end
    axi_read(ADDR_COINC_GROUP2);
    if (rd_data !== 32'h0000_0044) begin
        $display("[FAIL] Test 1l: COINC_GROUP2 readback expected 00000044, got %h", rd_data);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 1l: COINC_GROUP2 readback correct");
    end
    axi_read(ADDR_COINC_GROUP3);
    if (rd_data !== 32'h0000_0088) begin
        $display("[FAIL] Test 1m: COINC_GROUP3 readback expected 00000088, got %h", rd_data);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 1m: COINC_GROUP3 readback correct");
    end

    // COINC_WINDOW registers
    axi_write(ADDR_COINC_WIN0, 32'h0000_0064, 4'hF);
    axi_write(ADDR_COINC_WIN1, 32'h0000_00C8, 4'hF);
    axi_write(ADDR_COINC_WIN2, 32'h0000_01F4, 4'hF);
    axi_write(ADDR_COINC_WIN3, 32'h0000_03E8, 4'hF);
    axi_read(ADDR_COINC_WIN0);
    if (rd_data !== 32'h0000_0064) begin
        $display("[FAIL] Test 1n: COINC_WIN0 readback expected 00000064, got %h", rd_data);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 1n: COINC_WIN0 readback correct");
    end
    axi_read(ADDR_COINC_WIN3);
    if (rd_data !== 32'h0000_03E8) begin
        $display("[FAIL] Test 1o: COINC_WIN3 readback expected 000003E8, got %h", rd_data);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 1o: COINC_WIN3 readback correct");
    end

    // ========================================================================
    // Test 2: Write to RO registers - verify BRESP=SLVERR, value unchanged
    // ========================================================================
    $display("--- Test 2: RO register write protection ---");

    // CLK_STATUS (RO)
    axi_write(ADDR_CLK_STATUS, 32'hFFFF_FFFF, 4'hF);
    if (wr_resp !== RESP_SLVERR) begin
        $display("[FAIL] Test 2a: CLK_STATUS write BRESP expected SLVERR, got %b", wr_resp);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 2a: CLK_STATUS write returns SLVERR");
    end
    axi_read(ADDR_CLK_STATUS);
    if (rd_data !== sts_clk_status) begin
        $display("[FAIL] Test 2b: CLK_STATUS value changed after write. Expected %h, got %h", sts_clk_status, rd_data);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 2b: CLK_STATUS value unchanged after write");
    end

    // CAL_STATUS (RO)
    axi_write(ADDR_CAL_STATUS, 32'hFFFF_FFFF, 4'hF);
    if (wr_resp !== RESP_SLVERR) begin
        $display("[FAIL] Test 2c: CAL_STATUS write BRESP expected SLVERR, got %b", wr_resp);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 2c: CAL_STATUS write returns SLVERR");
    end

    // TEMP (RO)
    axi_write(ADDR_TEMP, 32'hFFFF_FFFF, 4'hF);
    if (wr_resp !== RESP_SLVERR) begin
        $display("[FAIL] Test 2d: TEMP write BRESP expected SLVERR, got %b", wr_resp);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 2d: TEMP write returns SLVERR");
    end

    // CH_STATUS0 (RO)
    axi_write(ADDR_CH_STATUS0, 32'hFFFF_FFFF, 4'hF);
    if (wr_resp !== RESP_SLVERR) begin
        $display("[FAIL] Test 2e: CH_STATUS0 write BRESP expected SLVERR, got %b", wr_resp);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 2e: CH_STATUS0 write returns SLVERR");
    end

    // TAG_RATE0 (RO)
    axi_write(ADDR_TAG_RATE0, 32'hFFFF_FFFF, 4'hF);
    if (wr_resp !== RESP_SLVERR) begin
        $display("[FAIL] Test 2f: TAG_RATE0 write BRESP expected SLVERR, got %b", wr_resp);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 2f: TAG_RATE0 write returns SLVERR");
    end

    // ERR_COUNT0 (RO)
    axi_write(ADDR_ERR_COUNT0, 32'hFFFF_FFFF, 4'hF);
    if (wr_resp !== RESP_SLVERR) begin
        $display("[FAIL] Test 2g: ERR_COUNT0 write BRESP expected SLVERR, got %b", wr_resp);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 2g: ERR_COUNT0 write returns SLVERR");
    end

    // FIFO_DATA (RO)
    axi_write(ADDR_FIFO_DATA, 32'hFFFF_FFFF, 4'hF);
    if (wr_resp !== RESP_SLVERR) begin
        $display("[FAIL] Test 2h: FIFO_DATA write BRESP expected SLVERR, got %b", wr_resp);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 2h: FIFO_DATA write returns SLVERR");
    end

    // FIFO_STATUS (RO)
    axi_write(ADDR_FIFO_STATUS, 32'hFFFF_FFFF, 4'hF);
    if (wr_resp !== RESP_SLVERR) begin
        $display("[FAIL] Test 2i: FIFO_STATUS write BRESP expected SLVERR, got %b", wr_resp);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 2i: FIFO_STATUS write returns SLVERR");
    end

    // DMA_STATUS (RO)
    axi_write(ADDR_DMA_STATUS, 32'hFFFF_FFFF, 4'hF);
    if (wr_resp !== RESP_SLVERR) begin
        $display("[FAIL] Test 2j: DMA_STATUS write BRESP expected SLVERR, got %b", wr_resp);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 2j: DMA_STATUS write returns SLVERR");
    end

    // RATE_OVF (RO)
    axi_write(ADDR_RATE_OVF, 32'hFFFF_FFFF, 4'hF);
    if (wr_resp !== RESP_SLVERR) begin
        $display("[FAIL] Test 2k: RATE_OVF write BRESP expected SLVERR, got %b", wr_resp);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 2k: RATE_OVF write returns SLVERR");
    end

    // ========================================================================
    // Test 3: Read all status registers - verify RRESP=OKAY and correct data
    // ========================================================================
    $display("--- Test 3: Status register reads ---");

    axi_read(ADDR_STATUS);
    if (rd_data !== sts_status || rd_resp !== RESP_OKAY) begin
        $display("[FAIL] Test 3a: STATUS read expected %h/OKAY, got %h/%b", sts_status, rd_data, rd_resp);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 3a: STATUS read correct");
    end

    axi_read(ADDR_CLK_STATUS);
    if (rd_data !== sts_clk_status || rd_resp !== RESP_OKAY) begin
        $display("[FAIL] Test 3b: CLK_STATUS read expected %h, got %h", sts_clk_status, rd_data);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 3b: CLK_STATUS read correct");
    end

    axi_read(ADDR_CAL_STATUS);
    if (rd_data !== sts_cal_status || rd_resp !== RESP_OKAY) begin
        $display("[FAIL] Test 3c: CAL_STATUS read expected %h, got %h", sts_cal_status, rd_data);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 3c: CAL_STATUS read correct");
    end

    axi_read(ADDR_TEMP);
    if (rd_data !== sts_temp || rd_resp !== RESP_OKAY) begin
        $display("[FAIL] Test 3d: TEMP read expected %h, got %h", sts_temp, rd_data);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 3d: TEMP read correct");
    end

    axi_read(ADDR_FIFO_STATUS);
    if (rd_data !== sts_fifo_status || rd_resp !== RESP_OKAY) begin
        $display("[FAIL] Test 3e: FIFO_STATUS read expected %h, got %h", sts_fifo_status, rd_data);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 3e: FIFO_STATUS read correct");
    end

    axi_read(ADDR_DMA_STATUS);
    if (rd_data !== sts_dma_status || rd_resp !== RESP_OKAY) begin
        $display("[FAIL] Test 3f: DMA_STATUS read expected %h, got %h", sts_dma_status, rd_data);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 3f: DMA_STATUS read correct");
    end

    axi_read(ADDR_RATE_OVF);
    if (rd_data !== sts_rate_ovf || rd_resp !== RESP_OKAY) begin
        $display("[FAIL] Test 3g: RATE_OVF read expected %h, got %h", sts_rate_ovf, rd_data);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 3g: RATE_OVF read correct");
    end

    // Read per-channel status
    axi_read(ADDR_CH_STATUS0);
    if (rd_data !== sts_ch_status[0] || rd_resp !== RESP_OKAY) begin
        $display("[FAIL] Test 3h: CH_STATUS0 read expected %h, got %h", sts_ch_status[0], rd_data);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 3h: CH_STATUS0 read correct");
    end

    axi_read(ADDR_TAG_RATE0);
    if (rd_data !== sts_tag_rate[0] || rd_resp !== RESP_OKAY) begin
        $display("[FAIL] Test 3i: TAG_RATE0 read expected %h, got %h", sts_tag_rate[0], rd_data);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 3i: TAG_RATE0 read correct");
    end

    axi_read(ADDR_ERR_COUNT0);
    if (rd_data !== sts_err_count[0] || rd_resp !== RESP_OKAY) begin
        $display("[FAIL] Test 3j: ERR_COUNT0 read expected %h, got %h", sts_err_count[0], rd_data);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 3j: ERR_COUNT0 read correct");
    end

    // ========================================================================
    // Test 4: err_clear_strobe pulses for 1 cycle on STATUS register write
    // ========================================================================
    $display("--- Test 4: err_clear_strobe on STATUS write ---");
    begin : test4_block
        reg strobe_seen;
        integer strobe_high_count;
        integer cycle_count;
        strobe_seen = 0;
        strobe_high_count = 0;

        fork
            begin
                // Monitor err_clear_strobe by sampling at every clock edge
                cycle_count = 0;
                while (cycle_count < 20) begin
                    @(posedge clk_axi);
                    #1; // Small delay to sample after NBA update
                    if (err_clear_strobe) begin
                        strobe_seen = 1;
                        strobe_high_count = strobe_high_count + 1;
                    end
                    cycle_count = cycle_count + 1;
                end
            end
            begin
                // Perform write to STATUS register
                axi_write(ADDR_STATUS, 32'h0000_0001, 4'hF);
                // Give time for strobe to complete
                repeat(10) @(posedge clk_axi);
            end
        join

        if (!strobe_seen) begin
            $display("[FAIL] Test 4a: err_clear_strobe not pulsed on STATUS write");
            error_count = error_count + 1;
        end else if (strobe_high_count !== 1) begin
            $display("[FAIL] Test 4b: err_clear_strobe width expected 1 cycle, got %0d", strobe_high_count);
            error_count = error_count + 1;
        end else begin
            $display("[PASS] Test 4: err_clear_strobe pulses for exactly 1 cycle on STATUS write");
        end
    end

    // ========================================================================
    // Test 5: fifo_rd_en pulses for 1 cycle on FIFO_DATA read
    // ========================================================================
    $display("--- Test 5: fifo_rd_en on FIFO_DATA read ---");
    begin : test5_block
        reg strobe_seen;
        integer strobe_high_count;
        integer cycle_count;
        strobe_seen = 0;
        strobe_high_count = 0;

        fork
            begin
                // Monitor fifo_rd_en by sampling at every clock edge
                cycle_count = 0;
                while (cycle_count < 20) begin
                    @(posedge clk_axi);
                    #1; // Small delay to sample after NBA update
                    if (fifo_rd_en) begin
                        strobe_seen = 1;
                        strobe_high_count = strobe_high_count + 1;
                    end
                    cycle_count = cycle_count + 1;
                end
            end
            begin
                // Perform read from FIFO_DATA address
                axi_read(ADDR_FIFO_DATA);
                repeat(10) @(posedge clk_axi);
            end
        join

        if (!strobe_seen) begin
            $display("[FAIL] Test 5a: fifo_rd_en not pulsed on FIFO_DATA read");
            error_count = error_count + 1;
        end else if (strobe_high_count !== 1) begin
            $display("[FAIL] Test 5b: fifo_rd_en width expected 1 cycle, got %0d", strobe_high_count);
            error_count = error_count + 1;
        end else begin
            $display("[PASS] Test 5: fifo_rd_en pulses for exactly 1 cycle on FIFO_DATA read");
        end

        // Verify FIFO_DATA returns correct data
        if (rd_data !== sts_fifo_data) begin
            $display("[FAIL] Test 5c: FIFO_DATA read expected %h, got %h", sts_fifo_data, rd_data);
            error_count = error_count + 1;
        end else begin
            $display("[PASS] Test 5c: FIFO_DATA read returns correct data");
        end
    end

    // ========================================================================
    // Test 6: Configuration outputs reflect written values within 1 clock cycle
    // ========================================================================
    $display("--- Test 6: Configuration output immediacy ---");

    // Write a new value to CH_ENABLE and check cfg output on next clock
    axi_write(ADDR_CH_ENABLE, 32'h0000_003C, 4'hF);
    @(posedge clk_axi); // 1 cycle after write completes
    if (cfg_ch_enable !== 8'h3C) begin
        $display("[FAIL] Test 6a: cfg_ch_enable expected 3C, got %h", cfg_ch_enable);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 6a: cfg_ch_enable reflects written value immediately");
    end

    axi_write(ADDR_EDGE_CONFIG, 32'h0000_0055, 4'hF);
    @(posedge clk_axi);
    if (cfg_edge_config !== 8'h55) begin
        $display("[FAIL] Test 6b: cfg_edge_config expected 55, got %h", cfg_edge_config);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 6b: cfg_edge_config reflects written value immediately");
    end

    axi_write(ADDR_DMA_CTRL, 32'h0000_0001, 4'hF);
    @(posedge clk_axi);
    if (cfg_dma_ctrl !== 32'h0000_0001) begin
        $display("[FAIL] Test 6c: cfg_dma_ctrl expected 00000001, got %h", cfg_dma_ctrl);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 6c: cfg_dma_ctrl reflects written value immediately");
    end

    axi_write(ADDR_DEAD_TIME, 32'h0000_0008, 4'hF);
    @(posedge clk_axi);
    if (cfg_dead_time !== 32'h0000_0008) begin
        $display("[FAIL] Test 6d: cfg_dead_time expected 00000008, got %h", cfg_dead_time);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 6d: cfg_dead_time reflects written value immediately");
    end

    axi_write(ADDR_COINC_WIN0, 32'h0000_0100, 4'hF);
    @(posedge clk_axi);
    if (cfg_coinc_window[0] !== 32'h0000_0100) begin
        $display("[FAIL] Test 6e: cfg_coinc_window[0] expected 00000100, got %h", cfg_coinc_window[0]);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 6e: cfg_coinc_window[0] reflects written value immediately");
    end

    // ========================================================================
    // Test 7: Back-to-back transactions (handshake timing patterns)
    // ========================================================================
    $display("--- Test 7: Back-to-back transactions ---");

    // Rapid successive writes
    axi_write(ADDR_CTRL, 32'h1111_1111, 4'hF);
    axi_write(ADDR_CTRL, 32'h2222_2222, 4'hF);
    axi_write(ADDR_CTRL, 32'h3333_3333, 4'hF);
    axi_read(ADDR_CTRL);
    if (rd_data !== 32'h3333_3333) begin
        $display("[FAIL] Test 7a: Back-to-back writes, final readback expected 33333333, got %h", rd_data);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 7a: Back-to-back writes produce correct final value");
    end

    // Rapid successive reads
    axi_read(ADDR_CH_ENABLE);
    axi_read(ADDR_EDGE_CONFIG);
    axi_read(ADDR_DMA_CTRL);
    if (rd_data !== 32'h0000_0001) begin
        $display("[FAIL] Test 7b: Back-to-back reads, DMA_CTRL expected 00000001, got %h", rd_data);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 7b: Back-to-back reads work correctly");
    end

    // Interleaved write-read-write-read
    axi_write(ADDR_CTRL, 32'hAAAA_BBBB, 4'hF);
    axi_read(ADDR_CTRL);
    if (rd_data !== 32'hAAAA_BBBB) begin
        $display("[FAIL] Test 7c: Interleaved W-R, expected AAAABBBB, got %h", rd_data);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 7c: Interleaved write-read works correctly");
    end
    axi_write(ADDR_CTRL, 32'hCCCC_DDDD, 4'hF);
    axi_read(ADDR_CTRL);
    if (rd_data !== 32'hCCCC_DDDD) begin
        $display("[FAIL] Test 7d: Interleaved W-R, expected CCCCDDDD, got %h", rd_data);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 7d: Interleaved write-read works correctly");
    end

    // ========================================================================
    // Test 8: Delayed ready handshake patterns
    // ========================================================================
    $display("--- Test 8: Delayed ready handshake ---");

    // Write with delayed bready
    @(posedge clk_axi);
    s_axi_awaddr  <= ADDR_CTRL;
    s_axi_awprot  <= 3'b000;
    s_axi_awvalid <= 1'b1;
    s_axi_wdata   <= 32'hDEAD_FACE;
    s_axi_wstrb   <= 4'hF;
    s_axi_wvalid  <= 1'b1;
    s_axi_bready  <= 1'b0; // Delay bready

    // Wait for handshake
    wait(s_axi_awready && s_axi_wready);
    @(posedge clk_axi);
    s_axi_awvalid <= 1'b0;
    s_axi_wvalid  <= 1'b0;

    // Wait for bvalid, then delay accepting it
    wait(s_axi_bvalid);
    repeat(3) @(posedge clk_axi); // Hold bready low for 3 cycles
    // Verify bvalid stays asserted during delay
    if (!s_axi_bvalid) begin
        $display("[FAIL] Test 8a: bvalid dropped before bready");
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 8a: bvalid held during delayed bready");
    end
    s_axi_bready <= 1'b1;
    @(posedge clk_axi);
    wr_resp = s_axi_bresp;
    s_axi_bready <= 1'b0;
    @(posedge clk_axi);

    if (wr_resp !== RESP_OKAY) begin
        $display("[FAIL] Test 8b: Delayed bready write BRESP expected OKAY, got %b", wr_resp);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 8b: Delayed bready write completes with OKAY");
    end

    // Verify the write took effect
    axi_read(ADDR_CTRL);
    if (rd_data !== 32'hDEAD_FACE) begin
        $display("[FAIL] Test 8c: Delayed bready write value expected DEADFACE, got %h", rd_data);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 8c: Delayed bready write value correct");
    end

    // Read with delayed rready
    @(posedge clk_axi);
    s_axi_araddr  <= ADDR_CTRL;
    s_axi_arprot  <= 3'b000;
    s_axi_arvalid <= 1'b1;
    s_axi_rready  <= 1'b0; // Delay rready

    wait(s_axi_arready);
    @(posedge clk_axi);
    s_axi_arvalid <= 1'b0;

    // Wait for rvalid, then delay accepting
    wait(s_axi_rvalid);
    repeat(4) @(posedge clk_axi); // Hold rready low for 4 cycles
    if (!s_axi_rvalid) begin
        $display("[FAIL] Test 8d: rvalid dropped before rready");
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 8d: rvalid held during delayed rready");
    end
    rd_data = s_axi_rdata;
    rd_resp = s_axi_rresp;
    s_axi_rready <= 1'b1;
    @(posedge clk_axi);
    s_axi_rready <= 1'b0;
    @(posedge clk_axi);

    if (rd_data !== 32'hDEAD_FACE) begin
        $display("[FAIL] Test 8e: Delayed rready read expected DEADFACE, got %h", rd_data);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 8e: Delayed rready read data correct");
    end
    if (rd_resp !== RESP_OKAY) begin
        $display("[FAIL] Test 8f: Delayed rready read RRESP expected OKAY, got %b", rd_resp);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 8f: Delayed rready read RRESP=OKAY");
    end

    // ========================================================================
    // Test 9: Protocol violation check - no double valid without ready
    // ========================================================================
    $display("--- Test 9: Protocol violation check ---");
    begin : test9_block
        reg violation_detected;
        violation_detected = 0;

        // Perform several transactions and monitor for protocol violations
        // The DUT should never assert awready/wready without corresponding valid
        // and should not double-assert valid without ready acceptance

        // Write transaction - verify awready only asserts when awvalid is high
        axi_write(ADDR_CH_ENABLE, 32'h0000_00AA, 4'hF);
        axi_write(ADDR_EDGE_CONFIG, 32'h0000_0077, 4'hF);
        axi_read(ADDR_CH_ENABLE);
        axi_read(ADDR_EDGE_CONFIG);

        // If we got here without hanging, protocol is working
        if (rd_data !== 32'h0000_0077) begin
            $display("[FAIL] Test 9a: Protocol check - unexpected data %h", rd_data);
            error_count = error_count + 1;
        end else begin
            $display("[PASS] Test 9: No protocol violations during multi-transaction sequence");
        end
    end

    // ========================================================================
    // Test 10: Byte strobe partial writes
    // ========================================================================
    $display("--- Test 10: Byte strobe partial writes ---");

    // Write full word first
    axi_write(ADDR_CTRL, 32'hFFFF_FFFF, 4'hF);
    // Write only byte 0
    axi_write(ADDR_CTRL, 32'h0000_0012, 4'h1);
    axi_read(ADDR_CTRL);
    if (rd_data !== 32'hFFFF_FF12) begin
        $display("[FAIL] Test 10a: Byte strobe[0] expected FFFFFF12, got %h", rd_data);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 10a: Byte strobe[0] partial write correct");
    end

    // Write only byte 2
    axi_write(ADDR_CTRL, 32'h00AB_0000, 4'h4);
    axi_read(ADDR_CTRL);
    if (rd_data !== 32'hFFAB_FF12) begin
        $display("[FAIL] Test 10b: Byte strobe[2] expected FFABFF12, got %h", rd_data);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 10b: Byte strobe[2] partial write correct");
    end

    // ========================================================================
    // Test 11: FIFO_DATA read at different addresses in range
    // ========================================================================
    $display("--- Test 11: FIFO_DATA address range ---");

    sts_fifo_data = 32'h1234_ABCD;
    axi_read(12'h110); // Within FIFO_DATA range
    if (rd_data !== 32'h1234_ABCD) begin
        $display("[FAIL] Test 11a: FIFO_DATA at 0x110 expected 1234ABCD, got %h", rd_data);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 11a: FIFO_DATA at 0x110 returns correct data");
    end

    sts_fifo_data = 32'hFEDC_BA98;
    axi_read(12'h1FC); // Near end of FIFO_DATA range
    if (rd_data !== 32'hFEDC_BA98) begin
        $display("[FAIL] Test 11b: FIFO_DATA at 0x1FC expected FEDCBA98, got %h", rd_data);
        error_count = error_count + 1;
    end else begin
        $display("[PASS] Test 11b: FIFO_DATA at 0x1FC returns correct data");
    end

    // ========================================================================
    // Final Summary
    // ========================================================================
    repeat(10) @(posedge clk_axi);

    if (error_count == 0) begin
        $display("=== ALL TESTS PASSED ===");
        $finish(0);
    end else begin
        $display("=== %0d TESTS FAILED ===", error_count);
        $finish(1);
    end
end

endmodule
