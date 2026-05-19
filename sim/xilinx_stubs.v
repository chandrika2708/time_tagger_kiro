//-----------------------------------------------------------------------------
// xilinx_stubs.v
// Behavioral stubs for Xilinx UltraScale+ primitives (simulation only)
//-----------------------------------------------------------------------------
// These are simplified behavioral models for iverilog/verilator simulation.
// They do NOT model actual timing or analog behavior of the real primitives.
//-----------------------------------------------------------------------------

`timescale 1ns / 1ps

// ============================================================================
// CARRY8 - 8-bit carry chain primitive
// ============================================================================
module CARRY8 #(
    parameter CARRY_TYPE = "SINGLE_CY8"
)(
    output [7:0] CO,
    output [7:0] O,
    input        CI,
    input        CI_TOP,
    input  [7:0] DI,
    input  [7:0] S
);
    // Simplified behavioral model: carry propagation
    wire [8:0] carry;
    assign carry[0] = CI;
    
    genvar i;
    generate
        for (i = 0; i < 8; i = i + 1) begin : gen_carry
            assign carry[i+1] = S[i] ? (DI[i] ^ carry[i]) : DI[i];
            assign CO[i] = carry[i+1];
            assign O[i] = S[i] ^ carry[i];
        end
    endgenerate
endmodule

// ============================================================================
// BUFG - Global clock buffer
// ============================================================================
module BUFG (
    output O,
    input  I
);
    assign O = I;
endmodule

// ============================================================================
// BUFGMUX_CTRL - Glitch-free clock multiplexer
// ============================================================================
module BUFGMUX_CTRL (
    output O,
    input  I0,
    input  I1,
    input  S,
    input  CE
);
    assign O = S ? I1 : I0;
endmodule

// ============================================================================
// MMCME4_ADV - Mixed-Mode Clock Manager (behavioral stub)
// ============================================================================
module MMCME4_ADV #(
    parameter BANDWIDTH = "OPTIMIZED",
    parameter real CLKFBOUT_MULT_F = 5.0,
    parameter real CLKFBOUT_PHASE = 0.0,
    parameter real CLKIN1_PERIOD = 10.0,
    parameter real CLKIN2_PERIOD = 10.0,
    parameter real CLKOUT0_DIVIDE_F = 1.0,
    parameter real CLKOUT0_PHASE = 0.0,
    parameter real CLKOUT0_DUTY_CYCLE = 0.5,
    parameter integer CLKOUT1_DIVIDE = 1,
    parameter real CLKOUT1_PHASE = 0.0,
    parameter real CLKOUT1_DUTY_CYCLE = 0.5,
    parameter integer CLKOUT2_DIVIDE = 1,
    parameter real CLKOUT2_PHASE = 0.0,
    parameter real CLKOUT2_DUTY_CYCLE = 0.5,
    parameter integer CLKOUT3_DIVIDE = 1,
    parameter real CLKOUT3_PHASE = 0.0,
    parameter real CLKOUT3_DUTY_CYCLE = 0.5,
    parameter integer CLKOUT4_DIVIDE = 1,
    parameter integer CLKOUT5_DIVIDE = 1,
    parameter integer CLKOUT6_DIVIDE = 1,
    parameter integer DIVCLK_DIVIDE = 1,
    parameter real REF_JITTER1 = 0.01,
    parameter real REF_JITTER2 = 0.01,
    parameter STARTUP_WAIT = "FALSE",
    parameter SS_EN = "FALSE",
    parameter SS_MODE = "CENTER_HIGH",
    parameter integer SS_MOD_PERIOD = 10000,
    parameter COMPENSATION = "AUTO"
)(
    input  CLKIN1,
    input  CLKIN2,
    input  CLKINSEL,
    input  CLKFBIN,
    output CLKFBOUT,
    output CLKFBOUTB,
    output CLKOUT0,
    output CLKOUT0B,
    output CLKOUT1,
    output CLKOUT1B,
    output CLKOUT2,
    output CLKOUT2B,
    output CLKOUT3,
    output CLKOUT3B,
    output CLKOUT4,
    output CLKOUT5,
    output CLKOUT6,
    output LOCKED,
    output CLKINSTOPPED,
    output CLKFBSTOPPED,
    input  PWRDWN,
    input  RST,
    input  [6:0] DADDR,
    input  DCLK,
    input  DEN,
    input  [15:0] DI,
    output [15:0] DO,
    output DRDY,
    input  DWE,
    input  PSCLK,
    input  PSEN,
    input  PSINCDEC,
    output PSDONE,
    input  CDDCREQ,
    output CDDCDONE
);
    // Simplified: pass through clock and assert locked after reset
    reg locked_reg;
    
    assign CLKFBOUT = CLKIN1;
    assign CLKOUT0 = CLKIN1;
    assign CLKOUT1 = CLKIN1;
    assign CLKOUT2 = CLKIN1;
    assign CLKOUT3 = CLKIN1;
    assign CLKOUT4 = 1'b0;
    assign CLKOUT5 = 1'b0;
    assign CLKOUT6 = 1'b0;
    assign CLKFBOUTB = ~CLKIN1;
    assign CLKOUT0B = ~CLKIN1;
    assign CLKOUT1B = ~CLKIN1;
    assign CLKOUT2B = ~CLKIN1;
    assign CLKOUT3B = ~CLKIN1;
    assign LOCKED = locked_reg;
    assign CLKINSTOPPED = 1'b0;
    assign CLKFBSTOPPED = 1'b0;
    assign DO = 16'h0;
    assign DRDY = 1'b0;
    assign PSDONE = 1'b0;
    assign CDDCDONE = 1'b0;
    
    always @(posedge CLKIN1 or posedge RST) begin
        if (RST)
            locked_reg <= 1'b0;
        else
            locked_reg <= 1'b1;
    end
endmodule

// ============================================================================
// PLLE4_ADV - Phase-Locked Loop (behavioral stub)
// ============================================================================
module PLLE4_ADV #(
    parameter integer CLKFBOUT_MULT = 1,
    parameter real CLKIN_PERIOD = 10.0,
    parameter integer CLKOUT0_DIVIDE = 1,
    parameter real CLKOUT0_PHASE = 0.0,
    parameter integer DIVCLK_DIVIDE = 1,
    parameter STARTUP_WAIT = "FALSE"
)(
    input  CLKIN,
    input  CLKFBIN,
    output CLKFBOUT,
    output CLKOUT0,
    output CLKOUT1,
    output LOCKED,
    input  PWRDWN,
    input  RST,
    input  [6:0] DADDR,
    input  DCLK,
    input  DEN,
    input  [15:0] DI,
    output [15:0] DO,
    output DRDY,
    input  DWE,
    input  PSCLK,
    input  PSEN,
    input  PSINCDEC,
    output PSDONE
);
    reg locked_reg;
    
    assign CLKFBOUT = CLKIN;
    assign CLKOUT0 = CLKIN;
    assign CLKOUT1 = 1'b0;
    assign LOCKED = locked_reg;
    assign DO = 16'h0;
    assign DRDY = 1'b0;
    assign PSDONE = 1'b0;
    
    always @(posedge CLKIN or posedge RST) begin
        if (RST)
            locked_reg <= 1'b0;
        else
            locked_reg <= 1'b1;
    end
endmodule
