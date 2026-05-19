#!/usr/bin/env python3
"""Generate PDF documentation for FPGA Time Tagger project."""

from fpdf import FPDF
import re

class TimeTaggerPDF(FPDF):
    def __init__(self):
        super().__init__()
        self.set_auto_page_break(auto=True, margin=20)
        self.add_page()
        self.set_font('Helvetica', '', 11)

    def header(self):
        if self.page_no() > 1:
            self.set_font('Helvetica', 'I', 8)
            self.cell(0, 5, 'FPGA Time Tagger - Complete Documentation', align='C')
            self.ln(8)

    def footer(self):
        self.set_y(-15)
        self.set_font('Helvetica', 'I', 8)
        self.cell(0, 10, f'Page {self.page_no()}/{{nb}}', align='C')

    def title_page(self):
        self.ln(60)
        self.set_font('Helvetica', 'B', 28)
        self.cell(0, 15, 'FPGA Time Tagger', align='C', new_x="LMARGIN", new_y="NEXT")
        self.ln(5)
        self.set_font('Helvetica', '', 16)
        self.cell(0, 10, 'Complete Working Principle & Code Guide', align='C', new_x="LMARGIN", new_y="NEXT")
        self.ln(20)
        self.set_font('Helvetica', '', 12)
        self.cell(0, 8, 'Target: Xilinx UltraScale+ (Zynq MPSoC)', align='C', new_x="LMARGIN", new_y="NEXT")
        self.cell(0, 8, 'Tools: PetaLinux + Vivado 2022.2+', align='C', new_x="LMARGIN", new_y="NEXT")
        self.cell(0, 8, 'Repository: github.com/chandrika2708/time_tagger_kiro', align='C', new_x="LMARGIN", new_y="NEXT")
        self.ln(30)
        self.set_font('Helvetica', 'I', 10)
        self.cell(0, 8, 'Multi-channel Time-to-Digital Converter with ~10 ps resolution', align='C', new_x="LMARGIN", new_y="NEXT")
        self.cell(0, 8, '8 channels | CARRY8 delay line | AXI DMA | Python interface', align='C', new_x="LMARGIN", new_y="NEXT")

    def chapter_title(self, title):
        self.add_page()
        self.set_font('Helvetica', 'B', 18)
        self.set_fill_color(41, 128, 185)
        self.set_text_color(255, 255, 255)
        self.cell(0, 12, f'  {title}', fill=True, new_x="LMARGIN", new_y="NEXT")
        self.set_text_color(0, 0, 0)
        self.ln(5)

    def section_title(self, title):
        self.ln(3)
        self.set_font('Helvetica', 'B', 13)
        self.set_text_color(41, 128, 185)
        self.cell(0, 8, title, new_x="LMARGIN", new_y="NEXT")
        self.set_text_color(0, 0, 0)
        self.ln(2)

    def subsection_title(self, title):
        self.ln(2)
        self.set_font('Helvetica', 'B', 11)
        self.cell(0, 7, title, new_x="LMARGIN", new_y="NEXT")
        self.ln(1)

    def body_text(self, text):
        self.set_font('Helvetica', '', 10)
        self.multi_cell(0, 5, text)
        self.ln(2)

    def code_block(self, code):
        self.set_font('Courier', '', 8)
        self.set_fill_color(240, 240, 240)
        for line in code.split('\n'):
            if self.get_y() > 270:
                self.add_page()
            self.cell(0, 4, '  ' + line[:100], fill=True, new_x="LMARGIN", new_y="NEXT")
        self.ln(3)
        self.set_font('Helvetica', '', 10)

    def bullet(self, text):
        self.set_font('Helvetica', '', 10)
        self.cell(0, 5, '  - ' + text, new_x="LMARGIN", new_y="NEXT")

    def table_row(self, cols, widths, bold=False):
        self.set_font('Helvetica', 'B' if bold else '', 9)
        for i, col in enumerate(cols):
            self.cell(widths[i], 6, str(col)[:30], border=1)
        self.ln()

def generate_pdf():
    pdf = TimeTaggerPDF()
    pdf.alias_nb_pages()

    # Title Page
    pdf.title_page()

    # Table of Contents
    pdf.add_page()
    pdf.set_font('Helvetica', 'B', 16)
    pdf.cell(0, 10, 'Table of Contents', new_x="LMARGIN", new_y="NEXT")
    pdf.ln(5)
    pdf.set_font('Helvetica', '', 11)
    toc = [
        '1. System Working Principle',
        '2. RTL Module Code Descriptions',
        '3. Verification Suite',
        '4. FPGA Board Testing Guide (PetaLinux)',
        '5. Python Host Interface',
        '6. Quick Reference',
    ]
    for item in toc:
        pdf.cell(0, 8, item, new_x="LMARGIN", new_y="NEXT")

    # Chapter 1: System Working Principle
    pdf.chapter_title('1. System Working Principle')

    pdf.section_title('1.1 What is a Time Tagger?')
    pdf.body_text(
        'A Time Tagger is a precision instrument that records the exact time when '
        'electrical events (pulses) arrive at its input channels. It is used in '
        'quantum optics (photon correlation, HBT experiments), LIDAR (time-of-flight), '
        'fluorescence lifetime imaging (FLIM), and nuclear/particle physics.'
    )

    pdf.section_title('1.2 How This Design Works')
    pdf.body_text(
        'The system timestamps events with ~10 picosecond resolution using a '
        'tapped delay line technique implemented with Xilinx CARRY8 primitives.'
    )
    pdf.body_text('Step-by-step operation:')
    steps = [
        '1. Event arrives at an input channel (electrical pulse on FPGA pin)',
        '2. CARRY8 delay chain propagates the event through 256 taps (~8 ps each)',
        '3. Clock edge samples all 256 taps simultaneously -> thermometer code',
        '4. Bubble correction fixes single-bit glitches in the thermometer code',
        '5. Priority encoder converts thermometer code to binary (0-255) = fine timestamp',
        '6. Coarse counter (48-bit at 500 MHz) provides the integer clock count',
        '7. Tag formatter assembles 96-bit Tag_Record',
        '8. Calibration LUT corrects for non-uniform tap delays (DNL correction)',
        '9. Tag FIFO buffers the record (async: 500 MHz write -> 250 MHz read)',
        '10. Tag Mux arbitrates 9 sources (8 channels + coincidence) round-robin',
        '11. DMA Engine bursts tags to DDR memory via AXI4',
        '12. Linux reads DDR and Python parses the binary tag records',
    ]
    for s in steps:
        pdf.bullet(s)
    pdf.ln(3)

    pdf.section_title('1.3 Timing Resolution')
    pdf.bullet('Coarse resolution: 2 ns (500 MHz clock period)')
    pdf.bullet('Fine resolution: 2 ns / 256 taps = 7.8 ps per tap')
    pdf.bullet('After calibration: ~10 ps RMS jitter')
    pdf.ln(3)

    pdf.section_title('1.4 Key Specifications')
    widths = [45, 45]
    specs = [
        ('Parameter', 'Value'),
        ('Number of channels', '8'),
        ('Timing resolution', '~10 ps'),
        ('Coarse counter', '48 bits'),
        ('Fine taps', '256 (CARRY8)'),
        ('Tag record width', '96 bits'),
        ('FIFO depth/channel', '16,384 entries'),
        ('Max tag rate', '80 Mtags/s'),
        ('DMA burst size', 'Up to 256 beats'),
        ('AXI data width', '128b (DMA), 32b (reg)'),
        ('Clock domains', '500/250/100 MHz'),
    ]
    for i, (p, v) in enumerate(specs):
        pdf.table_row([p, v], widths, bold=(i == 0))
    pdf.ln(5)

    pdf.section_title('1.5 Tag_Record Format (96 bits)')
    pdf.body_text('Each timestamp event produces a 96-bit record:')
    widths = [25, 30, 15, 50]
    tag_fmt = [
        ('Bits', 'Field', 'Width', 'Description'),
        ('[95:48]', 'Coarse', '48b', '500 MHz counter value'),
        ('[47:32]', 'Fine', '16b', 'Calibrated fine timestamp'),
        ('[31:24]', 'Channel ID', '8b', '0-7 or 0xFF (coincidence)'),
        ('[23:16]', 'Flags', '8b', 'Bit7:overflow, Bit0:polarity'),
        ('[15:0]', 'Reserved', '16b', 'Zero or coinc bitmask'),
    ]
    for i, row in enumerate(tag_fmt):
        pdf.table_row(row, widths, bold=(i == 0))
    pdf.ln(5)

    pdf.section_title('1.6 System Block Diagram')
    pdf.body_text(
        'Event Inputs -> TDC Channels (x8) -> Tag FIFOs -> Tag Mux -> DMA Engine -> AXI4 Master\n'
        '                     |                                           ^\n'
        '                     v                                           |\n'
        '             Fine Interpolator                           AXI Register File\n'
        '             (CARRY8 delay line)                         (AXI4-Lite Slave)\n'
        '                     |\n'
        '             Calibration Module <-- Temperature Sensor\n'
        '                     |\n'
        '             Coincidence Detector --> Coincidence Tags'
    )

    # Chapter 2: RTL Module Descriptions
    pdf.chapter_title('2. RTL Module Code Descriptions')

    modules = [
        ('2.1 fine_interpolator.v - Delay Line TDC Core',
         'Measures the fractional clock period between an event edge and the next '
         'clock edge using a CARRY8 tapped delay line (256 taps).',
         '1. CARRY8 chain: 32 primitives x 8 taps = 256 total taps\n'
         '2. Sampling registers capture tap outputs on clock edge\n'
         '3. Bubble correction fixes isolated 0s in thermometer code\n'
         '4. Priority encoder: fine_bin = index of highest set bit\n'
         '5. Pipeline latency: 3 clock cycles'),
        ('2.2 tdc_channel.v - Complete TDC Channel',
         'Combines edge detection, coarse counting, fine interpolation, '
         'dead time enforcement (4 ns), calibration LUT, and tag formatting.',
         'Edge detector -> Dead time check -> Coarse+Fine assembly\n'
         '-> Calibration LUT lookup -> Tag_Record output\n'
         'Supports rising+falling edges, sync_reset, channel enable'),
        ('2.3 tag_fifo.v - Asynchronous FIFO',
         'Bridges 500 MHz write domain to 250 MHz read domain with '
         '16,384-entry depth and gray-code CDC pointers.',
         'Dual-port RAM + Gray-code write/read pointers\n'
         'High-watermark at 75% (12,288 entries)\n'
         'Circular buffer on overflow (oldest discarded)\n'
         'Occupancy accurate to +/-1 entry'),
        ('2.4 tag_mux.v - Round-Robin Arbiter',
         'Fair arbiter combining 9 tag sources (8 channels + coincidence) '
         'into a single output stream with backpressure support.',
         'Scans from last_granted+1, grants first non-empty source\n'
         'Holds output stable when tag_ready deasserted\n'
         'Guarantees no data loss and per-source ordering'),
    ]
    for title, desc, details in modules:
        pdf.section_title(title)
        pdf.body_text(desc)
        pdf.code_block(details)

    modules2 = [
        ('2.5 coincidence_detector.v - Window Comparator',
         'Detects temporal coincidences between events on different channels '
         'within configurable time windows. 4 groups, priority-based output.',
         'Compares timestamps within same group\n'
         'If |ts_A - ts_B| < window -> coincidence tag (ch_id=0xFF)\n'
         'Group 0 highest priority, channel bitmask in reserved field'),
        ('2.6 calibration_module.v - Auto-Calibration',
         'Automatically calibrates fine interpolator to correct delay line '
         'non-linearity. Temperature-triggered recalibration (dT > 5C).',
         'FSM: IDLE -> ACCUMULATE -> COMPUTE -> CHECK_DNL -> UPDATE_LUT\n'
         'Histogram: 2.56M samples across 256 bins\n'
         'Atomic LUT update (all channels simultaneously)\n'
         'Old LUT active during recalibration (no gaps)'),
        ('2.7 axi_register_file.v - Configuration Interface',
         'AXI4-Lite slave with read-write and read-only registers. '
         'SLVERR on writes to RO registers. Special STATUS/FIFO_DATA behavior.',
         'RW: CTRL, CH_ENABLE, EDGE_CONFIG, DMA_CTRL, COINC_*\n'
         'RO: CLK_STATUS, CAL_STATUS, DMA_STATUS (SLVERR on write)\n'
         'STATUS write -> err_clear_strobe pulse\n'
         'FIFO_DATA read -> fifo_rd_en pulse'),
        ('2.8 axi_dma_engine.v - Burst DMA',
         'Transfers tags to DDR via AXI4 burst writes. Supports circular '
         'buffer addressing and partial bursts on timeout.',
         'FSM: IDLE -> COLLECT -> ADDR -> DATA -> RESP\n'
         'Each 96-bit tag zero-padded to 128 bits (one AXI beat)\n'
         'Circular wrap at base_addr + buf_size\n'
         'awsize=4 (16 bytes), awburst=INCR'),
        ('2.9 rate_monitor.v - Health Monitoring',
         'Tracks per-channel tag rates (1 ms window), detects overflow, '
         'maintains error counters with saturation.',
         'Per-channel 16-bit rate counter (saturates at 0xFFFF)\n'
         'Aggregate overflow: >80 Mtags/s sustained >1 us\n'
         'Error counter: 32-bit, saturates at 0xFFFFFFFF\n'
         'Status: 00=OK, 01=disabled, 10=overflow, 11=error'),
        ('2.10 clock_manager.v - Clock Generation',
         'Generates all internal clocks from board oscillator using MMCME4_ADV. '
         'Supports external 10 MHz reference with automatic failover.',
         'State machine: IDLE->INTERNAL->EXT_LOCKING->EXT_LOCKED->FALLBACK\n'
         'Outputs: 500 MHz, 250 MHz, 100 MHz\n'
         'BUFGMUX_CTRL for glitch-free clock switching\n'
         'clk_loss_error asserted on external reference loss'),
    ]
    for title, desc, details in modules2:
        pdf.section_title(title)
        pdf.body_text(desc)
        pdf.code_block(details)

    # Chapter 3: Verification
    pdf.chapter_title('3. Verification Suite')
    pdf.body_text(
        'The project includes 11 self-checking testbenches in tb/ that run with '
        'Icarus Verilog 12.0 (iverilog -g2012). Each testbench reports [PASS]/[FAIL] '
        'per check and exits with code 0 (all pass) or 1 (failures).'
    )
    pdf.section_title('3.1 Testbench List')
    widths = [15, 55, 50]
    tbs = [
        ('TB#', 'File', 'Verification Goals'),
        ('1', 'tb_fine_interpolator.v', 'Delay line, bubble correction, encoder'),
        ('2', 'tb_tdc_channel.v', 'Edge detect, dead time, tag format'),
        ('3', 'tb_tag_fifo.v', 'Async FIFO, CDC, overflow'),
        ('4', 'tb_tag_mux.v', 'Round-robin, backpressure, no loss'),
        ('5', 'tb_coincidence_detector.v', 'Window detection, priority'),
        ('6', 'tb_calibration_module.v', 'Histogram, DNL, LUT, temperature'),
        ('7', 'tb_axi_register_file.v', 'AXI4-Lite protocol, SLVERR'),
        ('8', 'tb_axi_dma_engine.v', 'Burst writes, circular buffer'),
        ('9', 'tb_rate_monitor.v', 'Rate counting, saturation'),
        ('10', 'tb_clock_manager.v', 'Clock gen, failover, FSM'),
        ('11', 'tb_time_tagger_top.v', 'End-to-end data flow'),
    ]
    for i, row in enumerate(tbs):
        pdf.table_row(row, widths, bold=(i == 0))
    pdf.ln(5)

    pdf.section_title('3.2 Running Testbenches')
    pdf.body_text('Run in WSL (Ubuntu) with Icarus Verilog installed:')
    pdf.code_block(
        '# Example: Fine Interpolator\n'
        'iverilog -g2012 -I rtl -o sim/tb_fine_interpolator.vvp \\\n'
        '  sim/xilinx_stubs.v rtl/time_tagger_pkg.v \\\n'
        '  rtl/fine_interpolator.v tb/tb_fine_interpolator.v\n'
        'vvp sim/tb_fine_interpolator.vvp\n'
        '\n'
        '# Run all (bash script):\n'
        'for tb in fine_interpolator tdc_channel tag_fifo ...; do\n'
        '  iverilog -g2012 -I rtl -o sim/tb_${tb}.vvp \\\n'
        '    sim/xilinx_stubs.v rtl/time_tagger_pkg.v rtl/*.v \\\n'
        '    tb/tb_${tb}.v && vvp sim/tb_${tb}.vvp\n'
        'done'
    )

    # Chapter 4: FPGA Board Testing
    pdf.chapter_title('4. FPGA Board Testing Guide (PetaLinux)')

    pdf.section_title('4.1 Prerequisites')
    pdf.bullet('Xilinx Zynq UltraScale+ board (ZCU102, ZCU104, KCU116)')
    pdf.bullet('Vivado 2022.2+ (for bitstream generation)')
    pdf.bullet('PetaLinux 2022.2+ (for Linux image)')
    pdf.bullet('SD card (16 GB+)')
    pdf.bullet('Ethernet cable or USB cable for data transfer')
    pdf.bullet('Signal source (pulse generator or photon detector)')
    pdf.ln(3)

    pdf.section_title('4.2 Step 1: Vivado Project Setup')
    pdf.body_text(
        'Create a Vivado project, add all RTL from rtl/, set time_tagger_top '
        'as top module, and add constraints/time_tagger.xdc.'
    )
    pdf.body_text('Block Design connections:')
    pdf.bullet('PS M_AXI_HPM0_FPD -> s_axi_* (register access at 0xA000_0000)')
    pdf.bullet('m_axi_* -> PS S_AXI_HP0_FPD (DMA writes to DDR)')
    pdf.bullet('event_in[7:0] -> external FPGA pins (from XDC)')
    pdf.bullet('clk_board -> 100 MHz oscillator on board')
    pdf.ln(3)

    pdf.section_title('4.3 Step 2: PetaLinux Build')
    pdf.code_block(
        '# Create project\n'
        'petalinux-create -t project --template zynqMP -n time_tagger_linux\n'
        'cd time_tagger_linux\n'
        '\n'
        '# Import hardware\n'
        'petalinux-config --get-hw-description=/path/to/time_tagger_top.xsa\n'
        '\n'
        '# Enable UIO driver in kernel config\n'
        'petalinux-config -c kernel\n'
        '# -> Device Drivers -> Userspace I/O -> Enable\n'
        '\n'
        '# Enable Python in rootfs\n'
        'petalinux-config -c rootfs\n'
        '# -> Filesystem Packages -> misc -> python3\n'
        '\n'
        '# Build\n'
        'petalinux-build\n'
        '\n'
        '# Package boot image\n'
        'petalinux-package --boot --fsbl zynqmp_fsbl.elf \\\n'
        '  --fpga system.bit --pmufw pmufw.elf --u-boot'
    )

    pdf.section_title('4.4 Step 3: Device Tree Configuration')
    pdf.body_text('Add to system-user.dtsi for UIO and DMA buffer:')
    pdf.code_block(
        '/include/ "system-conf.dtsi"\n'
        '/ {\n'
        '  reserved-memory {\n'
        '    #address-cells = <2>;\n'
        '    #size-cells = <2>;\n'
        '    ranges;\n'
        '    dma_buf: buffer@10000000 {\n'
        '      compatible = "shared-dma-pool";\n'
        '      reg = <0x0 0x10000000 0x0 0x1000000>;\n'
        '      no-map;\n'
        '    };\n'
        '  };\n'
        '};\n'
        '&amba {\n'
        '  time_tagger@a0000000 {\n'
        '    compatible = "generic-uio";\n'
        '    reg = <0x0 0xa0000000 0x0 0x10000>;\n'
        '  };\n'
        '};'
    )

    pdf.section_title('4.5 Step 4: Flash and Boot')
    pdf.code_block(
        '# Partition SD card:\n'
        '#   Part 1: FAT32, 512 MB (boot)\n'
        '#   Part 2: ext4, remaining (rootfs)\n'
        '\n'
        '# Copy boot files to FAT32 partition:\n'
        'cp BOOT.BIN image.ub boot.scr /media/BOOT/\n'
        '\n'
        '# Extract rootfs to ext4 partition:\n'
        'sudo tar xf rootfs.tar.gz -C /media/rootfs/\n'
        '\n'
        '# Copy Python script:\n'
        'cp python/time_tagger_host.py /media/rootfs/home/root/\n'
        '\n'
        '# Set board DIP switches to SD boot mode\n'
        '# Power on -> Linux boots -> login as root'
    )

    pdf.section_title('4.6 Step 5: Verify on Board')
    pdf.code_block(
        '# Check UIO device appeared\n'
        'ls /dev/uio0\n'
        '\n'
        '# Check address mapping\n'
        'cat /sys/class/uio/uio0/maps/map0/addr  # 0xa0000000\n'
        'cat /sys/class/uio/uio0/maps/map0/size  # 0x10000\n'
        '\n'
        '# Run time tagger (local mode - prints to console)\n'
        'python3 time_tagger_host.py --mode local --uio --duration 5\n'
        '\n'
        '# Run as TCP server (for remote access)\n'
        'python3 time_tagger_host.py --mode ethernet --port 5555 --uio'
    )

    # Chapter 5: Python Host Interface
    pdf.chapter_title('5. Python Host Interface')

    pdf.section_title('5.1 Architecture')
    pdf.body_text(
        'The Python script (python/time_tagger_host.py) runs on the Zynq PS ARM core '
        'under PetaLinux. It accesses FPGA registers via memory-mapped I/O (/dev/mem '
        'or /dev/uio0) and reads DMA buffers from DDR. It can serve data over TCP '
        '(Ethernet) or USB serial to a remote host PC.'
    )
    pdf.code_block(
        'Data Flow:\n'
        'FPGA Event -> TDC -> DMA -> DDR Memory\n'
        '  -> Python reads DDR (mmap)\n'
        '  -> Parses 96-bit Tag_Records\n'
        '  -> Sends over TCP/USB to Host PC'
    )

    pdf.section_title('5.2 Running on FPGA Board (Server)')
    pdf.code_block(
        '# Ethernet mode (TCP server on port 5555)\n'
        'python3 time_tagger_host.py --mode ethernet --port 5555 --uio\n'
        '\n'
        '# USB serial mode\n'
        'python3 time_tagger_host.py --mode usb --device /dev/ttyGS0 --uio\n'
        '\n'
        '# Local mode (print to console)\n'
        'python3 time_tagger_host.py --mode local --uio --duration 10\n'
        '\n'
        '# Options:\n'
        '#   --channels 0xFF    Enable all 8 channels\n'
        '#   --channels 0x03    Enable only channels 0,1\n'
        '#   --uio              Use /dev/uio0 (no root needed)\n'
        '#   --duration 30      Run for 30 seconds'
    )

    pdf.section_title('5.3 Running on Host PC (Client)')
    pdf.code_block(
        '# Receive via Ethernet\n'
        'python3 time_tagger_host.py --mode client \\\n'
        '  --host 192.168.1.100 --port 5555 --duration 10\n'
        '\n'
        '# Receive via USB serial\n'
        'python3 time_tagger_host.py --mode client \\\n'
        '  --device /dev/ttyACM0 --duration 10\n'
        '# (Windows: --device COM3)\n'
        '\n'
        '# Save raw data to file\n'
        'python3 time_tagger_host.py --mode client \\\n'
        '  --host 192.168.1.100 --output timestamps.bin'
    )

    pdf.section_title('5.4 Data Analysis Example')
    pdf.code_block(
        'import struct, numpy as np\n'
        '\n'
        '# Read saved binary data (10 bytes per tag)\n'
        'with open("timestamps.bin", "rb") as f:\n'
        '    raw = f.read()\n'
        '\n'
        'n_tags = len(raw) // 10\n'
        'timestamps = np.zeros(n_tags, dtype=np.uint64)\n'
        'channels = np.zeros(n_tags, dtype=np.uint8)\n'
        '\n'
        'for i in range(n_tags):\n'
        '    ts, ch, flags = struct.unpack_from("<QBB", raw, i*10)\n'
        '    timestamps[i] = ts  # picoseconds\n'
        '    channels[i] = ch\n'
        '\n'
        '# Time differences on channel 0\n'
        'ch0 = timestamps[channels == 0]\n'
        'dt_ns = np.diff(ch0) / 1000.0  # convert ps to ns\n'
        'print(f"Mean: {dt_ns.mean():.2f} ns, Std: {dt_ns.std():.2f} ns")'
    )

    pdf.section_title('5.5 USB Gadget Setup')
    pdf.body_text('To use USB serial mode, configure USB gadget on the FPGA board:')
    pdf.code_block(
        'modprobe libcomposite\n'
        'modprobe usb_f_acm\n'
        'mkdir -p /sys/kernel/config/usb_gadget/tagger\n'
        'cd /sys/kernel/config/usb_gadget/tagger\n'
        'echo 0x1d6b > idVendor\n'
        'echo 0x0104 > idProduct\n'
        'mkdir -p strings/0x409\n'
        'echo "TimeTagger" > strings/0x409/product\n'
        'mkdir -p configs/c.1\n'
        'mkdir -p functions/acm.usb0\n'
        'ln -s functions/acm.usb0 configs/c.1/\n'
        'echo "fe200000.dwc3" > UDC\n'
        '# Now /dev/ttyGS0 is available'
    )

    # Chapter 6: Quick Reference
    pdf.chapter_title('6. Quick Reference')

    pdf.section_title('6.1 Register Map')
    widths = [20, 30, 12, 58]
    regs = [
        ('Offset', 'Name', 'R/W', 'Purpose'),
        ('0x000', 'CTRL', 'RW', 'Bit0: enable, Bit1: sync'),
        ('0x004', 'STATUS', 'RW', 'Write clears errors'),
        ('0x008', 'CH_ENABLE', 'RW', 'Channel enable mask [7:0]'),
        ('0x00C', 'EDGE_CONFIG', 'RW', 'Falling edge enable [7:0]'),
        ('0x010', 'CLK_STATUS', 'RO', 'Clock lock/loss status'),
        ('0x014', 'CAL_CTRL', 'RW', 'Calibration control'),
        ('0x020', 'COINC_GROUP0', 'RW', 'Bit31:en, [7:0]:mask'),
        ('0x040', 'COINC_WIN0', 'RW', 'Window value [9:0]'),
        ('0x100', 'FIFO_DATA', 'RO', 'Read triggers fifo_rd_en'),
        ('0x200', 'DMA_STATUS', 'RO', 'DMA busy/error'),
        ('0x204', 'DMA_CTRL', 'RW', 'Bit0:en, [15:8]:burst-1'),
        ('0x300', 'DEAD_TIME', 'RW', 'Dead time config'),
    ]
    for i, row in enumerate(regs):
        pdf.table_row(row, widths, bold=(i == 0))
    pdf.ln(5)

    pdf.section_title('6.2 Directory Structure')
    pdf.code_block(
        'time_tagger_kiro/\n'
        '  rtl/                  RTL source files (12 modules)\n'
        '  tb/                   Self-checking testbenches (11)\n'
        '  sim/                  Xilinx primitive stubs\n'
        '  constraints/          FPGA pin constraints (XDC)\n'
        '  docs/                 Documentation\n'
        '  python/               Host-side Python interface'
    )

    pdf.section_title('6.3 Network Diagram')
    pdf.code_block(
        '+----------------+     Ethernet      +------------------+\n'
        '|   Host PC      |<----------------->|  FPGA Board      |\n'
        '|                |    TCP:5555       |  (Zynq MPSoC)   |\n'
        '|  Python        |                   |                  |\n'
        '|  client mode   |     OR USB       |  Python server   |\n'
        '|                |<----------------->|  time_tagger_    |\n'
        '|                |   /dev/ttyACM0   |  host.py         |\n'
        '+----------------+                   +------------------+'
    )

    pdf.section_title('6.4 Connecting Event Sources')
    pdf.body_text(
        'Connect your signal source to the FPGA pins mapped to event_in[7:0] '
        'in the XDC constraints file. Requirements:'
    )
    pdf.bullet('Logic levels: LVCMOS33 or LVTTL (3.3V)')
    pdf.bullet('Pulse width: minimum 2 ns (one clock cycle at 500 MHz)')
    pdf.bullet('Proper termination to avoid reflections')
    pdf.bullet('Single-photon detectors: TTL output directly compatible')
    pdf.bullet('Pulse generators: use 50 ohm termination')

    # Save PDF
    output_path = r'd:\time_tagger_kiro\docs\FPGA_Time_Tagger_Guide.pdf'
    pdf.output(output_path)
    print(f'PDF generated: {output_path}')


if __name__ == '__main__':
    generate_pdf()
