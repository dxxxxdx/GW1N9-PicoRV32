//
// PSRAM 低速口 bring-up
//
// 上一版把 msg[] 声明成了 `PSRAM unsigned char msg[6]`，也就是放进了 .psram
// 段（0x02000000）。于是"要打印的内容"本身就来自还没校准的 PSRAM，串口上
// 自然全是乱码 —— 那不是 UART 的问题。
//
// 这一版把缓冲区放回普通 BSRAM，先做真正的对齐扫描：
//   rdLat / wrLat 是"CA 结束之后 FSM 额外等几拍才进数据段"，代码里给的默认值
//   是按 CR0 固定延迟 6 拍推出来的，真机上必须扫。
//

#include "PSRAM.h"
#include "UART.h"
#include "IRQ.h"

/* 必须放 BSRAM：PSRAM 没调好之前，连"要打印什么"都读不出来。 */
static uint8_t msg[6];

/* 扫描用的图案。地址 0 对齐到 128 字节，不会跨 burst 边界。 */
#define PATTERN 0x12345678u

static void PrintStatus(void)
{
    uint32_t status = PSRAM_STATUS_REG;

    UART_CStr("STATUS = 0x");
    UART_Hex32(status);
    UART_CStr("  initDone=");
    UART_UInt(status & PSRAM_STATUS_INIT_DONE);
    UART_CStr(" phyBusy=");
    UART_UInt((status >> 1) & 1u);
    UART_CStr("\r\n");
}

static void ScanLatency(void)
{
    uint32_t total = 0u;
    uint32_t cp;
    uint32_t rd;
    uint32_t wr;

    /*
     * 三个旋钮里 CK 相位最要紧：rdLat 只能挪整拍，相位不对时怎么挪都对不上。
     * 所以外层扫相位，内层扫两个延迟。
     *
     * 相位改的是 rPLL 的 PSDA 输入，只影响 CLKOUTP（PSRAM 的 CK），
     * 不影响 CPU 跑的 CLKOUT，所以中途改相位不会把核弄死。
     */
    for (cp = 0u; cp < 16u; ++cp) {
        uint32_t hits = 0u;

        PSRAM_SetCkPhase(cp);
        for (volatile int d = 0; d < 5000; ++d) {
        }

        UART_CStr("ckp=");
        UART_UInt(PSRAM_GetCkPhase());
        UART_CStr(" ");

        for (wr = 0u; wr < 64u; ++wr) {
            for (rd = 0u; rd < 64u; ++rd) {
                PSRAM_SetLatency(rd, wr);
                PSRAM_U32[0] = PATTERN;
                if (PSRAM_U32[0] == PATTERN) {
                    ++hits;
                    if (hits <= 2u) {
                        UART_CStr("OK(rd=");
                        UART_UInt(rd);
                        UART_CStr(",wr=");
                        UART_UInt(wr);
                        UART_CStr(") ");
                    }
                }
            }
        }

        UART_CStr("hits=");
        UART_UInt(hits);
        UART_CStr("\r\n");

        total += hits;
    }

    UART_CStr("total=");
    UART_UInt(total);
    UART_CStr("\r\n");
}

int main(void)
{
    IRQ_Init();
    IRQ_Enable(IRQ_CH0);

    UART_CStr("\r\n=== PSRAM bring-up ===\r\n");
    /* 版本戳：位流和固件各一个，对不上就别往下看数据了 */
    UART_CStr("fw v9 / cr0-write-readback\r\n");
    UART_CStr("BSMAGIC = 0x");
    UART_Hex32(PSRAM_MAGIC_REG);
    UART_CStr("  expect 0x");
    UART_Hex32(PSRAM_MAGIC_EXPECTED);
    UART_CStr((PSRAM_MAGIC_REG == PSRAM_MAGIC_EXPECTED) ? "  OK\r\n"
                                                         : "  <<< 旧位流!\r\n");
    PrintStatus();

    /* 探针 1：clk_p（PSRAM CK 的源时钟）到底有没有在跑。
     * 读两次，变了才说明 PLL 的 CLKOUTP 是活的；一直不变就是 CK 没出去，
     * 那 CA 再对也没用。 */
    {
        uint32_t a = PSRAM_CKPCNT_REG;
        for (volatile int d = 0; d < 2000; ++d) {
        }
        uint32_t b = PSRAM_CKPCNT_REG;
        UART_CStr("CKPCNT a=0x");
        UART_Hex32(a);
        UART_CStr(" b=0x");
        UART_Hex32(b);
        UART_CStr((a != b) ? "  CLK_P ALIVE\r\n" : "  <<< CLK_P DEAD!\r\n");
    }

    /* 探针 2：读 CR0。器件正常应答时应该是 0x8F8FEFEF（两个 die 各回 0x8FEF）。
     * 全 0 / 全 F 就是器件压根没答应。 */
    UART_CStr("CR0 sweep rd=0..63 (want 0x8FA28FA2 或 0x8FEF8FEF):\r\n");
    for (uint32_t rd = 0u; rd < 64u; ++rd) {
        uint32_t got;
        PSRAM_SetLatency(rd, 4u);
        PSRAM_ReadCR0();
        for (volatile int d = 0; d < 500; ++d) {
        }
        got = PSRAM_REGRD_DATA_REG;
        if (got != 0u && got != 0xFFFFFFFFu) {
            UART_CStr("  rd=");
            UART_UInt(rd);
            UART_CStr(" -> 0x");
            UART_Hex32(got);
            UART_CStr("\r\n");
        }
    }
    UART_CStr("(only non-0 / non-F shown)\r\n");

    /* 先把 DQ 原始读数打出来：ckp=0 固定，rd 逐值扫。
     * 这 16 行就是一次读事务的 DQ 时间线，能直接看出器件有没有响应。 */
    PSRAM_SetCkPhase(0);
    PSRAM_SetLatency(6, 4);
    /* 决定性实验：写几个不同的合法 CR0 值，看回读跟不跟着变。
     * 跟着变 -> 写+读链路通，只是之前写的值不对；
     * 不变   -> 写根本没进去（或读的不是 CR0）。 */
    {
        static const uint16_t kCr0[] = {0x8FEFu, 0x8F2Fu, 0x8F0Fu, 0x8FFFu};
        UART_CStr("CR0 write -> read @ckp=4 rd=20:\r\n");
        PSRAM_SetCkPhase(4u);
        for (unsigned i = 0u; i < 4u; ++i) {
            PSRAM_WriteCR0(kCr0[i]);
            for (volatile int d = 0; d < 800; ++d) {
            }
            PSRAM_SetLatency(20u, 4u);
            PSRAM_ReadCR0();
            for (volatile int d = 0; d < 800; ++d) {
            }
            UART_CStr("  wr=0x");
            UART_Hex32(kCr0[i]);
            UART_CStr(" -> rd=0x");
            UART_Hex32(PSRAM_REGRD_DATA_REG);
            UART_CStr("\r\n");
        }
    }

    /* 关键实验：在"已经能采到确定值"的采样点上单独扫 CK 相位。
     * 之前的 ckp 扫描要求整条写+读链路同时对上，太苛刻；这里只动相位，
     * 采样点固定在 rd=20（CR0 扫描里 0x8FA2 反复出现的位置）。 */
    UART_CStr("ckp sweep, CR0 @rd=20 (want 0x8FEF8FEF):\r\n");
    for (uint32_t ckp = 0u; ckp < 16u; ++ckp) {
        PSRAM_SetCkPhase(ckp);
        for (volatile int d = 0; d < 2000; ++d) {
        }
        PSRAM_SetLatency(20u, 4u);
        PSRAM_ReadCR0();
        for (volatile int d = 0; d < 500; ++d) {
        }
        UART_CStr("  ckp=");
        UART_UInt(ckp);
        UART_CStr(" -> 0x");
        UART_Hex32(PSRAM_REGRD_DATA_REG);
        UART_CStr("\r\n");
    }

    UART_CStr("ckp sweep, mem read @rd=16 (want 0x12345678):\r\n");
    for (uint32_t ckp = 0u; ckp < 16u; ++ckp) {
        uint32_t got;
        PSRAM_SetCkPhase(ckp);
        for (volatile int d = 0; d < 2000; ++d) {
        }
        PSRAM_SetLatency(16u, 4u);
        PSRAM_U32[0] = PATTERN;
        got = PSRAM_U32[0];
        UART_CStr("  ckp=");
        UART_UInt(ckp);
        UART_CStr(" -> 0x");
        UART_Hex32(got);
        UART_CStr((got == PATTERN) ? "  <<< MATCH\r\n" : "\r\n");
    }

    PSRAM_SetCkPhase(4u);

    UART_CStr("scan ckp x rd x wr:\r\n");
    ScanLatency();

    UART_CStr("done\r\n");

    /* 心跳：确认 main 之后核还活着，顺便覆盖 UART_String 的用法 */
    for (int i = 0; i < 6; ++i)
        msg[i] = '0';
    msg[3] = '\r';
    msg[4] = '\n';

    for (;;) {
        for (volatile int i = 0; i < 400000; ++i) {
        }

        UART_String(msg, 5);

        if (++msg[2] > '9') {
            msg[2] = '0';
            if (++msg[1] > '9') {
                msg[1] = '0';
                if (++msg[0] > '9')
                    msg[0] = '0';
            }
        }
    }
}

const uint8_t ch0msg[] = "CH0 trigged!";
void IRQ_Ch0_Handler(void)
{
    UART_String(ch0msg, 13);
}
