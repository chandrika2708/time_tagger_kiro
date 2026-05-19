# FPGA Time Tagger — Complete Documentation

## 1. System Overview

### 1.1 Purpose

The FPGA Time Tagger is a multi-channel Time-to-Digital Converter (TDC) that timestamps input events with ~10 picosecond resolution. It is designed for quantum optics experiments, LIDAR, fluorescence lifetime imaging, and any application requiring precise event timing across multiple channels.

### 1.2 Key Specifications

| Parameter | Value |
|-----------|-------|
| Number of channels | 8 |
| Timing resolution | ~10 ps (CARRY8 tap spacing) |
| Coarse counter width | 48 bits |
| Fine interpolator taps | 256 (NUM_TAPS) |
| Tag record width | 96 bits |
| FIFO depth per channel | 16,384 entries |
| Max tag rate | 80 Mtags/s aggregate |
| DMA burst size | Up to 256 beats |
| AXI data width | 128 bits (DMA), 32 bits (registers) |
| Clock domains | 500 MHz (coarse), 250 MHz (AXI/DMA), 100 MHz (cal) |

### 1.3 System Block Diagram

```
                    ┌─────────────────────────────────────────────────────────┐
                    │                   time_tagger_top                        │
                    │                                                          │
  clk_board ───────►│  ┌──────────────┐                                       │
  clk_ext_10mhz ──►│  │ Clock Manager │──► clk_coarse (500 MHz)              │
  ext_clk_valid ───►│  │              │──► clk_axi (250 MHz)                  │
                    │  │              │──► clk_dma (250 MHz)                   │
                    │  │              │──► clk_cal (100 MHz)                   │
                    │  └──────────────┘                                       │
                    │                                                          │
  event_in[7:0] ───►│  ┌────────────┐    ┌──────────┐    ┌─────────┐         │
                    │  │ TDC Channel │───►│ Tag FIFO │───►│         │         │
                    │  │    (×8)     │    │   (×8)   │    │ Tag Mux │         │
                    │  └────────────┘    └──────────┘    │  (9-in) │         │
                    │        │                            │         │         │
                    │        ▼                            │         │         │
                    │  ┌────────────┐                     │         │         │
                    │  │ Coincidence│────► FIFO ─────────►│         │         │
                    │  │ Detector   │                     └────┬────┘         │
                    │  └────────────┘                          │              │
                    │                                          ▼              │
                    │  ┌────────────┐                    ┌───────────┐        │──► m_axi_*
                    │  │Calibration │                    │ DMA Engine│────────│    (AXI4 Master)
                    │  │  Module    │                    └───────────┘        │
                    │  └────────────┘                                         │
                    │                                                          │
                    │  ┌────────────┐    ┌──────────────┐                     │
  s_axi_* ────────►│  │ Rate       │◄───│ AXI Register │◄───────────────────│
  (AXI4-Lite)      │  │ Monitor    │    │    File      │                     │
                    │  └────────────┘    └──────────────┘                     │
                    └─────────────────────────────────────────────────────────┘
```

---

## 2. Module Descriptions

### 2.1 Fine Interpolator (`fine_interpolator.v`)

**Purpose:** Measures the fractional clock period between an event edge and the next clock edge using a CARRY8 tapped delay line.

**Working Principle:**
1. The input event propagates through a chain of 256 CARRY8 elements (32 CARRY8 primitives × 8 taps each)
2. At the clock edge, all tap outputs are sampled into registers → produces a thermometer code
3. Bubble correction fixes single-bit errors (isolated 0s within a run of 1s)
4. A priority encoder converts the corrected thermometer code to a binary fine_bin value (0–255)
5. Pipeline latency: 3 clock cycles

**Key Signals:**
- `event_in` → input event pulse
- `therm_code[255:0]` → raw thermometer code (debug)
- `fine_bin[7:0]` → binary fine timestamp (0 to NUM_TAPS-1)

### 2.2 TDC Channel (`tdc_channel.v`)

**Purpose:** Complete single-channel TDC combining edge detection, coarse counting, fine interpolation, dead time enforcement, and tag formatting.

**Working Principle:**
1. Edge detector identifies rising (and optionally falling) edges on `event_in`
2. Coarse counter (48-bit) increments every clock cycle at 500 MHz
3. Fine interpolator provides sub-clock resolution
4. Dead time logic suppresses events arriving within 4 ns (2 cycles) of the previous event
5. Calibration LUT corrects fine values for delay line non-linearity
6. Tag formatter assembles the 96-bit Tag_Record

**Tag_Record Format (96 bits):**
```
[95:32] = 64-bit timestamp (48-bit coarse [63:16] + 16-bit fine [15:0])
[31:24] = 8-bit channel ID
[23:16] = 8-bit flags (bit 7: overflow, bit 0: edge_polarity)
[15:0]  = 16-bit reserved (zero for normal tags)
```

### 2.3 Tag FIFO (`tag_fifo.v`)

**Purpose:** Asynchronous FIFO bridging the 500 MHz write domain (TDC) to the 250 MHz read domain (DMA).

**Working Principle:**
1. Dual-port RAM (16,384 × 96 bits) with independent read/write clocks
2. Gray-code encoded pointers for safe clock domain crossing
3. High-watermark flag at 75% occupancy (12,288 entries)
4. Circular buffer behavior on overflow (oldest data discarded)
5. Occupancy output accurate to ±1 entry (CDC latency)

### 2.4 Tag Multiplexer (`tag_mux.v`)

**Purpose:** Fair round-robin arbiter combining 9 tag sources (8 channels + 1 coincidence) into a single stream.

**Working Principle:**
1. Scans sources starting from the one after the last granted
2. Grants the first non-empty source found
3. Supports backpressure via `tag_ready` signal
4. Guarantees no data loss and per-source ordering preservation

### 2.5 Coincidence Detector (`coincidence_detector.v`)

**Purpose:** Detects temporal coincidences between events on different channels within configurable time windows.

**Working Principle:**
1. Monitors tag_valid signals from all channels
2. Compares timestamps of events within the same group
3. If timestamps differ by less than the configured window (10–1000 units of ~10 ps), generates a coincidence Tag_Record
4. Supports 4 independent groups with configurable channel masks
5. Group 0 has highest priority on simultaneous detections

**Coincidence Tag_Record:**
- `channel_id = 0xFF`
- `flags` = group ID
- `reserved` = participating channel bitmask

### 2.6 Calibration Module (`calibration_module.v`)

**Purpose:** Automatically calibrates the fine interpolator to correct for delay line non-linearity and temperature drift.

**Working Principle:**
1. Accumulates a histogram of fine_bin values using an internal LFSR-based stimulus
2. Computes DNL (Differential Non-Linearity) from the histogram
3. Generates a correction LUT that linearizes the fine timestamp
4. Atomic LUT update: all channels updated simultaneously
5. Temperature-triggered recalibration when ΔT > 5°C
6. Manual trigger available via `cal_trigger`
7. Old LUT remains active during recalibration (no timestamp gaps)

### 2.7 AXI Register File (`axi_register_file.v`)

**Purpose:** AXI4-Lite slave providing configuration and status registers.

**Register Map:**

| Address | Name | Access | Description |
|---------|------|--------|-------------|
| 0x000 | CTRL | RW | Global control (bit 0: enable) |
| 0x004 | STATUS | RW* | Status/error clear (write triggers err_clear_strobe) |
| 0x008 | CH_ENABLE | RW | Per-channel enable bitmask [7:0] |
| 0x00C | EDGE_CONFIG | RW | Per-channel falling-edge enable [7:0] |
| 0x010 | CLK_STATUS | RO | Clock lock/loss status |
| 0x014 | CAL_CTRL | RW | Calibration control |
| 0x020–0x02C | COINC_GROUPn | RW | Coincidence group config (×4) |
| 0x040–0x04C | COINC_WINDOWn | RW | Coincidence window (×4) |
| 0x100–0x1FF | FIFO_DATA | RO | FIFO read port |
| 0x200 | DMA_STATUS | RO | DMA status |
| 0x204 | DMA_CTRL | RW | DMA control |
| 0x300 | DEAD_TIME | RW | Dead time configuration |

### 2.8 AXI DMA Engine (`axi_dma_engine.v`)

**Purpose:** Transfers tag data from the mux to system memory via AXI4 burst writes.

**Working Principle:**
1. Collects tags from the mux into an internal buffer
2. When burst_len tags collected (or timeout expires), issues an AXI4 INCR burst write
3. Each 96-bit tag is zero-padded to 128 bits (one AXI beat)
4. Circular buffer addressing: wraps at `base_addr + buf_size`
5. Supports partial bursts on timeout (fewer tags than burst_len)

### 2.9 Rate Monitor (`rate_monitor.v`)

**Purpose:** Tracks per-channel tag rates, detects overflow conditions, and maintains error counters.

**Key Features:**
- Per-channel 16-bit rate counter (1 ms interval, saturates at 65535)
- Aggregate rate overflow detection (>80 Mtags/s sustained >1 µs)
- Per-channel 32-bit error counter (saturates at 0xFFFFFFFF)
- Channel status state machine: enabled/disabled/overflow/error

### 2.10 Clock Manager (`clock_manager.v`)

**Purpose:** Generates all internal clocks from the board oscillator with optional external reference switching.

**State Machine:**
```
IDLE → INTERNAL → EXT_LOCKING → EXT_LOCKED → FALLBACK → INTERNAL
```

**Clocks Generated:**
- `clk_coarse`: 500 MHz (TDC sampling)
- `clk_axi`: 250 MHz (AXI bus)
- `clk_dma`: 250 MHz (DMA engine)
- `clk_cal`: 100 MHz (calibration)

---

## 3. Testing on FPGA Board with PetaLinux

### 3.1 Prerequisites

- Xilinx UltraScale+ FPGA board (e.g., ZCU102, ZCU104, KCU116)
- Vivado 2022.2+ (for bitstream generation)
- PetaLinux 2022.2+ (for Linux image)
- USB or Ethernet connection to host PC

### 3.2 Vivado Project Setup

1. **Create Vivado project:**
```bash
vivado -mode batch -source create_project.tcl
```

2. **Add RTL sources:**
   - Add all files from `rtl/` directory
   - Set `time_tagger_top.v` as the top module
   - Add `constraints/time_tagger.xdc`

3. **Create Block Design:**
   - Add Zynq UltraScale+ MPSoC IP
   - Connect `time_tagger_top` as a custom IP:
     - `s_axi_*` → PS AXI4-Lite master (GP port)
     - `m_axi_*` → PS AXI4 slave (HP port) for DMA to DDR
   - Assign address ranges:
     - Register file: `0xA000_0000` (64 KB)
     - DMA buffer: `0x1000_0000` (16 MB in DDR)

4. **Generate bitstream:**
```bash
vivado -mode batch -source build_bitstream.tcl
```

5. **Export hardware (XSA):**
   - File → Export → Export Hardware (include bitstream)
   - Save as `time_tagger_top.xsa`

### 3.3 PetaLinux Build

```bash
# Create PetaLinux project
petalinux-create -t project --template zynqMP -n time_tagger_linux

cd time_tagger_linux

# Import hardware description
petalinux-config --get-hw-description=/path/to/time_tagger_top.xsa

# Configure kernel (enable UIO driver for register access)
petalinux-config -c kernel
# Enable: Device Drivers → Userspace I/O → Userspace I/O platform driver with generic IRQ handling

# Configure rootfs (add Python)
petalinux-config -c rootfs
# Enable: Filesystem Packages → misc → python3
# Enable: Filesystem Packages → misc → python3-numpy

# Add device tree overlay for UIO
# Edit: project-spec/meta-user/recipes-bsp/device-tree/files/system-user.dtsi
```

**Device Tree Entry (`system-user.dtsi`):**
```dts
/include/ "system-conf.dtsi"
/ {
    time_tagger@a0000000 {
        compatible = "generic-uio";
        reg = <0x0 0xa0000000 0x0 0x10000>;  /* Register file */
        interrupt-parent = <&gic>;
        interrupts = <0 89 4>;  /* Optional: DMA complete interrupt */
    };

    reserved-memory {
        #address-cells = <2>;
        #size-cells = <2>;
        ranges;

        dma_buffer: dma_buffer@10000000 {
            compatible = "shared-dma-pool";
            reg = <0x0 0x10000000 0x0 0x1000000>;  /* 16 MB */
            no-map;
        };
    };
};
```

```bash
# Build PetaLinux image
petalinux-build

# Package boot image
petalinux-package --boot --fsbl images/linux/zynqmp_fsbl.elf \
    --fpga images/linux/system.bit \
    --pmufw images/linux/pmufw.elf \
    --u-boot

# Flash to SD card
# Copy BOOT.BIN, image.ub, boot.scr to SD card boot partition
```

### 3.4 Boot and Verify

```bash
# On the FPGA board (via serial console or SSH):
# Check UIO device appeared
ls /dev/uio*
# Should show /dev/uio0

# Check memory mapping
cat /sys/class/uio/uio0/maps/map0/addr
# Should show 0xa0000000

cat /sys/class/uio/uio0/maps/map0/size
# Should show 0x10000
```

---

## 4. Python Host Interface

### 4.1 On-Board Python (via SSH/Serial)

The Python script runs directly on the Zynq PS (ARM core) and accesses the FPGA registers via memory-mapped I/O through `/dev/mem` or UIO.

### 4.2 Network Access (Ethernet)

For remote access from a host PC:
1. The Python script on the FPGA board runs a TCP server
2. The host PC connects and receives timestamp data in real-time
3. Alternatively, use SSH + the script directly

### 4.3 USB Access

For USB-based access:
1. Configure the Zynq USB as a CDC-ACM (virtual serial port)
2. The Python script on the FPGA sends data over the USB serial link
3. Host PC reads from the COM port / `/dev/ttyACM0`

---

## 5. Data Flow Summary

```
Physical Event → FPGA Pin → TDC Channel → 96-bit Tag_Record
    → Tag FIFO → Tag Mux → DMA Engine → DDR Memory (via AXI4)
    → Linux reads DDR buffer → Python parses Tag_Records
    → TCP/USB → Host PC
```

---

## 6. Tag_Record Binary Format (for parsing)

Each tag is 128 bits (16 bytes) in the DMA buffer (96-bit tag + 32-bit zero padding):

```
Byte offset:  0  1  2  3  4  5  6  7  8  9  10 11 12 13 14 15
              |-- reserved --| flags | ch_id |---- timestamp (64-bit) ----|  | padding |
              [15:0]          [23:16] [31:24] [95:32]                        [127:96]
```

**Python struct format:** `<QI4x` or parse as 16-byte records.

---

## 7. Performance Considerations

- **Maximum sustained rate:** 80 Mtags/s aggregate across all channels
- **DMA bandwidth:** 128 bits × 250 MHz = 4 GB/s (theoretical max)
- **Practical throughput:** Limited by DDR bandwidth and Linux overhead (~500 Mtags/s)
- **FIFO depth:** 16,384 entries per channel provides ~200 µs buffering at max rate
- **Calibration time:** ~25 ms per cycle (non-blocking, old LUT active during cal)
