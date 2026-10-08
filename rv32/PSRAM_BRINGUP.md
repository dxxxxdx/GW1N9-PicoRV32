# PSRAM front/back die switcher

## Memory organization

The two embedded x8 dies remain physically independent:

| Physical die | Capacity | PHY |
|---|---:|---|
| die 0 | 4 MiB | `psramPhy phy0` |
| die 1 | 4 MiB | `psramPhy phy1` |

Software no longer sees one contiguous 8 MiB region.  It sees one logical
4 MiB back-buffer window at `0x0200_0000`–`0x023f_ffff`.  `psramSwitcher`
maps that window to whichever physical die is currently back.  HDMI owns the
opposite, front die.

Reset ownership is:

```text
front = die 1   (HDMI)
back  = die 0   (CPU/GPU)
```

A swap changes only these two ownership bits.  It does not copy memory.

## Clock and PHY configuration

- CPU, MMIO and normal bus: 40 MHz
- two PSRAM PHYs: 80 MHz
- PSRAM CK: 80 MHz with dynamic rPLL phase
- default phase: tap 5, from the measured common pass window 2..7
- CR0: `0x9FEF`, latency 3, fixed 2x latency, 35-ohm drive
- power-up: each PHY waits 160 us and configures its own die

Each CPU 32-bit load/store becomes one two-beat physical burst: CA is sent
once, then the low and high halfwords travel as two consecutive 16-bit beats.
The streaming PHY port only ever carries the current value in `w_data[15:0]`
or `r_data[15:0]`; the CPU bridge does the 32-bit split/join.  A frame boundary
cannot move the second beat to the other die because the switcher locks the
owner and physical die for the entire burst.

## Logical clients

`psramSwitcher` has three clients, all expressed as burst ports in the 80 MHz
domain.  One accepted command carries 1..64 consecutive 16-bit beats (2..128
bytes):

- HDMI exclusively accesses front;
- GPU and CPU share back;
- GPU has priority when GPU and CPU become valid at the same command boundary;
- an already accepted CPU transaction is never pre-empted;
- HDMI and the selected CPU/GPU client may access opposite dies concurrently.

The write source holds its current low-16-bit beat until `*_w_take`, then
advances on that same clock edge.  Reads return `*_r_valid` and `*_r_last`
without backpressure, so an HDMI reader must reserve enough line-FIFO space
before issuing its command.  `*_done` releases ownership after the physical
recovery interval.

The top level ties the future GPU port inactive for now.  HDMI is connected to
front through `psramHdmiReader`: it issues 64-beat reads and crosses the data
to the pixel clock through one 512 x 16 dual-clock BSRAM FIFO.

## Frame swap handshake

The CPU writes `SWAP_REQUEST`.  The request remains pending and
`frame_swap_request` remains high until HDMI reports `hdmi_frame_done`.
The switcher then blocks new commands, drains accepted physical and logical
transactions, and atomically flips front/back.

While HDMI is disabled, MMIO bit 1 injects a software frame-done event so both
physical dies can be tested through the one logical window.  Once HDMI is
enabled, its last burst of each frame supplies the production frame-done event.

## Configuration window

The configuration window remains at `0x0300_0000`:

| Offset | Access | Description |
|---:|---|---|
| `0x00` | R | PHY frequency, `80_000_000` |
| `0x04` | R | init/busy/die-ready/swap/front/back/GPU/HDMI status |
| `0x08` | R/W | rPLL phase tap, reset value 5 |
| `0x0c` | R | version `0x50534231` (`PSB1`, burst-port ABI v1) |
| `0x10` | R | phase-clock activity counter |
| `0x14` | R | CPU-visible logical bytes, `0x0040_0000` |
| `0x18` | R/W | swap status/control |
| `0x1c` | R | total physical bytes, `0x0080_0000` |
| `0x20` | R/W | HDMI enable, bit 0 |

`0x18` writes:

```text
bit 0 = request swap at the next HDMI frame boundary
bit 1 = inject frame-done for pre-HDMI testing only
```

`0x18` reads:

```text
bit 0      = swap pending
bit 1      = physical front die
bit 2      = physical back die
bit 3      = request level presented to HDMI
bits 31:16 = completed swap count
```

## Firmware bring-up

The current firmware uses the software frame-done bit to:

1. train all 16 phases through both physical dies;
2. test byte/halfword lanes and 4 MiB boundaries on both dies;
3. write different values at the same logical address on each die and verify
   that swapping preserves both values;
4. run a full 4 MiB write/read test on die 0 and then die 1.

The `.psram` linker section is `NOLOAD` and is limited to the logical 4 MiB
back window.  Firmware cannot directly address the front die; it must request a
frame-boundary swap first.

## HDMI reader

The HDMI front-port reader is implemented.  A 640x480 RGB565 frame begins at
offset zero and occupies 614400 bytes.  It fetches 64 pixels/128 bytes per
burst, for exactly 4800 bursts per frame, and reserves a whole burst plus a
small CDC margin before launching.  The 512 x 16 FIFO is an explicit `SDPB`,
so it consumes one BSRAM rather than about 8192 flip-flops.

The video clock tree is 126.667 MHz serializer `/5` to 25.333 MHz pixel clock.
With the Tang Nano 800x525 raster this is about 60.3 Hz and about 37.0 MB/s of
active RGB565 reads.  Each front die has a raw 160 MB/s data rate at 80 MHz DDR.

The GPU placeholder uses the same burst shape on back; its priority over the
CPU is already enforced at the switcher boundary.  The PHY intentionally
contains no 128-byte buffer, so the future GPU may add its own BSRAM without
duplicating storage in every PHY.
