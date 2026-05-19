# FPGA Time Tagger

A high-precision multi-channel Time-to-Digital Converter (TDC) implemented on Xilinx UltraScale+ FPGAs. Achieves ~10 ps timing resolution using CARRY8 tapped delay lines with 8 independent input channels, coincidence detection, and DMA-based data transfer.

## Architecture

```
Event Inputs ──► TDC Channels (×8) ──► Tag FIFOs ──► Tag Mux ──► DMA Engine ──► AXI4 Master
                      │                                              ▲
                      ▼                                              │
              Fine Interpolator                              AXI Register File
              (CARRY8 delay line)                            (AXI4-Lite Slave)
                      │
              Calibration Module ◄── Temperature Sensor
                      │
              Coincidence Detector ──► Coincidence Tags
```

## Features

- **8 independent TDC channels** with ~10 ps resolution (CARRY8 delay line)
- **Thermometer-to-binary encoding** with bubble correction
- **Automatic calibration** with temperature-triggered recalibration
- **Coincidence detection** with configurable time windows (4 groups)
- **Asynchronous Tag FIFOs** (16K deep) with gray-code CDC
- **Round-robin tag multiplexer** for fair channel arbitration
- **AXI4 DMA engine** for high-throughput burst transfers
- **AXI4-Lite register file** for configuration and status
- **Clock manager** with external reference switching and failover

## Directory Structure

```
time_tagger_kiro/
├── rtl/                    # RTL source files
│   ├── time_tagger_pkg.v   # Shared parameters package
│   ├── time_tagger_top.v   # Top-level module
│   ├── fine_interpolator.v # CARRY8 delay line TDC
│   ├── tdc_channel.v       # Complete TDC channel
│   ├── tag_fifo.v          # Async FIFO with CDC
│   ├── tag_mux.v           # Round-robin multiplexer
│   ├── coincidence_detector.v
│   ├── calibration_module.v
│   ├── axi_register_file.v
│   ├── axi_dma_engine.v
│   ├── rate_monitor.v
│   └── clock_manager.v
├── tb/                     # Self-checking testbenches
├── sim/                    # Simulation support files
│   └── xilinx_stubs.v     # Xilinx primitive stubs
├── constraints/            # FPGA constraints
│   └── time_tagger.xdc
├── docs/                   # Documentation
│   └── time_tagger_documentation.md
└── python/                 # Host-side Python interface
    └── time_tagger_host.py
```

## Quick Start (Simulation)

```bash
# Requires Icarus Verilog 12.0 (iverilog with -g2012)
# Run all testbenches:
cd /path/to/time_tagger_kiro
iverilog -g2012 -I rtl -o sim/tb_fine_interpolator.vvp sim/xilinx_stubs.v rtl/time_tagger_pkg.v rtl/fine_interpolator.v tb/tb_fine_interpolator.v
vvp sim/tb_fine_interpolator.vvp
```

## Hardware Deployment (PetaLinux)

See `docs/time_tagger_documentation.md` for complete PetaLinux build and Python host interface instructions.

## License

MIT
