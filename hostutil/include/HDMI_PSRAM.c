#include "HDMI_PSRAM.h"

/* 控制器内部的 INIT_DONE 等于 die0-ready 与 die1-ready 的逻辑与。 */
int HDMI_PSRAM_Ready(void)
{
    return (HDMI_PSRAM_STATUS_REG & HDMI_PSRAM_INIT_DONE) != 0u;
}

/* 上电阶段使用的阻塞等待；如果板级连线或时钟异常，本函数会有意停在这里。 */
uint32_t HDMI_PSRAM_WaitReady(void)
{
    uint32_t spin = 0u;
    while (!HDMI_PSRAM_Ready())
        ++spin;
    return spin;
}

/* 复位后 HDMI 默认关闭，留给软件先初始化两份帧缓冲。 */
void HDMI_PSRAM_Enable(void)
{
    HDMI_PSRAM_CTRL_REG = HDMI_PSRAM_ENABLE;
}
