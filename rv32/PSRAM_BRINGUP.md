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
front = die 1   (future HDMI)
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

Each CPU 32-bit load/store is split into one or two 16-bit commands.  The
switcher includes a CPU sequence lock, so a frame boundary cannot move the
second halfword of a 32-bit access to the other die.

## Logical clients

`psramSwitcher` has three clients, all currently expressed as single-word
16-bit command ports in the 80 MHz domain:

- HDMI exclusively accesses front;
- GPU and CPU share back;
- GPU has priority when GPU and CPU become valid at the same command boundary;
- an already accepted CPU transaction is never pre-empted;
- HDMI and the selected CPU/GPU client may access opposite dies concurrently.

The top level ties the future GPU and HDMI ports inactive for now.  CPU-only
bring-up therefore exercises back through the normal PicoRV32 memory window.

## Frame swap handshake

The CPU writes `SWAP_REQUEST`.  The request remains pending and
`frame_swap_request` remains high until HDMI reports `hdmi_frame_done`.
The switcher then blocks new commands, drains accepted physical and logical
transactions, and atomically flips front/back.

Before HDMI exists, MMIO bit 1 injects a software frame-done event so both
physical dies can be tested through the one logical window.

## Configuration window

The configuration window remains at `0x0300_0000`:

| Offset | Access | Description |
|---:|---|---|
| `0x00` | R | PHY frequency, `80_000_000` |
| `0x04` | R | init/busy/die-ready/swap/front/back/GPU/HDMI status |
| `0x08` | R/W | rPLL phase tap, reset value 5 |
| `0x0c` | R | version `0x50535253` (`PSRS`) |
| `0x10` | R | phase-clock activity counter |
| `0x14` | R | CPU-visible logical bytes, `0x0040_0000` |
| `0x18` | R/W | swap status/control |
| `0x1c` | R | total physical bytes, `0x0080_0000` |

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

## HDMI follow-up

The placeholder HDMI word port is not fast enough for 720p60.  The next stage
will add a burst reader and asynchronous line FIFO above the front port.  The
GPU placeholder will similarly become a burst writer on back; its existing
priority over the CPU is already enforced at the switcher boundary.
