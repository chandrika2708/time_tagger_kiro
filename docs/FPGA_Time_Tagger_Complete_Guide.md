# FPGA Time Tagger — Complete Working Principle & Code Guide

**Repository:** https://github.com/chandrika2708/time_tagger_kiro  
**Target:** Xilinx UltraScale+ (Zynq MPSoC)  
**Tool:** PetaLinux + Vivado 2022.2+

---

## Table of Contents

1. [System Working Principle](#1-system-working-principle)
2. [RTL Module Code Descriptions](#2-rtl-module-code-descriptions)
3. [Verification Suite](#3-verification-suite)
4. [FPGA Board Testing Guide (PetaLinux)](#4-fpga-board-testing-guide-petalinux)
5. [Python Host Interface](#5-python-host-interface)
6. [Quick Reference](#6-quick-reference)

---

## 1. System Working Principle

### 1.1 What is a Time Tagger?

A Time Tagger is a precision instrument that records the exact time when electrical events (pulses) arrive at its input channels. It is used in:
- Quantum optics (photon correlation, HBT experiments)
- LIDAR (time-of-flight measurement)
- Fluorescence lifetime imaging (FLIM)
- Nuclear/particle physics (coincidence counting)

### 1.2 How This Design Works

The system timestamps events with ~10 picosecond resolution using a **tapped delay line** technique:

```
                    ┌─── 2 ns (one 500 MHz clock period) ───┐
                    │                                         │
Clock Edge ─────────┤                                         ├─── Next Clock Edge
                    │    ◄── Event arrives somewhere here ──► │
                    │                                         │
                    │  Tap 0  Tap 1  Tap 2 ... Tap 255       │
                    │   ▼      ▼      ▼          ▼           │
                    │  [1]    [1]    [1]   ...  [0]          │
                    │         Thermometer Code                │
                    └─────────────────────────────────────────┘
```

**Step-by-step operation:**

1. **Event arrives** at an input channel (electrical pulse on FPGA pin)
2. **CARRY8 delay chain** propagates the event through 256 taps (each ~8 ps delay)
3. **Clock edge samples** all 256 taps simultaneously → thermometer code
4. **Bubble correction** fixes single-bit glitches in the thermometer code
5. **Priority encoder** converts thermometer code to binary (0–255) = fine timestamp
6. **Coarse counter** (48-bit, incrementing at 500 MHz) provides the integer clock count
7. **Tag formatter** combines: `{coarse[47:0], fine[15:0], channel_id[7:0], flags[7:0], reserved[15:0]}`
8. **Calibration LUT** corrects for non-uniform tap delays (DNL correction)
9. **Tag FIFO** buffers the 96-bit tag record (async: 500 MHz write → 250 MHz read)
10. **Tag Mux** arbitrates 9 sources (8 channels + coincidence) in round-robin
11. **DMA Engine** bursts tags to DDR memory via AXI4
12. **Linux reads DDR** and Python parses the binary tag records

### 1.3 Timing Resolution

- **Coarse resolution:** 2 ns (500 MHz clock period)
- **Fine resolution:** 2 ns / 256 taps ≈ 7.8 ps per tap
- **After calibration:** ~10 ps RMS jitter

### 1.4 Data Format

Each tag is a 96-bit record (stored as 128 bits in DMA with 32-bit zero padding):

```
Bit Position:  [95:48]        [47:32]      [31:24]     [23:16]    [15:0]
Field:         Coarse(48b)    Fine(16b)    Channel(8b)  Flags(8b)  Reserved(16b)
```

**Flags byte:**
- Bit 7: Overflow (coarse counter wrapped)
- Bit 0: Edge polarity (1=rising, 0=falling)

**Special tags:**
- Channel ID = 0xFF → Coincidence tag
- Reserved field = channel bitmask (which channels participated)

---

## 2. RTL Module Code Descriptions

### 2.1 `time_tagger_pkg.v` — Shared Parameters

Defines global constants used across all modules:
- `NUM_CHANNELS = 8`
- `NUM_TAPS = 256`
- `TAG_WIDTH = 96`
- `COARSE_BITS = 48`
- `FINE_BITS = 16`
- `FIFO_DEPTH = 16384`

### 2.2 `fine_interpolator.v` — Delay Line TDC Core

**Code structure:**
```verilog
// 1. CARRY8 chain instantiation (32 primitives × 8 taps = 256 taps)
generate
    for (i = 0; i < 32; i = i + 1) begin
        CARRY8 carry_inst (.CI(chain[i]), .CO(chain[i+1]), ...);
    end
endgenerate

// 2. Sampling registers (capture tap outputs on clock edge)
always @(posedge clk) tap_samples <= carry_outputs;

// 3. Bubble correction (fix isolated 0s in thermometer code)
// If tap[n]=0 but tap[n-1]=1 and tap[n+1]=1, set tap[n]=1

// 4. Thermometer-to-binary encoder (priority encoder)
// fine_bin = index of highest set bit
```

### 2.3 `tdc_channel.v` — Complete Channel

**Code structure:**
```verilog
// Edge detector (rising + optional falling)
wire rising_edge  = event_in & ~event_in_d;
wire falling_edge = ~event_in & event_in_d;

// Dead time enforcement (suppress events < 4 ns apart)
if (cycle_count - last_event_cycle < DEAD_TIME) suppress = 1;

// Coarse counter (48-bit, resets on sync_reset)
always @(posedge clk_coarse)
    if (sync_reset) coarse_counter <= 0;
    else coarse_counter <= coarse_counter + 1;

// Tag assembly
tag_record = {coarse_counter, cal_lut[fine_bin], channel_id, flags, 16'b0};
```

### 2.4 `tag_fifo.v` — Asynchronous FIFO

**Code structure:**
```verilog
// Dual-port RAM
reg [WIDTH-1:0] mem [0:DEPTH-1];

// Gray-code write pointer (write clock domain)
wire [ADDR_W:0] wr_ptr_gray = wr_ptr ^ (wr_ptr >> 1);

// Gray-code read pointer (read clock domain)
wire [ADDR_W:0] rd_ptr_gray = rd_ptr ^ (rd_ptr >> 1);

// CDC: synchronize pointers across domains (2-stage FF)
always @(posedge rd_clk) begin
    wr_ptr_gray_sync1 <= wr_ptr_gray;
    wr_ptr_gray_sync2 <= wr_ptr_gray_sync1;
end

// Full/empty/occupancy logic using synchronized gray pointers
```

### 2.5 `tag_mux.v` — Round-Robin Arbiter

**Code structure:**
```verilog
// Round-robin scan starting from last_granted + 1
always @(*) begin
    next_grant = last_granted;
    for (i = 0; i < NUM_SOURCES; i = i + 1) begin
        idx = (last_granted + 1 + i) % NUM_SOURCES;
        if (!fifo_empty[idx]) begin
            next_grant = idx;
            break;
        end
    end
end

// Backpressure: hold output when tag_ready is low
if (tag_ready && tag_valid) last_granted <= current_grant;
```

### 2.6 `coincidence_detector.v` — Window Comparator

**Code structure:**
```verilog
// For each group, compare timestamps of participating channels
// If |timestamp_A - timestamp_B| < window, coincidence detected
for (group = 0; group < NUM_GROUPS; group = group + 1) begin
    if (group_enable[group] && channel_mask[group]) begin
        if (ts_diff < window[group] && ts_diff >= 10)
            coinc_detected[group] = 1;
    end
end

// Priority: group 0 > group 1 > group 2 > group 3
// Output coincidence tag with channel_id=0xFF
```

### 2.7 `calibration_module.v` — Auto-Calibration

**Code structure (FSM):**
```
ST_IDLE → ST_ACCUMULATE → ST_COMPUTE → ST_CHECK_DNL → ST_UPDATE_LUT / ST_FAIL
```

- **ST_ACCUMULATE:** Counts fine_bin values into histogram (2.56M samples)
- **ST_COMPUTE:** Calculates ideal count per bin, derives correction
- **ST_CHECK_DNL:** Verifies histogram uniformity (fail if too skewed)
- **ST_UPDATE_LUT:** Atomically writes new LUT to all channels

### 2.8 `axi_register_file.v` — Configuration Interface

Standard AXI4-Lite slave with:
- Read-write registers (CTRL, CH_ENABLE, DMA_CTRL, etc.)
- Read-only registers (STATUS, CLK_STATUS) — writes return SLVERR
- Special behavior: write to STATUS triggers `err_clear_strobe`
- Special behavior: read from FIFO_DATA triggers `fifo_rd_en`

### 2.9 `axi_dma_engine.v` — Burst DMA

**FSM:**
```
ST_IDLE → ST_COLLECT → ST_ADDR → ST_DATA → ST_RESP → ST_IDLE
```

- Collects tags until burst_len reached or timeout expires
- Issues AXI4 INCR burst write (awsize=4 for 16-byte beats)
- Circular buffer: wraps address at base + size
- Reports errors on non-OKAY bresp

### 2.10 `rate_monitor.v` — Health Monitoring

- Per-channel 16-bit rate counter (1 ms window)
- Aggregate overflow detection (>80 Mtags/s for >1 µs)
- Per-channel error counter (saturates at 32'hFFFFFFFF)
- Channel status FSM: 00=OK, 01=disabled, 10=overflow, 11=error

### 2.11 `clock_manager.v` — Clock Generation

Uses MMCME4_ADV + BUFGMUX_CTRL to generate:
- 500 MHz from 100 MHz board clock (×5)
- 250 MHz (÷2 of 500 MHz)
- 100 MHz (passthrough)

State machine handles external reference switching and failover.

---

## 3. Verification Suite

All 11 testbenches in `tb/` are self-checking and run with Icarus Verilog:

```bash
# Example: run fine interpolator testbench
wsl bash -c "cd /mnt/d/time_tagger_kiro && \
  iverilog -g2012 -I rtl -o sim/tb_fine_interpolator.vvp \
  sim/xilinx_stubs.v rtl/time_tagger_pkg.v rtl/fine_interpolator.v \
  tb/tb_fine_interpolator.v && vvp sim/tb_fine_interpolator.vvp"
```

Each testbench outputs `[PASS]`/`[FAIL]` per check and exits with code 0 (all pass) or 1 (failures).

---

## 4. FPGA Board Testing Guide (PetaLinux)

### 4.1 Hardware Requirements

- Xilinx Zynq UltraScale+ board (ZCU102, ZCU104, or similar)
- Vivado 2022.2+
- PetaLinux 2022.2+
- SD card (16 GB+)
- Ethernet cable or USB cable for data transfer
- Signal source (pulse generator or photon detector) for event inputs

### 4.2 Step-by-Step Build Process

#### Step 1: Create Vivado Project

```tcl
# create_project.tcl
create_project time_tagger ./vivado_project -part xczu9eg-ffvb1156-2-e
add_files [glob rtl/*.v]
add_files -fileset constrs_1 constraints/time_tagger.xdc
set_property top time_tagger_top [current_fileset]
```

#### Step 2: Create Block Design

In Vivado GUI:
1. Create Block Design → Add Zynq UltraScale+ MPSoC
2. Run Block Automation (configure PS)
3. Add `time_tagger_top` as RTL module
4. Connect:
   - PS M_AXI_HPM0_FPD → `s_axi_*` (register access)
   - `m_axi_*` → PS S_AXI_HP0_FPD (DMA to DDR)
5. Address Editor:
   - Register file: `0xA000_0000` (64 KB)
   - DMA HP port: `0x0000_0000` – `0x7FFF_FFFF` (full DDR range)

#### Step 3: Generate Bitstream

```bash
vivado -mode batch -source build.tcl
# Export XSA: File → Export → Export Hardware (include bitstream)
```

#### Step 4: Build PetaLinux

```bash
# Create project
petalinux-create -t project --template zynqMP -n time_tagger_linux
cd time_tagger_linux

# Import hardware
petalinux-config --get-hw-description=/path/to/time_tagger_top.xsa

# In menuconfig:
# - Set boot device (SD card)
# - Set root filesystem (SD card ext4)

# Configure kernel for UIO
petalinux-config -c kernel
# → Device Drivers → Userspace I/O → Enable "Userspace I/O platform driver"

# Configure rootfs for Python
petalinux-config -c rootfs
# → Filesystem Packages → misc → python3 (enable)
# → Filesystem Packages → misc → python3-numpy (enable)

# Add device tree for UIO and reserved memory
# Edit: project-spec/meta-user/recipes-bsp/device-tree/files/system-user.dtsi
```

**system-user.dtsi:**
```dts
/include/ "system-conf.dtsi"
/ {
    reserved-memory {
        #address-cells = <2>;
        #size-cells = <2>;
        ranges;
        dma_buf: buffer@10000000 {
            compatible = "shared-dma-pool";
            reg = <0x0 0x10000000 0x0 0x1000000>;
            no-map;
        };
    };
};

&amba {
    time_tagger@a0000000 {
        compatible = "generic-uio";
        reg = <0x0 0xa0000000 0x0 0x10000>;
    };
};
```

```bash
# Build everything
petalinux-build

# Package boot files
petalinux-package --boot \
    --fsbl images/linux/zynqmp_fsbl.elf \
    --fpga images/linux/system.bit \
    --pmufw images/linux/pmufw.elf \
    --u-boot
```

#### Step 5: Flash SD Card

```bash
# Partition SD card:
# - Partition 1: FAT32, 512 MB (boot)
# - Partition 2: ext4, remaining (rootfs)

# Copy boot files
cp images/linux/BOOT.BIN /media/BOOT/
cp images/linux/image.ub /media/BOOT/
cp images/linux/boot.scr /media/BOOT/

# Extract rootfs
sudo tar xf images/linux/rootfs.tar.gz -C /media/rootfs/

# Copy Python script
cp /path/to/python/time_tagger_host.py /media/rootfs/home/root/
```

#### Step 6: Boot and Test

```bash
# Set board boot mode to SD card
# Power on, connect serial console (115200 baud)

# After Linux boots, login as root
# Verify UIO device
ls /dev/uio0

# Run the time tagger
python3 /home/root/time_tagger_host.py --mode local --uio
```

### 4.3 Connecting Event Sources

Connect your signal source to the FPGA pins mapped to `event_in[7:0]` in the XDC constraints file. Typical connections:
- **Single-photon detectors:** TTL/LVTTL output → FPGA LVCMOS input
- **Pulse generator:** 50Ω terminated, 3.3V logic levels
- **Ensure proper termination** to avoid reflections at high frequencies

---

## 5. Python Host Interface

### 5.1 On the FPGA Board (Server Mode)

```bash
# Ethernet mode — serves timestamps over TCP
python3 time_tagger_host.py --mode ethernet --port 5555 --uio

# USB mode — sends timestamps over USB serial
python3 time_tagger_host.py --mode usb --device /dev/ttyGS0 --uio

# Local mode — prints timestamps to console
python3 time_tagger_host.py --mode local --uio --duration 5
```

### 5.2 On Your Host PC (Client Mode)

```bash
# Receive via Ethernet (connect to FPGA's IP address)
python3 time_tagger_host.py --mode client --host 192.168.1.100 --port 5555 --duration 10

# Receive via USB serial
python3 time_tagger_host.py --mode client --device /dev/ttyACM0 --duration 10

# Save to file for offline analysis
python3 time_tagger_host.py --mode client --host 192.168.1.100 --output data.bin
```

### 5.3 Data Analysis Example

```python
import struct
import numpy as np

# Read saved binary data
with open('data.bin', 'rb') as f:
    raw = f.read()

# Parse 10-byte records: timestamp_ps(8B) + channel(1B) + flags(1B)
n_tags = len(raw) // 10
timestamps = np.zeros(n_tags, dtype=np.uint64)
channels = np.zeros(n_tags, dtype=np.uint8)

for i in range(n_tags):
    ts, ch, flags = struct.unpack_from('<QBB', raw, i * 10)
    timestamps[i] = ts
    channels[i] = ch

# Compute time differences between consecutive events on channel 0
ch0_mask = channels == 0
ch0_times = timestamps[ch0_mask]
dt = np.diff(ch0_times)  # Inter-arrival times in picoseconds

print(f"Channel 0: {len(ch0_times)} events")
print(f"Mean interval: {dt.mean()/1000:.2f} ns")
print(f"Std deviation: {dt.std()/1000:.2f} ns")

# Histogram of time differences (for g(2) correlation)
import matplotlib.pyplot as plt
plt.hist(dt / 1000, bins=100, range=(0, 100))
plt.xlabel('Time difference (ns)')
plt.ylabel('Counts')
plt.title('Inter-arrival time histogram')
plt.savefig('histogram.png')
```

### 5.4 USB Gadget Setup (for USB serial mode)

On the FPGA board, configure USB gadget:
```bash
# Load USB gadget modules
modprobe libcomposite
modprobe usb_f_acm

# Create gadget
mkdir -p /sys/kernel/config/usb_gadget/tagger
cd /sys/kernel/config/usb_gadget/tagger
echo 0x1d6b > idVendor
echo 0x0104 > idProduct
mkdir -p strings/0x409
echo "TimeTagger" > strings/0x409/product
mkdir -p configs/c.1
mkdir -p functions/acm.usb0
ln -s functions/acm.usb0 configs/c.1/
echo "fe200000.dwc3" > UDC

# Now /dev/ttyGS0 is available for the Python script
```

---

## 6. Quick Reference

### 6.1 Register Map Summary

| Offset | Name | R/W | Purpose |
|--------|------|-----|---------|
| 0x000 | CTRL | RW | Bit 0: global enable, Bit 1: sync |
| 0x004 | STATUS | RW | Write clears errors |
| 0x008 | CH_ENABLE | RW | Channel enable mask [7:0] |
| 0x00C | EDGE_CONFIG | RW | Falling edge enable [7:0] |
| 0x204 | DMA_CTRL | RW | Bit 0: DMA enable, [15:8]: burst_len-1 |

### 6.2 Compile Commands (Simulation)

```bash
# All testbenches (run in WSL)
for tb in fine_interpolator tdc_channel tag_fifo tag_mux \
          coincidence_detector calibration_module axi_register_file \
          axi_dma_engine rate_monitor clock_manager time_tagger_top; do
    iverilog -g2012 -I rtl -o sim/tb_${tb}.vvp \
        sim/xilinx_stubs.v rtl/time_tagger_pkg.v rtl/*.v tb/tb_${tb}.v
    vvp sim/tb_${tb}.vvp
done
```

### 6.3 Network Diagram

```
┌──────────────┐     Ethernet      ┌──────────────────┐
│   Host PC    │◄──────────────────►│  FPGA Board      │
│              │    TCP:5555        │  (Zynq MPSoC)    │
│  Python      │                    │                  │
│  client.py   │     OR USB        │  Python server   │
│              │◄──────────────────►│  time_tagger_    │
│              │   /dev/ttyACM0     │  host.py         │
└──────────────┘                    └──────────────────┘
```

---

## Converting This Document to PDF

```bash
# Using pandoc (install: apt install pandoc texlive-latex-recommended)
pandoc docs/FPGA_Time_Tagger_Complete_Guide.md -o FPGA_Time_Tagger_Guide.pdf \
    --pdf-engine=xelatex -V geometry:margin=1in

# Or using VS Code: install "Markdown PDF" extension, right-click → Export PDF
```

---

*Document generated for the time_tagger_kiro project.*  
*Repository: https://github.com/chandrika2708/time_tagger_kiro*
