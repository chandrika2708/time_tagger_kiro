#!/usr/bin/env python3
"""
FPGA Time Tagger — Host Interface
==================================
This script runs on the Zynq PS (ARM) under PetaLinux.
It configures the time tagger, reads DMA buffers, and serves
timestamp data over TCP (Ethernet) or USB serial.

Usage:
    # On FPGA board via SSH:
    python3 time_tagger_host.py --mode ethernet --port 5555
    python3 time_tagger_host.py --mode usb --device /dev/ttyGS0
    python3 time_tagger_host.py --mode local --output timestamps.bin

Requirements:
    - Python 3.6+
    - numpy (optional, for analysis)
    - mmap access to /dev/mem or /dev/uio0
"""

import struct
import mmap
import os
import sys
import time
import socket
import argparse
import threading
from collections import namedtuple

# =============================================================================
# Constants
# =============================================================================

# Register base address (from Vivado address editor)
REG_BASE_ADDR = 0xA000_0000
REG_SIZE = 0x10000  # 64 KB

# DMA buffer in DDR (from device tree reserved-memory)
DMA_BASE_ADDR = 0x1000_0000
DMA_BUF_SIZE = 0x100_0000  # 16 MB

# Register offsets
REG_CTRL = 0x000
REG_STATUS = 0x004
REG_CH_ENABLE = 0x008
REG_EDGE_CONFIG = 0x00C
REG_CLK_STATUS = 0x010
REG_CAL_CTRL = 0x014
REG_COINC_GROUP0 = 0x020
REG_COINC_GROUP1 = 0x024
REG_COINC_GROUP2 = 0x028
REG_COINC_GROUP3 = 0x02C
REG_COINC_WIN0 = 0x040
REG_COINC_WIN1 = 0x044
REG_COINC_WIN2 = 0x048
REG_COINC_WIN3 = 0x04C
REG_DMA_STATUS = 0x200
REG_DMA_CTRL = 0x204
REG_DEAD_TIME = 0x300

# Tag record size in DMA buffer (128 bits = 16 bytes per tag)
TAG_SIZE_BYTES = 16

# Tag_Record structure
TagRecord = namedtuple('TagRecord', [
    'timestamp_coarse',  # 48-bit coarse counter
    'timestamp_fine',    # 16-bit fine interpolator value
    'channel_id',        # 8-bit channel (0-7, or 0xFF for coincidence)
    'flags',             # 8-bit flags
    'reserved',          # 16-bit (channel bitmask for coincidence)
])


# =============================================================================
# Memory-Mapped Register Access
# =============================================================================

class MemoryMap:
    """Access FPGA registers and DMA buffer via /dev/mem."""

    def __init__(self, use_uio=False):
        if use_uio:
            # UIO-based access (safer, no root required if permissions set)
            self._fd_reg = os.open('/dev/uio0', os.O_RDWR | os.O_SYNC)
            self._reg_mmap = mmap.mmap(
                self._fd_reg, REG_SIZE,
                mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE,
                offset=0
            )
            # DMA buffer still needs /dev/mem
            self._fd_mem = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
            self._dma_mmap = mmap.mmap(
                self._fd_mem, DMA_BUF_SIZE,
                mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE,
                offset=DMA_BASE_ADDR
            )
        else:
            # Direct /dev/mem access (requires root)
            self._fd_mem = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
            self._reg_mmap = mmap.mmap(
                self._fd_mem, REG_SIZE,
                mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE,
                offset=REG_BASE_ADDR
            )
            self._dma_mmap = mmap.mmap(
                self._fd_mem, DMA_BUF_SIZE,
                mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE,
                offset=DMA_BASE_ADDR
            )

    def reg_write(self, offset, value):
        """Write a 32-bit value to a register."""
        struct.pack_into('<I', self._reg_mmap, offset, value)

    def reg_read(self, offset):
        """Read a 32-bit value from a register."""
        return struct.unpack_from('<I', self._reg_mmap, offset)[0]

    def read_dma_buffer(self, offset, size):
        """Read raw bytes from the DMA buffer."""
        self._dma_mmap.seek(offset)
        return self._dma_mmap.read(size)

    def close(self):
        self._reg_mmap.close()
        self._dma_mmap.close()
        if hasattr(self, '_fd_reg'):
            os.close(self._fd_reg)
        os.close(self._fd_mem)


# =============================================================================
# Time Tagger Controller
# =============================================================================

class TimeTagger:
    """High-level interface to the FPGA Time Tagger."""

    def __init__(self, use_uio=False):
        self.mm = MemoryMap(use_uio=use_uio)
        self._read_ptr = 0  # Current read position in DMA buffer

    def configure(self, channels=0xFF, falling_edge=0x00,
                  coinc_groups=None, coinc_windows=None,
                  dma_burst_len=16):
        """Configure the time tagger for operation."""

        # Enable channels
        self.mm.reg_write(REG_CH_ENABLE, channels & 0xFF)

        # Edge configuration
        self.mm.reg_write(REG_EDGE_CONFIG, falling_edge & 0xFF)

        # Coincidence groups (if provided)
        if coinc_groups:
            group_regs = [REG_COINC_GROUP0, REG_COINC_GROUP1,
                          REG_COINC_GROUP2, REG_COINC_GROUP3]
            for i, (mask, enable) in enumerate(coinc_groups[:4]):
                val = (1 << 31 if enable else 0) | (mask & 0xFF)
                self.mm.reg_write(group_regs[i], val)

        if coinc_windows:
            win_regs = [REG_COINC_WIN0, REG_COINC_WIN1,
                        REG_COINC_WIN2, REG_COINC_WIN3]
            for i, window in enumerate(coinc_windows[:4]):
                self.mm.reg_write(win_regs[i], window & 0x3FF)

        # DMA configuration: enable + burst_len
        dma_ctrl = 0x01 | ((dma_burst_len - 1) << 8)
        self.mm.reg_write(REG_DMA_CTRL, dma_ctrl)

        # Global enable
        self.mm.reg_write(REG_CTRL, 0x01)

        print(f"[INFO] Time Tagger configured: channels=0x{channels:02X}, "
              f"burst_len={dma_burst_len}")

    def read_tags(self, max_tags=1024):
        """Read available tags from the DMA buffer.

        Returns a list of TagRecord namedtuples.
        """
        tags = []
        buf_size = DMA_BUF_SIZE
        bytes_to_read = min(max_tags * TAG_SIZE_BYTES, buf_size - self._read_ptr)

        if bytes_to_read <= 0:
            self._read_ptr = 0
            bytes_to_read = min(max_tags * TAG_SIZE_BYTES, buf_size)

        raw = self.mm.read_dma_buffer(self._read_ptr, bytes_to_read)

        for i in range(0, len(raw), TAG_SIZE_BYTES):
            chunk = raw[i:i + TAG_SIZE_BYTES]
            if len(chunk) < TAG_SIZE_BYTES:
                break

            # Parse 128-bit DMA word (little-endian)
            # Layout: [15:0]=reserved, [23:16]=flags, [31:24]=ch_id,
            #         [95:32]=timestamp, [127:96]=padding
            word_lo = struct.unpack_from('<Q', chunk, 0)[0]  # bits [63:0]
            word_hi = struct.unpack_from('<Q', chunk, 8)[0]  # bits [127:64]

            reserved = word_lo & 0xFFFF
            flags = (word_lo >> 16) & 0xFF
            channel_id = (word_lo >> 24) & 0xFF
            timestamp_raw = (word_lo >> 32) | ((word_hi & 0xFFFFFFFF) << 32)

            # Skip empty records
            if timestamp_raw == 0 and channel_id == 0:
                continue

            coarse = (timestamp_raw >> 16) & 0xFFFF_FFFF_FFFF  # upper 48 bits
            fine = timestamp_raw & 0xFFFF  # lower 16 bits

            tag = TagRecord(
                timestamp_coarse=coarse,
                timestamp_fine=fine,
                channel_id=channel_id,
                flags=flags,
                reserved=reserved,
            )
            tags.append(tag)

        self._read_ptr = (self._read_ptr + len(raw)) % buf_size
        return tags

    def get_timestamp_ps(self, tag):
        """Convert a TagRecord to absolute timestamp in picoseconds.

        Assumes 500 MHz coarse clock (2 ns per tick) and 256 fine bins
        spanning one coarse period.
        """
        coarse_ps = tag.timestamp_coarse * 2000  # 2 ns = 2000 ps per coarse tick
        fine_ps = (tag.timestamp_fine * 2000) // 256  # Fine fraction of 2 ns
        return coarse_ps + fine_ps

    def get_status(self):
        """Read system status."""
        clk_status = self.mm.reg_read(REG_CLK_STATUS)
        dma_status = self.mm.reg_read(REG_DMA_STATUS)
        return {
            'clock_locked': bool(clk_status & 0x01),
            'clock_loss': bool(clk_status & 0x02),
            'dma_busy': bool(dma_status & 0x01),
            'dma_error': bool(dma_status & 0x02),
        }

    def clear_errors(self):
        """Clear error flags by writing to STATUS register."""
        self.mm.reg_write(REG_STATUS, 0x01)

    def sync_reset(self):
        """Pulse sync to reset all coarse counters."""
        ctrl = self.mm.reg_read(REG_CTRL)
        self.mm.reg_write(REG_CTRL, ctrl | 0x02)  # Set sync bit
        time.sleep(0.001)
        self.mm.reg_write(REG_CTRL, ctrl & ~0x02)  # Clear sync bit

    def disable(self):
        """Disable the time tagger."""
        self.mm.reg_write(REG_CTRL, 0x00)
        self.mm.reg_write(REG_DMA_CTRL, 0x00)

    def close(self):
        self.disable()
        self.mm.close()


# =============================================================================
# TCP Server (Ethernet mode)
# =============================================================================

class TCPServer:
    """Serves timestamp data over TCP to a remote host."""

    def __init__(self, tagger, host='0.0.0.0', port=5555):
        self.tagger = tagger
        self.host = host
        self.port = port
        self.running = False

    def start(self):
        self.running = True
        self.server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.server.bind((self.host, self.port))
        self.server.listen(1)
        print(f"[INFO] TCP server listening on {self.host}:{self.port}")

        while self.running:
            try:
                conn, addr = self.server.accept()
                print(f"[INFO] Client connected: {addr}")
                self._handle_client(conn)
            except OSError:
                break

    def _handle_client(self, conn):
        """Stream tags to connected client as binary records."""
        try:
            while self.running:
                tags = self.tagger.read_tags(max_tags=256)
                if tags:
                    for tag in tags:
                        # Send as: timestamp_ps (8 bytes) + channel_id (1 byte)
                        # + flags (1 byte) = 10 bytes per tag
                        ts_ps = self.tagger.get_timestamp_ps(tag)
                        record = struct.pack('<QBB', ts_ps,
                                            tag.channel_id, tag.flags)
                        conn.sendall(record)
                else:
                    time.sleep(0.001)  # 1 ms poll interval
        except (BrokenPipeError, ConnectionResetError):
            print("[INFO] Client disconnected")
        finally:
            conn.close()

    def stop(self):
        self.running = False
        self.server.close()


# =============================================================================
# USB Serial Mode
# =============================================================================

class USBSerialServer:
    """Serves timestamp data over USB serial (CDC-ACM)."""

    def __init__(self, tagger, device='/dev/ttyGS0'):
        self.tagger = tagger
        self.device = device
        self.running = False

    def start(self):
        self.running = True
        print(f"[INFO] USB serial output on {self.device}")

        # Open the USB gadget serial device
        with open(self.device, 'wb', buffering=0) as f:
            while self.running:
                tags = self.tagger.read_tags(max_tags=64)
                if tags:
                    for tag in tags:
                        ts_ps = self.tagger.get_timestamp_ps(tag)
                        record = struct.pack('<QBB', ts_ps,
                                            tag.channel_id, tag.flags)
                        f.write(record)
                else:
                    time.sleep(0.001)

    def stop(self):
        self.running = False


# =============================================================================
# Host-side Client (runs on your PC)
# =============================================================================

def receive_tags_tcp(host, port, duration_s=10.0, output_file=None):
    """Connect to the FPGA TCP server and receive timestamps.

    Run this on your host PC.
    """
    print(f"[INFO] Connecting to {host}:{port}...")
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.connect((host, port))
    print("[INFO] Connected. Receiving tags...")

    tags_received = 0
    start_time = time.time()
    output = open(output_file, 'wb') if output_file else None

    try:
        while time.time() - start_time < duration_s:
            data = sock.recv(10240)  # 1024 tags × 10 bytes
            if not data:
                break

            if output:
                output.write(data)

            # Parse received tags
            for i in range(0, len(data) - 9, 10):
                ts_ps, ch_id, flags = struct.unpack_from('<QBB', data, i)
                tags_received += 1

                if tags_received <= 20:  # Print first 20
                    ts_ns = ts_ps / 1000.0
                    print(f"  Ch{ch_id}: {ts_ns:.3f} ns "
                          f"(flags=0x{flags:02X})")

    except KeyboardInterrupt:
        pass
    finally:
        elapsed = time.time() - start_time
        rate = tags_received / elapsed if elapsed > 0 else 0
        print(f"\n[INFO] Received {tags_received} tags in {elapsed:.2f}s "
              f"({rate:.0f} tags/s)")
        sock.close()
        if output:
            output.close()


def receive_tags_usb(device='/dev/ttyACM0', duration_s=10.0, output_file=None):
    """Read timestamps from USB serial port.

    Run this on your host PC.
    """
    import serial  # pip install pyserial

    print(f"[INFO] Opening {device}...")
    ser = serial.Serial(device, baudrate=3000000, timeout=1)
    print("[INFO] Connected. Receiving tags...")

    tags_received = 0
    start_time = time.time()
    output = open(output_file, 'wb') if output_file else None
    buffer = b''

    try:
        while time.time() - start_time < duration_s:
            data = ser.read(10240)
            if data:
                if output:
                    output.write(data)
                buffer += data

                while len(buffer) >= 10:
                    ts_ps, ch_id, flags = struct.unpack_from('<QBB', buffer, 0)
                    buffer = buffer[10:]
                    tags_received += 1

                    if tags_received <= 20:
                        ts_ns = ts_ps / 1000.0
                        print(f"  Ch{ch_id}: {ts_ns:.3f} ns "
                              f"(flags=0x{flags:02X})")

    except KeyboardInterrupt:
        pass
    finally:
        elapsed = time.time() - start_time
        rate = tags_received / elapsed if elapsed > 0 else 0
        print(f"\n[INFO] Received {tags_received} tags in {elapsed:.2f}s "
              f"({rate:.0f} tags/s)")
        ser.close()
        if output:
            output.close()


# =============================================================================
# Main Entry Point
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description='FPGA Time Tagger Host Interface')
    parser.add_argument('--mode', choices=['ethernet', 'usb', 'local', 'client'],
                        default='local',
                        help='Operating mode')
    parser.add_argument('--port', type=int, default=5555,
                        help='TCP port (ethernet mode)')
    parser.add_argument('--host', default='0.0.0.0',
                        help='Listen/connect address')
    parser.add_argument('--device', default='/dev/ttyGS0',
                        help='USB serial device')
    parser.add_argument('--output', default=None,
                        help='Output file for timestamps')
    parser.add_argument('--channels', type=lambda x: int(x, 0), default=0xFF,
                        help='Channel enable mask (hex)')
    parser.add_argument('--duration', type=float, default=10.0,
                        help='Acquisition duration (seconds)')
    parser.add_argument('--uio', action='store_true',
                        help='Use UIO instead of /dev/mem')

    args = parser.parse_args()

    if args.mode == 'client':
        # Client mode: runs on host PC, connects to FPGA
        if 'ttyACM' in args.device or 'COM' in args.device:
            receive_tags_usb(args.device, args.duration, args.output)
        else:
            receive_tags_tcp(args.host, args.port, args.duration, args.output)
        return

    # Server modes: run on FPGA board
    tagger = TimeTagger(use_uio=args.uio)

    try:
        tagger.configure(channels=args.channels)
        tagger.sync_reset()

        if args.mode == 'ethernet':
            server = TCPServer(tagger, host=args.host, port=args.port)
            server.start()

        elif args.mode == 'usb':
            server = USBSerialServer(tagger, device=args.device)
            server.start()

        elif args.mode == 'local':
            # Local mode: print tags to console
            print(f"[INFO] Acquiring for {args.duration}s...")
            start = time.time()
            total_tags = 0

            while time.time() - start < args.duration:
                tags = tagger.read_tags(max_tags=256)
                for tag in tags:
                    ts_ps = tagger.get_timestamp_ps(tag)
                    ts_ns = ts_ps / 1000.0
                    ch = tag.channel_id
                    if ch == 0xFF:
                        print(f"  COINC: {ts_ns:.3f} ns "
                              f"(mask=0x{tag.reserved:04X})")
                    else:
                        print(f"  Ch{ch}: {ts_ns:.3f} ns "
                              f"(flags=0x{tag.flags:02X})")
                    total_tags += 1

                if not tags:
                    time.sleep(0.001)

            print(f"\n[INFO] Total: {total_tags} tags in {args.duration}s")

    except KeyboardInterrupt:
        print("\n[INFO] Interrupted")
    finally:
        tagger.close()


if __name__ == '__main__':
    main()
