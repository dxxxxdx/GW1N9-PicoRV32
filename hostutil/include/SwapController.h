/*
 * PSRAM front/back role switcher.
 *
 * HDMI exclusively reads the logical FRONT die. CPU and rectangle GPU share
 * the logical BACK die. A completed swap changes only this routing; no memory
 * is copied. Hardware drains accepted traffic before changing the mapping.
 */
#ifndef GW1NR9_RV32_SWAP_CONTROLLER_H
#define GW1NR9_RV32_SWAP_CONTROLLER_H

#include <stdint.h>

/*
 * Swap-controller page: 0x0300_1000..0x0300_1fff.
 *
 * +0x00 MAGIC  R   Page/version signature 0x53575031 (ASCII "SWP1").
 * +0x04 STATUS R   bits [31:16] completed-swap counter (wraps at 65536)
 *                  bit 3  request level currently presented to HDMI
 *                  bit 2  physical die number currently used as BACK
 *                  bit 1  physical die number currently used as FRONT
 *                  bit 0  swap pending
 *                  bits [15:4] are zero. FRONT and BACK are complementary.
 * +0x08 CTRL   W   bit 0 queues a swap request
 *                  bit 1 injects a software frame-done event
 *                  other bits are ignored; reads return zero.
 *
 * CTRL writes require byte lane 0. Requests are not queued by count: another
 * bit-0 write while one swap is pending still represents the same pending swap.
 */
#define SWAP_CONTROLLER_BASE       0x03001000u
#define SWAP_CONTROLLER_MAGIC_REG  (*(volatile uint32_t *)(SWAP_CONTROLLER_BASE + 0x00u))
#define SWAP_CONTROLLER_STATUS_REG (*(volatile uint32_t *)(SWAP_CONTROLLER_BASE + 0x04u))
#define SWAP_CONTROLLER_CTRL_REG   (*(volatile uint32_t *)(SWAP_CONTROLLER_BASE + 0x08u))

#define SWAP_CONTROLLER_MAGIC_EXPECTED 0x53575031u /* ASCII "SWP1" */

/* SWAP_CONTROLLER_STATUS_REG bits. */
#define SWAP_STATUS_PENDING        (1u << 0) /* request accepted, not completed */
#define SWAP_STATUS_FRONT_DIE      (1u << 1) /* 0 = die0, 1 = die1 */
#define SWAP_STATUS_BACK_DIE       (1u << 2) /* 0 = die0, 1 = die1 */
#define SWAP_STATUS_HDMI_REQUEST   (1u << 3) /* same pending request sent to HDMI */
#define SWAP_STATUS_COUNT_SHIFT    16u

/* SWAP_CONTROLLER_CTRL_REG write bits. */
#define SWAP_REQUEST               (1u << 0) /* request mapping flip */
#define SWAP_SOFT_FRAME_DONE       (1u << 1) /* synthesize frame boundary */

/* Return the physical die number (0 or 1) currently mapped as logical BACK. */
uint32_t SwapController_GetBackDie(void);

/* Return the physical die number (0 or 1) currently mapped as logical FRONT. */
uint32_t SwapController_GetFrontDie(void);

/* Return the low 16-bit completed-swap count, zero-extended to uint32_t. */
uint32_t SwapController_GetCount(void);

/*
 * Queue a swap for a real HDMI frame boundary and return immediately. Once
 * that boundary arrives, CPU/HDMI traffic is held, an in-flight GPU job may
 * finish all of its bursts, and the roles flip only after both dies drain.
 */
void SwapController_Request(void);

/*
 * Request a swap and inject a frame boundary in the same MMIO write. Use only
 * during boot while HDMI is disabled; it exists so software can initialize or
 * test both physical dies through the single logical BACK window.
 */
void SwapController_BootRequest(void);

/*
 * Pre-HDMI blocking swap using a synthetic frame boundary. timeout is a CPU
 * polling-iteration count. Returns 1 on completion, 0 on timeout.
 * A timeout does NOT cancel the already-issued hardware request.
 */
int SwapController_SwapBeforeHDMI(uint32_t timeout);

/*
 * Request a production swap at the next real HDMI frame boundary and wait for
 * its completion. timeout is a polling-iteration count, not a time unit.
 * Returns 1 on completion, 0 on timeout; timeout does not cancel the request.
 */
int SwapController_SwapAtHDMIFrame(uint32_t timeout);

/*
 * While HDMI is disabled, make physical die (die&1) the logical BACK die.
 * Returns 1 if selected (including already selected), otherwise 0 on timeout.
 */
int SwapController_SelectBackBeforeHDMI(uint32_t die, uint32_t timeout);

#endif /* GW1NR9_RV32_SWAP_CONTROLLER_H */
