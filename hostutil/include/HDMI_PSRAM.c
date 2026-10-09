#include "HDMI_PSRAM.h"

/* INIT_DONE is the AND of die0-ready and die1-ready inside the controller. */
int HDMI_PSRAM_Ready(void)
{
    return (HDMI_PSRAM_STATUS_REG & HDMI_PSRAM_INIT_DONE) != 0u;
}

/* Boot-time blocking helper. A board/clock failure intentionally stalls here. */
uint32_t HDMI_PSRAM_WaitReady(void)
{
    uint32_t spin = 0u;
    while (!HDMI_PSRAM_Ready())
        ++spin;
    return spin;
}

/* Hardware implements 16 phase taps, so only the low four bits are meaningful. */
void HDMI_PSRAM_SetPhase(uint32_t phase)
{
    HDMI_PSRAM_PHASE_REG = phase & 15u;
}

/* HDMI starts disabled after reset so software can initialize both framebuffers. */
void HDMI_PSRAM_Enable(void)
{
    HDMI_PSRAM_CTRL_REG = HDMI_PSRAM_ENABLE;
}
