#include "SwapController.h"

/* STATUS 的 FRONT/BACK 位直接保存对应的物理 die 编号。 */
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

/* 位 0 经跨时钟同步后，在 80 MHz PSRAM 时钟域中变成一个请求脉冲。 */
void SwapController_Request(void)
{
    SWAP_CONTROLLER_CTRL_REG = SWAP_REQUEST;
}

/* 一次写入同时产生交换请求脉冲和软件模拟的帧结束脉冲。 */
void SwapController_BootRequest(void)
{
    SWAP_CONTROLLER_CTRL_REG = SWAP_REQUEST | SWAP_SOFT_FRAME_DONE;
}

/* 交换计数发生变化，就是软件可见的“映射已经正式切换”提交点。 */
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
