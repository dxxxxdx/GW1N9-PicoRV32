#include "SwapController.h"

/* STATUS stores the physical die number directly in each role bit. */
uint32_t SwapController_GetBackDie(void)
{
    return (SWAP_CONTROLLER_STATUS_REG & SWAP_STATUS_BACK_DIE) != 0u;
}

uint32_t SwapController_GetFrontDie(void)
{
    return (SWAP_CONTROLLER_STATUS_REG & SWAP_STATUS_FRONT_DIE) != 0u;
}

uint32_t SwapController_GetCount(void)
{
    return SWAP_CONTROLLER_STATUS_REG >> SWAP_STATUS_COUNT_SHIFT;
}

/* Bit 0 becomes a pulse in the 80 MHz PSRAM clock domain. */
void SwapController_Request(void)
{
    SWAP_CONTROLLER_CTRL_REG = SWAP_REQUEST;
}

/* One write generates both request and synthetic frame-done pulses. */
void SwapController_BootRequest(void)
{
    SWAP_CONTROLLER_CTRL_REG = SWAP_REQUEST | SWAP_SOFT_FRAME_DONE;
}

/* A count change is the software-visible commit point of the mapping flip. */
static int wait_for_swap(uint32_t before, uint32_t timeout)
{
    for (uint32_t i = 0u; i < timeout; ++i)
        if (SwapController_GetCount() != before)
            return 1;
    return 0;
}

int SwapController_SwapBeforeHDMI(uint32_t timeout)
{
    uint32_t before = SwapController_GetCount();
    SwapController_BootRequest();
    return wait_for_swap(before, timeout);
}

int SwapController_SwapAtHDMIFrame(uint32_t timeout)
{
    uint32_t before = SwapController_GetCount();
    SwapController_Request();
    return wait_for_swap(before, timeout);
}

int SwapController_SelectBackBeforeHDMI(uint32_t die, uint32_t timeout)
{
    die &= 1u;
    if (SwapController_GetBackDie() == die)
        return 1;
    if (!SwapController_SwapBeforeHDMI(timeout))
        return 0;
    return SwapController_GetBackDie() == die;
}
