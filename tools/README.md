# RV32 UART 程序下载器

运行：

```bash
python3 uart_loader_gui.py
```

操作顺序：

1. 按下并松开 FPGA 板上的 `RESET`。
2. 选择 USB 串口和不超过 16 KiB 的裸 `.bin` 文件。
3. 点击“下载并监听串口”。
4. 下载完成后按下板上的 `START`，程序输出会显示在窗口内。

工具固定使用 115200 baud、8-N-1、无流控，只依赖 Python 标准库和
Tkinter。下载目标是 FPGA 内部的易失性程序 RAM，并非 SPI Flash。
