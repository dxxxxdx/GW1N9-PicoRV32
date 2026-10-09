// HDMI framebuffer and GW1NR-9C embedded-PSRAM interface.
#ifndef GW1NR9_RV32_HDMI_PSRAM_H
#define GW1NR9_RV32_HDMI_PSRAM_H

#include <stdint.h>

#define HDMI_WIDTH                 640u
#define HDMI_HEIGHT                480u
#define HDMI_FRAME_BYTES           (HDMI_WIDTH * HDMI_HEIGHT * 2u)

#define HDMI_PSRAM_BASE            0x02000000u
#define HDMI_PSRAM_SIZE            0x00400000u
#define HDMI_PSRAM_PHYSICAL_SIZE   0x00800000u

// Objects in this NOLOAD section are not initialized by the startup code.
#define HDMI_PSRAM_SECTION __attribute__((section(".psram"), aligned(4)))

extern uint8_t __psram_base[];
extern uint8_t __psram_limit[];
extern uint8_t __psram_start[];
extern uint8_t __psram_end[];

#define HDMI_PSRAM_U32 ((volatile uint32_t *)HDMI_PSRAM_BASE)
#define HDMI_PSRAM_U16 ((volatile uint16_t *)HDMI_PSRAM_BASE)
#define HDMI_PSRAM_U8  ((volatile uint8_t  *)HDMI_PSRAM_BASE)

#define HDMI_PSRAM_CFG_BASE        0x03000000u
#define HDMI_PSRAM_INFO_REG        (*(volatile uint32_t *)(HDMI_PSRAM_CFG_BASE + 0x00u))
#define HDMI_PSRAM_STATUS_REG      (*(volatile uint32_t *)(HDMI_PSRAM_CFG_BASE + 0x04u))
#define HDMI_PSRAM_PHASE_REG       (*(volatile uint32_t *)(HDMI_PSRAM_CFG_BASE + 0x08u))
#define HDMI_PSRAM_MAGIC_REG       (*(volatile uint32_t *)(HDMI_PSRAM_CFG_BASE + 0x0cu))
#define HDMI_PSRAM_CKPCNT_REG      (*(volatile uint32_t *)(HDMI_PSRAM_CFG_BASE + 0x10u))
#define HDMI_PSRAM_BYTES_REG       (*(volatile uint32_t *)(HDMI_PSRAM_CFG_BASE + 0x14u))
#define HDMI_PSRAM_PHYS_BYTES_REG  (*(volatile uint32_t *)(HDMI_PSRAM_CFG_BASE + 0x18u))
#define HDMI_PSRAM_CTRL_REG        (*(volatile uint32_t *)(HDMI_PSRAM_CFG_BASE + 0x1cu))

#define HDMI_PSRAM_MAGIC_EXPECTED  0x48505331u // "HPS1"
#define HDMI_PSRAM_INIT_DONE       (1u << 0)
#define HDMI_PSRAM_PHY_BUSY        (1u << 1)
#define HDMI_PSRAM_DIE0_READY      (1u << 2)
#define HDMI_PSRAM_DIE1_READY      (1u << 3)
#define HDMI_PSRAM_GPU_ACTIVE      (1u << 4)
#define HDMI_PSRAM_HDMI_ACTIVE     (1u << 5)
#define HDMI_PSRAM_ENABLE          (1u << 0)

int HDMI_PSRAM_Ready(void);
uint32_t HDMI_PSRAM_WaitReady(void);
void HDMI_PSRAM_SetPhase(uint32_t phase);
void HDMI_PSRAM_Enable(void);

#endif
