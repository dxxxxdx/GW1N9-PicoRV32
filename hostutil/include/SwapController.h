#ifndef GW1NR9_RV32_SWAP_CONTROLLER_H
#define GW1NR9_RV32_SWAP_CONTROLLER_H

#include <stdint.h>

#define SWAP_CONTROLLER_BASE       0x03001000u
#define SWAP_CONTROLLER_MAGIC_REG  (*(volatile uint32_t *)(SWAP_CONTROLLER_BASE + 0x00u))
#define SWAP_CONTROLLER_STATUS_REG (*(volatile uint32_t *)(SWAP_CONTROLLER_BASE + 0x04u))
#define SWAP_CONTROLLER_CTRL_REG   (*(volatile uint32_t *)(SWAP_CONTROLLER_BASE + 0x08u))

#define SWAP_CONTROLLER_MAGIC_EXPECTED 0x53575031u // "SWP1"
#define SWAP_STATUS_PENDING        (1u << 0)
#define SWAP_STATUS_FRONT_DIE      (1u << 1)
#define SWAP_STATUS_BACK_DIE       (1u << 2)
#define SWAP_STATUS_HDMI_REQUEST   (1u << 3)
#define SWAP_REQUEST               (1u << 0)
#define SWAP_SOFT_FRAME_DONE       (1u << 1)

uint32_t SwapController_GetBackDie(void);
uint32_t SwapController_GetFrontDie(void);
uint32_t SwapController_GetCount(void);
void SwapController_Request(void);
void SwapController_BootRequest(void);
int SwapController_SwapBeforeHDMI(uint32_t timeout);
int SwapController_SwapAtHDMIFrame(uint32_t timeout);
int SwapController_SelectBackBeforeHDMI(uint32_t die, uint32_t timeout);

#endif
