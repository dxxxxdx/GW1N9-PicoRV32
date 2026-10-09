/*
 * HDMI framebuffer and embedded-PSRAM software interface.
 *
 * There are two physical 4 MiB PSRAM dies. Software never selects a physical
 * die in the address: 0x0200_0000..0x023f_ffff is always the logical BACK die.
 * HDMI reads the opposite (FRONT) die. SwapController atomically exchanges
 * the two logical roles at a frame boundary; it does not copy any pixels.
 *
 * Therefore an object placed at a PSRAM address refers to whichever physical
 * die is currently BACK. Do not expect its contents to remain the same after
 * a front/back swap unless both dies were initialized identically.
 */
#ifndef GW1NR9_RV32_HDMI_PSRAM_H
#define GW1NR9_RV32_HDMI_PSRAM_H

#include <stdint.h>

/* Active video format. One framebuffer is 640*480 RGB565 = 614400 bytes. */
#define HDMI_WIDTH                 640u
#define HDMI_HEIGHT                480u
#define HDMI_FRAME_BYTES           (HDMI_WIDTH * HDMI_HEIGHT * 2u)

/* CPU-visible logical BACK window and total storage across both physical dies. */
#define HDMI_PSRAM_BASE            0x02000000u
#define HDMI_PSRAM_SIZE            0x00400000u
#define HDMI_PSRAM_PHYSICAL_SIZE   0x00800000u

/*
 * Put an object in the linker's .psram NOLOAD section. NOLOAD means neither
 * the download image nor reset code initializes it; software/GPU must fill it.
 * The linker rejects objects that extend past the 4 MiB logical window.
 */
#define HDMI_PSRAM_SECTION __attribute__((section(".psram"), aligned(4)))

/* Linker symbols for the allocated .psram area and the complete 4 MiB window. */
extern uint8_t __psram_base[];   /* first byte of the complete logical window */
extern uint8_t __psram_limit[];  /* one byte past the complete logical window */
extern uint8_t __psram_start[];  /* first byte allocated to .psram objects */
extern uint8_t __psram_end[];    /* one byte past allocated .psram objects */

/* Typed volatile views of the logical BACK window. */
#define HDMI_PSRAM_U32 ((volatile uint32_t *)HDMI_PSRAM_BASE)
#define HDMI_PSRAM_U16 ((volatile uint16_t *)HDMI_PSRAM_BASE)
#define HDMI_PSRAM_U8  ((volatile uint8_t  *)HDMI_PSRAM_BASE)

/*
 * HDMI/PSRAM configuration page: 0x0300_0000..0x0300_0fff.
 *
 * +0x00 INFO       R   PHY clock frequency in Hz (currently 80,000,000).
 * +0x04 STATUS     R   Live synchronized status; bit definitions are below.
 * +0x08 PHASE      R/W PSRAM CK rPLL phase tap in bits [3:0]. Reset value is 5.
 *                       A write changes phase directly; it does not retrain or
 *                       verify memory. Only the written value's low 4 bits
 *                       are retained.
 * +0x0c MAGIC      R   Page/version signature 0x48505331 (ASCII "HPS1").
 * +0x10 CKPCNT     R   Sampled bits [31:16] of a free-running clk_p counter.
 *                       It is an activity diagnostic, not a precise timer.
 * +0x14 BYTES      R   CPU-visible logical BACK size (0x0040_0000).
 * +0x18 PHYS_BYTES R   Total size of both physical dies (0x0080_0000).
 * +0x1c CTRL       R/W bit 0 enables HDMI fetch/output. Reset value is 0.
 *
 * All registers are 32-bit. PHASE and CTRL writes require byte lane 0.
 */
#define HDMI_PSRAM_CFG_BASE        0x03000000u
#define HDMI_PSRAM_INFO_REG        (*(volatile uint32_t *)(HDMI_PSRAM_CFG_BASE + 0x00u))
#define HDMI_PSRAM_STATUS_REG      (*(volatile uint32_t *)(HDMI_PSRAM_CFG_BASE + 0x04u))
#define HDMI_PSRAM_PHASE_REG       (*(volatile uint32_t *)(HDMI_PSRAM_CFG_BASE + 0x08u))
#define HDMI_PSRAM_MAGIC_REG       (*(volatile uint32_t *)(HDMI_PSRAM_CFG_BASE + 0x0cu))
#define HDMI_PSRAM_CKPCNT_REG      (*(volatile uint32_t *)(HDMI_PSRAM_CFG_BASE + 0x10u))
#define HDMI_PSRAM_BYTES_REG       (*(volatile uint32_t *)(HDMI_PSRAM_CFG_BASE + 0x14u))
#define HDMI_PSRAM_PHYS_BYTES_REG  (*(volatile uint32_t *)(HDMI_PSRAM_CFG_BASE + 0x18u))
#define HDMI_PSRAM_CTRL_REG        (*(volatile uint32_t *)(HDMI_PSRAM_CFG_BASE + 0x1cu))

#define HDMI_PSRAM_MAGIC_EXPECTED  0x48505331u /* ASCII "HPS1" */

/* HDMI_PSRAM_STATUS_REG bits; bits [31:6] read as zero. */
#define HDMI_PSRAM_INIT_DONE       (1u << 0) /* both dies completed PHY init */
#define HDMI_PSRAM_PHY_BUSY        (1u << 1) /* PSRAM bridge/switcher path busy */
#define HDMI_PSRAM_DIE0_READY      (1u << 2) /* physical die 0 initialized */
#define HDMI_PSRAM_DIE1_READY      (1u << 3) /* physical die 1 initialized */
#define HDMI_PSRAM_GPU_ACTIVE      (1u << 4) /* GPU job/burst owns BACK path */
#define HDMI_PSRAM_HDMI_ACTIVE     (1u << 5) /* HDMI burst owns FRONT path */

/* HDMI_PSRAM_CTRL_REG bits. */
#define HDMI_PSRAM_ENABLE          (1u << 0) /* 1 = enable HDMI reader/output */

/* Return nonzero only after BOTH physical dies have completed power-up init. */
int HDMI_PSRAM_Ready(void);

/*
 * Busy-wait until HDMI_PSRAM_Ready() becomes true and return the number of
 * polling iterations. There is deliberately no timeout; the returned value
 * is a loop count, not microseconds.
 */
uint32_t HDMI_PSRAM_WaitReady(void);

/*
 * Select rPLL phase tap phase&15 immediately. This is a low-level bring-up
 * hook; normal firmware uses characterized tap 5 and should not change it.
 */
void HDMI_PSRAM_SetPhase(uint32_t phase);

/* Enable HDMI framebuffer reads. Initialize both physical framebuffers first. */
void HDMI_PSRAM_Enable(void);

#endif /* GW1NR9_RV32_HDMI_PSRAM_H */
