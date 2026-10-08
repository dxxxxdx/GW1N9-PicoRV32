// GW1NR-9C embedded PSRAM support
//
// 0x0200_0000 .. 0x023f_ffff : 4 MiB logical back-die window
// 0x0300_0000 .. 0x0300_0fff : diagnostics, phase and frame-swap control

#ifndef GW1NR9_RV32_PSRAM_H
#define GW1NR9_RV32_PSRAM_H

#include <stdint.h>

typedef uint8_t  u8;
typedef uint16_t u16;
typedef uint32_t u32;

#define PSRAM_BASE 0x02000000u
#define PSRAM_SIZE          0x00400000u
#define PSRAM_PHYSICAL_SIZE 0x00800000u

// Objects in this NOLOAD section are not initialized by the startup code.
#define PSRAM __attribute__((section(".psram"), aligned(4)))

extern uint8_t __psram_base[];
extern uint8_t __psram_limit[];
extern uint8_t __psram_start[];
extern uint8_t __psram_end[];

#define PSRAM_U32 ((volatile uint32_t *)PSRAM_BASE)
#define PSRAM_U16 ((volatile uint16_t *)PSRAM_BASE)
#define PSRAM_U8  ((volatile uint8_t  *)PSRAM_BASE)

#define PSRAM_CFG_BASE    0x03000000u
#define PSRAM_INFO_REG    (*(volatile uint32_t *)(PSRAM_CFG_BASE + 0x00u))
#define PSRAM_STATUS_REG  (*(volatile uint32_t *)(PSRAM_CFG_BASE + 0x04u))
#define PSRAM_PHASE_REG   (*(volatile uint32_t *)(PSRAM_CFG_BASE + 0x08u))
#define PSRAM_MAGIC_REG   (*(volatile uint32_t *)(PSRAM_CFG_BASE + 0x0cu))
#define PSRAM_CKPCNT_REG  (*(volatile uint32_t *)(PSRAM_CFG_BASE + 0x10u))
#define PSRAM_BYTES_REG   (*(volatile uint32_t *)(PSRAM_CFG_BASE + 0x14u))
#define PSRAM_SWAP_REG    (*(volatile uint32_t *)(PSRAM_CFG_BASE + 0x18u))
#define PSRAM_PHYS_BYTES_REG (*(volatile uint32_t *)(PSRAM_CFG_BASE + 0x1cu))
#define PSRAM_HDMI_CTRL_REG (*(volatile uint32_t *)(PSRAM_CFG_BASE + 0x20u))

#define PSRAM_MAGIC_EXPECTED     0x50534231u  // "PSB1": burst-port ABI v1
#define PSRAM_STATUS_INIT_DONE   (1u << 0)
#define PSRAM_STATUS_PHY_BUSY    (1u << 1)
#define PSRAM_STATUS_DIE0_READY  (1u << 2)
#define PSRAM_STATUS_DIE1_READY  (1u << 3)
#define PSRAM_STATUS_SWAP_PENDING (1u << 4)
#define PSRAM_STATUS_FRONT_DIE    (1u << 5)
#define PSRAM_STATUS_BACK_DIE     (1u << 6)
#define PSRAM_STATUS_GPU_ACTIVE   (1u << 7)
#define PSRAM_STATUS_HDMI_ACTIVE  (1u << 8)

#define PSRAM_SWAP_REQUEST        (1u << 0)
#define PSRAM_SWAP_SOFT_FRAME_DONE (1u << 1)
#define PSRAM_SWAP_PENDING        (1u << 0)
#define PSRAM_SWAP_FRONT_DIE      (1u << 1)
#define PSRAM_SWAP_BACK_DIE       (1u << 2)
#define PSRAM_SWAP_HDMI_REQUEST   (1u << 3)
#define PSRAM_HDMI_ENABLE          (1u << 0)

static inline int PSRAM_Ready(void)
{
    return (PSRAM_STATUS_REG & PSRAM_STATUS_INIT_DONE) != 0u;
}

static inline uint32_t PSRAM_WaitReady(void)
{
    uint32_t spin = 0u;
    while (!PSRAM_Ready())
        ++spin;
    return spin;
}

// Change the PSRAM CK phase while no data transaction is active.  The rPLL has
// 16 taps per cycle; the measured 2..7 pass window selects tap 5 by default.
static inline void PSRAM_SetPhase(uint32_t phase)
{
    PSRAM_PHASE_REG = phase & 15u;
}

static inline uint32_t PSRAM_GetBackDie(void)
{
    return (PSRAM_SWAP_REG & PSRAM_SWAP_BACK_DIE) != 0u;
}

static inline uint32_t PSRAM_GetSwapCount(void)
{
    return PSRAM_SWAP_REG >> 16;
}

// Production path: request now, then HDMI supplies the real frame-done event.
static inline void PSRAM_RequestSwap(void)
{
    PSRAM_SWAP_REG = PSRAM_SWAP_REQUEST;
}

// Bring-up path before HDMI exists: request and inject a safe frame boundary.
static inline void PSRAM_TestSwap(void)
{
    PSRAM_SWAP_REG = PSRAM_SWAP_REQUEST | PSRAM_SWAP_SOFT_FRAME_DONE;
}

static inline void PSRAM_HDMIEnable(void)
{
    PSRAM_HDMI_CTRL_REG = PSRAM_HDMI_ENABLE;
}

// Writes and verifies words [0, words).  Returns words on success, otherwise
// the index of the first mismatch.
uint32_t PSRAM_TestPattern(uint32_t words);

#endif
