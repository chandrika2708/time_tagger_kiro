//-----------------------------------------------------------------------------
// axi_register_file.v
// AXI4-Lite Slave Register File for the FPGA Time Tagger
//-----------------------------------------------------------------------------
// Provides a 4 KB address space (1024 × 32-bit registers) with:
//   - Full register map: CTRL, STATUS, CH_ENABLE, EDGE_CONFIG, CLK_STATUS,
//     CAL_CTRL, CAL_STATUS, TEMP, COINC_GROUPn, COINC_WINDOWn, CH_STATUSn,
//     TAG_RATEn, ERR_COUNTn, FIFO_DATA, FIFO_STATUS, DMA_CTRL, DMA_STATUS,
//     DEAD_TIME, RATE_OVF
//   - Read-only register write protection with SLVERR response
//   - Configuration application within 10 clock cycles of write
//   - Error flag clearing on STATUS register write
//-----------------------------------------------------------------------------

`include "time_tagger_pkg.v"

module axi_register_file (
    // ========================================================================
    // Clock and Reset
    // ========================================================================
    input  wire        clk_axi,           // 250 MHz AXI clock
    input  wire        rst_n,             // Active-low reset

    // ========================================================================
    // AXI4-Lite Slave Interface
    // ========================================================================
    // Write Address Channel
    input  wire [11:0] s_axi_awaddr,
    input  wire [2:0]  s_axi_awprot,
    input  wire        s_axi_awvalid,
    output reg         s_axi_awready,

    // Write Data Channel
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output reg         s_axi_wready,

    // Write Response Channel
    output reg  [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,

    // Read Address Channel
    input  wire [11:0] s_axi_araddr,
    input  wire [2:0]  s_axi_arprot,
    input  wire        s_axi_arvalid,
    output reg         s_axi_arready,

    // Read Data Channel
    output reg  [31:0] s_axi_rdata,
    output reg  [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,

    // ========================================================================
    // Configuration Outputs (active within 10 clocks of write)
    // ========================================================================
    output reg  [31:0] cfg_ctrl,          // CTRL register
    output reg  [7:0]  cfg_ch_enable,     // Per-channel enable bitmask
    output reg  [7:0]  cfg_edge_config,   // Per-channel falling-edge enable
    output reg  [31:0] cfg_cal_ctrl,      // Calibration control
    output reg  [31:0] cfg_coinc_group [0:3],  // Coincidence group configs
    output reg  [31:0] cfg_coinc_window [0:3], // Coincidence windows
    output reg  [31:0] cfg_dma_ctrl,      // DMA control
    output reg  [31:0] cfg_dead_time,     // Dead time configuration

    // ========================================================================
    // Status Inputs (directly sampled from hardware)
    // ========================================================================
    input  wire [31:0] sts_status,        // Global status flags (hw-generated)
    input  wire [31:0] sts_clk_status,    // Clock lock, ext ref status
    input  wire [31:0] sts_cal_status,    // Calibration busy/done/fail
    input  wire [31:0] sts_temp,          // FPGA temperature
    input  wire [31:0] sts_ch_status [0:7],  // Per-channel status
    input  wire [31:0] sts_tag_rate [0:7],   // Per-channel tag rate
    input  wire [31:0] sts_err_count [0:7],  // Per-channel error counters
    input  wire [31:0] sts_fifo_data,     // FIFO read port data
    input  wire [31:0] sts_fifo_status,   // FIFO occupancy
    input  wire [31:0] sts_dma_status,    // DMA busy, transfer count
    input  wire [31:0] sts_rate_ovf,      // Rate overflow flag

    // ========================================================================
    // Error Clear Strobe
    // ========================================================================
    output reg         err_clear_strobe,  // Pulsed on STATUS register write

    // ========================================================================
    // FIFO Read Strobe
    // ========================================================================
    output reg         fifo_rd_en         // Pulsed on FIFO_DATA read
);

// ============================================================================
// Register Address Offsets (byte addresses, word-aligned)
// ============================================================================
localparam ADDR_CTRL          = 12'h000;
localparam ADDR_STATUS        = 12'h004;
localparam ADDR_CH_ENABLE     = 12'h008;
localparam ADDR_EDGE_CONFIG   = 12'h00C;
localparam ADDR_CLK_STATUS    = 12'h010;
localparam ADDR_CAL_CTRL      = 12'h014;
localparam ADDR_CAL_STATUS    = 12'h018;
localparam ADDR_TEMP          = 12'h01C;

// Coincidence group config: 0x020, 0x024, 0x028, 0x02C (4 groups × 4 bytes)
localparam ADDR_COINC_GROUP_BASE   = 12'h020;
localparam ADDR_COINC_GROUP_END    = 12'h02C;

// Coincidence window: 0x040, 0x044, 0x048, 0x04C (4 groups × 4 bytes)
localparam ADDR_COINC_WINDOW_BASE  = 12'h040;
localparam ADDR_COINC_WINDOW_END   = 12'h04C;

// Per-channel status: 0x060, 0x064, ..., 0x07C (8 channels × 4 bytes)
localparam ADDR_CH_STATUS_BASE     = 12'h060;
localparam ADDR_CH_STATUS_END      = 12'h07C;

// Per-channel tag rate: 0x080, 0x084, ..., 0x09C (8 channels × 4 bytes)
localparam ADDR_TAG_RATE_BASE      = 12'h080;
localparam ADDR_TAG_RATE_END       = 12'h09C;

// Per-channel error counters: 0x0A0, 0x0A4, ..., 0x0BC (8 channels × 4 bytes)
localparam ADDR_ERR_COUNT_BASE     = 12'h0A0;
localparam ADDR_ERR_COUNT_END      = 12'h0BC;

// FIFO data read port: 0x100-0x1FF
localparam ADDR_FIFO_DATA_BASE     = 12'h100;
localparam ADDR_FIFO_DATA_END      = 12'h1FF;

// FIFO/DMA registers
localparam ADDR_FIFO_STATUS   = 12'h200;
localparam ADDR_DMA_CTRL      = 12'h204;
localparam ADDR_DMA_STATUS    = 12'h208;

// Dead time and rate overflow
localparam ADDR_DEAD_TIME     = 12'h300;
localparam ADDR_RATE_OVF      = 12'h304;

// ============================================================================
// AXI4-Lite Response Codes
// ============================================================================
localparam RESP_OKAY   = 2'b00;
localparam RESP_SLVERR = 2'b10;

// ============================================================================
// Internal Signals
// ============================================================================

// Write transaction state machine
reg        aw_ready_r;
reg        w_ready_r;
reg [11:0] wr_addr;
reg        wr_addr_valid;
reg        wr_data_valid;

// Read transaction state machine
reg [11:0] rd_addr;

// ============================================================================
// Read-Only Address Check Function
// ============================================================================
// Returns 1 if the address is read-only (writes should produce SLVERR)
function is_read_only;
    input [11:0] addr;
    begin
        is_read_only = 1'b0;
        // CLK_STATUS (0x010)
        if (addr == ADDR_CLK_STATUS)
            is_read_only = 1'b1;
        // CAL_STATUS (0x018)
        else if (addr == ADDR_CAL_STATUS)
            is_read_only = 1'b1;
        // TEMP (0x01C)
        else if (addr == ADDR_TEMP)
            is_read_only = 1'b1;
        // CH_STATUSn (0x060-0x07C)
        else if (addr >= ADDR_CH_STATUS_BASE && addr <= ADDR_CH_STATUS_END)
            is_read_only = 1'b1;
        // TAG_RATEn (0x080-0x09C)
        else if (addr >= ADDR_TAG_RATE_BASE && addr <= ADDR_TAG_RATE_END)
            is_read_only = 1'b1;
        // ERR_COUNTn (0x0A0-0x0BC)
        else if (addr >= ADDR_ERR_COUNT_BASE && addr <= ADDR_ERR_COUNT_END)
            is_read_only = 1'b1;
        // FIFO_DATA (0x100-0x1FF)
        else if (addr >= ADDR_FIFO_DATA_BASE && addr <= ADDR_FIFO_DATA_END)
            is_read_only = 1'b1;
        // FIFO_STATUS (0x200)
        else if (addr == ADDR_FIFO_STATUS)
            is_read_only = 1'b1;
        // DMA_STATUS (0x208)
        else if (addr == ADDR_DMA_STATUS)
            is_read_only = 1'b1;
        // RATE_OVF (0x304)
        else if (addr == ADDR_RATE_OVF)
            is_read_only = 1'b1;
    end
endfunction

// ============================================================================
// Write Address Channel Handling
// ============================================================================
always @(posedge clk_axi or negedge rst_n) begin
    if (!rst_n) begin
        s_axi_awready <= 1'b0;
        wr_addr       <= 12'h0;
        wr_addr_valid <= 1'b0;
    end else begin
        if (!s_axi_awready && s_axi_awvalid && s_axi_wvalid && !wr_addr_valid) begin
            s_axi_awready <= 1'b1;
            wr_addr       <= s_axi_awaddr;
            wr_addr_valid <= 1'b1;
        end else if (s_axi_bvalid && s_axi_bready) begin
            wr_addr_valid <= 1'b0;
            s_axi_awready <= 1'b0;
        end else begin
            s_axi_awready <= 1'b0;
        end
    end
end

// ============================================================================
// Write Data Channel Handling
// ============================================================================
always @(posedge clk_axi or negedge rst_n) begin
    if (!rst_n) begin
        s_axi_wready  <= 1'b0;
        wr_data_valid <= 1'b0;
    end else begin
        if (!s_axi_wready && s_axi_wvalid && s_axi_awvalid && !wr_data_valid) begin
            s_axi_wready  <= 1'b1;
            wr_data_valid <= 1'b1;
        end else if (s_axi_bvalid && s_axi_bready) begin
            wr_data_valid <= 1'b0;
            s_axi_wready  <= 1'b0;
        end else begin
            s_axi_wready  <= 1'b0;
        end
    end
end

// ============================================================================
// Write Response Channel and Register Write Logic
// ============================================================================
always @(posedge clk_axi or negedge rst_n) begin
    if (!rst_n) begin
        s_axi_bvalid    <= 1'b0;
        s_axi_bresp     <= RESP_OKAY;
        err_clear_strobe <= 1'b0;

        // Default configuration register values
        cfg_ctrl         <= 32'h0;
        cfg_ch_enable    <= 8'h0;
        cfg_edge_config  <= 8'h0;
        cfg_cal_ctrl     <= 32'h0;
        cfg_coinc_group[0]  <= 32'h0;
        cfg_coinc_group[1]  <= 32'h0;
        cfg_coinc_group[2]  <= 32'h0;
        cfg_coinc_group[3]  <= 32'h0;
        cfg_coinc_window[0] <= 32'h0;
        cfg_coinc_window[1] <= 32'h0;
        cfg_coinc_window[2] <= 32'h0;
        cfg_coinc_window[3] <= 32'h0;
        cfg_dma_ctrl     <= 32'h0;
        cfg_dead_time    <= 32'h0000_0002; // Default 4 ns = 2 cycles at 500 MHz
    end else begin
        // Default: clear strobe
        err_clear_strobe <= 1'b0;

        if (wr_addr_valid && wr_data_valid && !s_axi_bvalid) begin
            // Write transaction complete - generate response
            s_axi_bvalid <= 1'b1;

            if (is_read_only(wr_addr)) begin
                // Write to read-only register: respond with SLVERR
                s_axi_bresp <= RESP_SLVERR;
            end else begin
                // Valid write: apply configuration immediately (within same cycle)
                s_axi_bresp <= RESP_OKAY;
                write_register(wr_addr, s_axi_wdata, s_axi_wstrb);
            end
        end else if (s_axi_bvalid && s_axi_bready) begin
            // Response accepted by master
            s_axi_bvalid <= 1'b0;
            s_axi_bresp  <= RESP_OKAY;
        end
    end
end

// ============================================================================
// Register Write Task (byte-enable aware)
// ============================================================================
task write_register;
    input [11:0] addr;
    input [31:0] wdata;
    input [3:0]  wstrb;
    reg   [31:0] masked_data;
    reg   [1:0]  group_idx;
    begin
        // Apply byte strobes
        masked_data = wdata;

        case (addr)
            ADDR_CTRL: begin
                if (wstrb[0]) cfg_ctrl[7:0]   <= wdata[7:0];
                if (wstrb[1]) cfg_ctrl[15:8]  <= wdata[15:8];
                if (wstrb[2]) cfg_ctrl[23:16] <= wdata[23:16];
                if (wstrb[3]) cfg_ctrl[31:24] <= wdata[31:24];
            end

            ADDR_STATUS: begin
                // Write to STATUS clears all error flags and resets error counters
                err_clear_strobe <= 1'b1;
            end

            ADDR_CH_ENABLE: begin
                if (wstrb[0]) cfg_ch_enable <= wdata[7:0];
            end

            ADDR_EDGE_CONFIG: begin
                if (wstrb[0]) cfg_edge_config <= wdata[7:0];
            end

            ADDR_CAL_CTRL: begin
                if (wstrb[0]) cfg_cal_ctrl[7:0]   <= wdata[7:0];
                if (wstrb[1]) cfg_cal_ctrl[15:8]  <= wdata[15:8];
                if (wstrb[2]) cfg_cal_ctrl[23:16] <= wdata[23:16];
                if (wstrb[3]) cfg_cal_ctrl[31:24] <= wdata[31:24];
            end

            ADDR_DMA_CTRL: begin
                if (wstrb[0]) cfg_dma_ctrl[7:0]   <= wdata[7:0];
                if (wstrb[1]) cfg_dma_ctrl[15:8]  <= wdata[15:8];
                if (wstrb[2]) cfg_dma_ctrl[23:16] <= wdata[23:16];
                if (wstrb[3]) cfg_dma_ctrl[31:24] <= wdata[31:24];
            end

            ADDR_DEAD_TIME: begin
                if (wstrb[0]) cfg_dead_time[7:0]   <= wdata[7:0];
                if (wstrb[1]) cfg_dead_time[15:8]  <= wdata[15:8];
                if (wstrb[2]) cfg_dead_time[23:16] <= wdata[23:16];
                if (wstrb[3]) cfg_dead_time[31:24] <= wdata[31:24];
            end

            default: begin
                // Check coincidence group registers (0x020-0x02C)
                if (addr >= ADDR_COINC_GROUP_BASE && addr <= ADDR_COINC_GROUP_END) begin
                    group_idx = (addr - ADDR_COINC_GROUP_BASE) >> 2;
                    if (wstrb[0]) cfg_coinc_group[group_idx][7:0]   <= wdata[7:0];
                    if (wstrb[1]) cfg_coinc_group[group_idx][15:8]  <= wdata[15:8];
                    if (wstrb[2]) cfg_coinc_group[group_idx][23:16] <= wdata[23:16];
                    if (wstrb[3]) cfg_coinc_group[group_idx][31:24] <= wdata[31:24];
                end
                // Check coincidence window registers (0x040-0x04C)
                else if (addr >= ADDR_COINC_WINDOW_BASE && addr <= ADDR_COINC_WINDOW_END) begin
                    group_idx = (addr - ADDR_COINC_WINDOW_BASE) >> 2;
                    if (wstrb[0]) cfg_coinc_window[group_idx][7:0]   <= wdata[7:0];
                    if (wstrb[1]) cfg_coinc_window[group_idx][15:8]  <= wdata[15:8];
                    if (wstrb[2]) cfg_coinc_window[group_idx][23:16] <= wdata[23:16];
                    if (wstrb[3]) cfg_coinc_window[group_idx][31:24] <= wdata[31:24];
                end
            end
        endcase
    end
endtask

// ============================================================================
// Read Address Channel Handling
// ============================================================================
always @(posedge clk_axi or negedge rst_n) begin
    if (!rst_n) begin
        s_axi_arready <= 1'b0;
        rd_addr       <= 12'h0;
    end else begin
        if (!s_axi_arready && s_axi_arvalid && !s_axi_rvalid) begin
            s_axi_arready <= 1'b1;
            rd_addr       <= s_axi_araddr;
        end else begin
            s_axi_arready <= 1'b0;
        end
    end
end

// ============================================================================
// Read Data Channel and Register Read Logic
// ============================================================================
always @(posedge clk_axi or negedge rst_n) begin
    if (!rst_n) begin
        s_axi_rvalid <= 1'b0;
        s_axi_rdata  <= 32'h0;
        s_axi_rresp  <= RESP_OKAY;
        fifo_rd_en   <= 1'b0;
    end else begin
        // Default: clear FIFO read strobe
        fifo_rd_en <= 1'b0;

        if (s_axi_arready && s_axi_arvalid && !s_axi_rvalid) begin
            // Read transaction: latch data
            s_axi_rvalid <= 1'b1;
            s_axi_rresp  <= RESP_OKAY;
            s_axi_rdata  <= read_register(rd_addr);

            // Generate FIFO read strobe for FIFO_DATA access
            if (rd_addr >= ADDR_FIFO_DATA_BASE && rd_addr <= ADDR_FIFO_DATA_END) begin
                fifo_rd_en <= 1'b1;
            end
        end else if (s_axi_rvalid && s_axi_rready) begin
            // Read data accepted by master
            s_axi_rvalid <= 1'b0;
        end
    end
end

// ============================================================================
// Register Read Function
// ============================================================================
function [31:0] read_register;
    input [11:0] addr;
    reg [1:0] idx;
    reg [2:0] ch_idx;
    begin
        read_register = 32'h0; // Default: return zero for unmapped addresses

        case (addr)
            ADDR_CTRL:        read_register = cfg_ctrl;
            ADDR_STATUS:      read_register = sts_status;
            ADDR_CH_ENABLE:   read_register = {24'h0, cfg_ch_enable};
            ADDR_EDGE_CONFIG: read_register = {24'h0, cfg_edge_config};
            ADDR_CLK_STATUS:  read_register = sts_clk_status;
            ADDR_CAL_CTRL:    read_register = cfg_cal_ctrl;
            ADDR_CAL_STATUS:  read_register = sts_cal_status;
            ADDR_TEMP:        read_register = sts_temp;
            ADDR_FIFO_STATUS: read_register = sts_fifo_status;
            ADDR_DMA_CTRL:    read_register = cfg_dma_ctrl;
            ADDR_DMA_STATUS:  read_register = sts_dma_status;
            ADDR_DEAD_TIME:   read_register = cfg_dead_time;
            ADDR_RATE_OVF:    read_register = sts_rate_ovf;
            default: begin
                // Coincidence group registers (0x020-0x02C)
                if (addr >= ADDR_COINC_GROUP_BASE && addr <= ADDR_COINC_GROUP_END) begin
                    idx = (addr - ADDR_COINC_GROUP_BASE) >> 2;
                    read_register = cfg_coinc_group[idx];
                end
                // Coincidence window registers (0x040-0x04C)
                else if (addr >= ADDR_COINC_WINDOW_BASE && addr <= ADDR_COINC_WINDOW_END) begin
                    idx = (addr - ADDR_COINC_WINDOW_BASE) >> 2;
                    read_register = cfg_coinc_window[idx];
                end
                // Per-channel status (0x060-0x07C)
                else if (addr >= ADDR_CH_STATUS_BASE && addr <= ADDR_CH_STATUS_END) begin
                    ch_idx = (addr - ADDR_CH_STATUS_BASE) >> 2;
                    read_register = sts_ch_status[ch_idx];
                end
                // Per-channel tag rate (0x080-0x09C)
                else if (addr >= ADDR_TAG_RATE_BASE && addr <= ADDR_TAG_RATE_END) begin
                    ch_idx = (addr - ADDR_TAG_RATE_BASE) >> 2;
                    read_register = sts_tag_rate[ch_idx];
                end
                // Per-channel error counters (0x0A0-0x0BC)
                else if (addr >= ADDR_ERR_COUNT_BASE && addr <= ADDR_ERR_COUNT_END) begin
                    ch_idx = (addr - ADDR_ERR_COUNT_BASE) >> 2;
                    read_register = sts_err_count[ch_idx];
                end
                // FIFO data read port (0x100-0x1FF)
                else if (addr >= ADDR_FIFO_DATA_BASE && addr <= ADDR_FIFO_DATA_END) begin
                    read_register = sts_fifo_data;
                end
                // Unmapped: return 0
                else begin
                    read_register = 32'h0;
                end
            end
        endcase
    end
endfunction

endmodule
