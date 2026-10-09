#include "HDMI_PSRAM.h"

int HDMI_PSRAM_Ready(void)
{
    return (HDMI_PSRAM_STATUS_REG & HDMI_PSRAM_INIT_DONE) != 0u;
}

uint32_t HDMI_PSRAM_WaitReady(void)
{
    uint32_t spin = 0u;
    while (!HDMI_PSRAM_Ready())
        ++spin;
    return spin;
}

void HDMI_PSRAM_SetPhase(uint32_t phase)
{
    HDMI_PSRAM_PHASE_REG = phase & 15u;
}

void HDMI_PSRAM_Enable(void)
{
    HDMI_PSRAM_CTRL_REG = HDMI_PSRAM_ENABLE;
}
