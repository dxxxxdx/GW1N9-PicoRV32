`timescale 1ns / 1ps
`default_nettype none

//------------------------------------------------------------------------------
// psramPhy.v  --  GW1NR-9C 内嵌 PSRAM（HyperRAM 协议）1:1 DDR 物理层
//
// 两个 die 并行，16 根 DQ，每拍 4 字节：
//   tx[31:24] = die2 上升沿   tx[23:16] = die1 上升沿
//   tx[15: 8] = die2 下降沿   tx[ 7: 0] = die1 下降沿
// 接收方向逐位对称（rx[i] 对应 tx[i]），所以 32bit 写进去读出来一定一样。
//
// 一次事务：CA(3拍) -> 等 rdLat/wrLat 拍 -> 数据(len 拍) -> 抬 CS -> 间隔
//
// !!! 关键约束 !!!
// ODDR / IDDR 是 IOB 里的硬资源，一个实例只能推一个 pad，所以 2 个 die 的
// CK / CS / RWDS 必须每根线各自一个 ODDR / IDDR，不能扇出。
//
// !!! 上板必须扫的参数 !!!
// rdLat / wrLat 是"CA 结束之后 FSM 额外等几拍"，不是器件的 tACC。
// 器件固定延迟 = 2 x CR0[7:4]，CR0[7:4]=1110(3拍) 时是 6 拍，对应
// 默认 rdLat=6 / wrLat=4（写方向 ODDR 自带一拍流水，所以少 2）。
// 实际值必须上板扫。
//------------------------------------------------------------------------------
module psramPhy (
    input  wire        clk,          // 80MHz
    input  wire        clk_p,        // 相移时钟，推 CK
    input  wire        reset_n,

    // 命令接口
    input  wire        start,        // 单周期脉冲
    input  wire        wr,           // 1=写 0=读
    input  wire        regWr,        // 1=写 CR0（用固定 CA）
    input  wire        regRd,        // 1=读 CR0（用固定 CA，用来验证器件是否应答）
    input  wire [15:0] regWrData,    // 寄存器写数据：每个 die 各收这个 16bit 值
    input  wire [20:0] wordAddr,     // 16bit 字地址 = 字节地址[21:1]
    input  wire [ 3:0] wmask,        // 1 = 屏蔽该字节（= ~mem_wstrb）
    input  wire [ 6:0] len,          // 数据拍数，1~64
    input  wire [ 5:0] rdLat,        // 读方向额外等待拍数（0~63）
    input  wire [ 5:0] wrLat,        // 写方向额外等待拍数（0~63）
    output wire        busy,
    output reg         done,         // 单周期脉冲
    input  wire [31:0] dIn,          // 写数据，数据阶段每拍取一个
    output wire [31:0] dOut,         // 读数据，数据阶段每拍有效
    output wire        dOutWr,       // 读数据有效

    // PSRAM 物理层（顶层 magic 端口，cst 里不要写）
    output wire [1:0]  O_psram_ck,
    output wire [1:0]  O_psram_ck_n,
    output wire [1:0]  O_psram_cs_n,
    output wire [1:0]  O_psram_reset_n,
    inout  wire [1:0]  IO_psram_rwds,
    inout  wire [15:0] IO_psram_dq
);
    localparam integer GAP_CYCLES = 2;

    // ---------------------------------------------------------------- 状态
    localparam [2:0] S_IDLE = 3'd0,
                     S_CA   = 3'd1,
                     S_LAT  = 3'd2,
                     S_DATA = 3'd3,
                     S_END  = 3'd4,
                     S_GAP  = 3'd5;

    reg  [2:0]  st;
    reg  [1:0]  caPh;
    reg  [6:0]  cnt;
    reg  [47:0] caSr;
    reg  [31:0] txWord;

    reg ckEn;
    reg csN;
    reg dqOen;      // 1 = 高阻（读）
    reg rwdsOen;    // 1 = 高阻
    reg rwds1Ris, rwds1Fal, rwds2Ris, rwds2Fal;

    // ------------------------------------------------------------ CA 构造
    // 48bit，MSB 先发：
    //   [47]    = 1 读 / 0 写
    //   [46]    = 0
    //   [45]    = 1 linear burst（顺序走，不 wrap）
    //   [44:16] = 字地址高位
    //   [15:3]  = 0
    //   [2:0]   = 字地址低位
    wire [47:0] caMem = {~wr, 13'b010_0000_0000_00,
                         wordAddr[20:3], 13'b0, wordAddr[2:0]};
    // 寄存器写：CR0 = 0x8FEF
    //   [15]=1 正常  [14:12]=000 25ohm  [11:9]=111 保留写1  [8]=1
    //   [7:4]=1110 3拍延迟  [3]=1 固定延迟(=6拍)  [1:0]=11 -> 32字节 burst
    wire [47:0] caReg   = 48'h60_00_01_00_00_00;   // 写 CR0
    wire [47:0] caRegRd = 48'hE0_00_01_00_00_00;   // 读 CR0（CA[47]=1 读, CA[46]=1 寄存器空间）
    wire [47:0] ca      = regWr ? caReg : (regRd ? caRegRd : caMem);

    // -------------------------------------------------------- DDR 收发接线
    wire [15:0] dqOutRis = txWord[31:16];
    wire [15:0] dqOutFal = txWord[15: 0];
    wire [15:0] dqInRis;
    wire [15:0] dqInFal;
    wire [31:0] rxWord   = {dqInRis, dqInFal};

    wire rwdsInRis, rwdsInFal;

    assign busy    = (st != S_IDLE);
    assign dOut    = rxWord;
    assign dOutWr  = (st == S_DATA) && !wr;

    assign O_psram_reset_n = {2{reset_n}};
    assign O_psram_ck_n    = 2'b00;      // 单端 CK，CK# 常低

    // ------------------------------------------------------------------ FSM
    always @(posedge clk) begin
        done <= 1'b0;

        if (!reset_n) begin
            st       <= S_IDLE;
            caPh     <= 2'd0;
            cnt      <= 7'd0;
            caSr     <= 48'd0;
            txWord   <= 32'd0;
            ckEn     <= 1'b0;
            csN      <= 1'b1;
            dqOen    <= 1'b1;
            rwdsOen  <= 1'b1;
            rwds1Ris <= 1'b1; rwds1Fal <= 1'b1;
            rwds2Ris <= 1'b1; rwds2Fal <= 1'b1;
        end else begin
            case (st)

            // ---------------------------------------------------------- 空闲
            S_IDLE: begin
                ckEn    <= 1'b0;
                csN     <= 1'b1;
                dqOen   <= 1'b1;
                rwdsOen <= 1'b1;
                if (start) begin
                    caSr    <= ca;
                    caPh    <= 2'd3;
                    // CA 第一个 16bit 块：每个 die 各自收同样的两个字节
                    // （上升沿收高字节、下降沿收低字节），所以是"逐字节复制"，
                    // 不是把 16bit 整块复制。写错了两个 die 都只收到半个 CA。
                    txWord  <= {{2{ca[47:40]}}, {2{ca[39:32]}}};
                    csN     <= 1'b0;
                    ckEn    <= 1'b1;
                    dqOen   <= 1'b0;
                    rwdsOen <= 1'b1;                     // CA 期间 RWDS 由器件驱动
                    st      <= S_CA;
                end
            end

            // ------------------------------------------------ CA：3 拍 x 16bit
            S_CA: begin
                caSr   <= {caSr[31:0], 16'd0};
                // 同样逐字节复制：caSr[31:16] 是这一拍的 16bit 块
                txWord <= {{2{caSr[31:24]}}, {2{caSr[23:16]}}};
                caPh   <= caPh - 1'b1;
                if (caPh == 2'd1) begin
                    st  <= S_LAT;
                    cnt <= (wr ? wrLat : rdLat);
                    dqOen    <= wr ? 1'b0 : 1'b1;        // 写驱动 / 读释放
                    rwdsOen  <= wr ? 1'b0 : 1'b1;        // 写驱动掩码 / 读高阻
                    if (wr) begin
                        // RWDS = 数据掩码，1 = 不写
                        rwds1Ris <= wmask[2];
                        rwds1Fal <= wmask[0];
                        rwds2Ris <= wmask[3];
                        rwds2Fal <= wmask[1];
                    end
                end
            end

            // -------------------------------------------------------- 等延迟
            S_LAT: begin
                if (cnt <= 7'd1) begin
                    st  <= S_DATA;
                    cnt <= {1'b0, len} - 7'd1;
                    // 寄存器写：每个 die 各自收 RG[15:8] 然后 RG[7:0]，
                    // 所以是"逐字节复制"给两个 die
                    if (wr) txWord <= regWr ? {{2{regWrData[15:8]}}, {2{regWrData[7:0]}}} : dIn;
                end else begin
                    cnt <= cnt - 7'd1;
                end
            end

            // ---------------------------------------------------- 数据：len 拍
            S_DATA: begin
                if (wr) txWord <= regWr ? {{2{regWrData[15:8]}}, {2{regWrData[7:0]}}} : dIn;
                if (cnt == 7'd0) st <= S_END;
                else             cnt <= cnt - 7'd1;
            end

            // ------------------------------------------------------------ 收尾
            S_END: begin
                csN     <= 1'b1;
                ckEn    <= 1'b0;
                dqOen   <= 1'b1;
                rwdsOen <= 1'b1;
                txWord  <= 32'd0;
                done    <= 1'b1;
                cnt     <= GAP_CYCLES[6:0];
                st      <= S_GAP;
            end

            // ------------------------------------------------------ 事务间隔
            S_GAP: begin
                if (cnt == 7'd0) st <= S_IDLE;
                else             cnt <= cnt - 7'd1;
            end

            default: st <= S_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------ PHY
    genvar i;

    // CK：每根一个 ODDR，用相移时钟拼 50% 方波。
    //
    // !!! CK 必须常开，不能门控 !!!
    // 原来 D0 接 ckEn（只在事务期间拉高），但 ODDR 有流水延迟，CK 会比
    // CS/CA 晚起一两拍 —— 器件第一拍 CA 就丢了，命令直接作废，表现就是
    // "器件完全不应答"。内存时钟本来就该一直跑，常开还能省掉这个不确定性。
    generate
        for (i = 0; i < 2; i = i + 1) begin : g_ck
            wire ckTbuf;
            ODDR oddrCk (
                .CLK (clk_p),
                .D0  (1'b1),
                .D1  (1'b0),
                .TX  (1'b0),
                .Q0  (ckTbuf)
            );
            assign O_psram_ck[i] = ckTbuf;
        end
    endgenerate

    // CS：两个 die 一起选（16bit 并行访问）
    generate
        for (i = 0; i < 2; i = i + 1) begin : g_cs
            wire csTbuf;
            ODDR oddrCs (
                .CLK (clk),
                .D0  (csN),
                .D1  (csN),
                .TX  (1'b0),
                .Q0  (csTbuf)
            );
            assign O_psram_cs_n[i] = csTbuf;
        end
    endgenerate

    // RWDS：写数据阶段输出掩码，其余时间高阻
    generate
        for (i = 0; i < 2; i = i + 1) begin : g_rwds
            wire rwdsTbuf, rwdsOenTbuf;
            ODDR oddrRwds (
                .CLK (clk),
                .D0  (i == 0 ? rwds1Ris : rwds2Ris),
                .D1  (i == 0 ? rwds1Fal : rwds2Fal),
                .TX  (rwdsOen),
                .Q0  (rwdsTbuf),
                .Q1  (rwdsOenTbuf)
            );
            assign IO_psram_rwds[i] = rwdsOenTbuf ? 1'bz : rwdsTbuf;
        end
    endgenerate

    IDDR iddrRwds0 (.CLK(clk), .D(IO_psram_rwds[0]), .Q0(rwdsInRis), .Q1(rwdsInFal));

    // DQ：16 根，每根一个 ODDR 出 + 一个 IDDR 入
    generate
        for (i = 0; i < 16; i = i + 1) begin : g_dq
            wire dqTbuf, dqOenTbuf;
            ODDR oddrDq (
                .CLK (clk),
                .D0  (dqOutRis[i]),
                .D1  (dqOutFal[i]),
                .TX  (dqOen),
                .Q0  (dqTbuf),
                .Q1  (dqOenTbuf)
            );
            assign IO_psram_dq[i] = dqOenTbuf ? 1'bz : dqTbuf;

            IDDR iddrDq (
                .CLK (clk),
                .D   (IO_psram_dq[i]),
                .Q0  (dqInRis[i]),
                .Q1  (dqInFal[i])
            );
        end
    endgenerate

    // RWDS 输入路径这里没参与数据判断（用固定延迟），但保留连线避免被裁掉。
    wire unusedRwds = rwdsInRis ^ rwdsInFal;

endmodule

`default_nettype wire
