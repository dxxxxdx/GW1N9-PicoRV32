#!/usr/bin/env python3
"""Tk GUI for loading a raw RV32 binary over the board's UART bridge."""

from __future__ import annotations

import errno
import glob
import os
from pathlib import Path
import queue
import select
import termios
import threading
import tkinter as tk
from tkinter import filedialog, messagebox, ttk


BAUD_RATE = 115_200
MAX_IMAGE_BYTES = 16 * 1024
DEVICE_PATTERNS = ("/dev/ttyACM*", "/dev/ttyUSB*")


def find_serial_devices() -> list[str]:
    """Return the USB serial devices relevant to this board."""
    devices: set[str] = set()
    for pattern in DEVICE_PATTERNS:
        devices.update(glob.glob(pattern))
    return sorted(devices)


def configure_serial_115200_8n1(fd: int) -> None:
    """Put an already opened Linux tty into raw 115200-8-N-1 mode."""
    attrs = termios.tcgetattr(fd)

    # Raw input/output: do not translate bytes or perform software flow control.
    attrs[0] = 0
    attrs[1] = 0

    cflag = attrs[2]
    cflag &= ~(termios.CSIZE | termios.PARENB | termios.CSTOPB)
    if hasattr(termios, "CRTSCTS"):
        cflag &= ~termios.CRTSCTS
    cflag |= termios.CS8 | termios.CREAD | termios.CLOCAL
    attrs[2] = cflag

    # No canonical processing, echo, or signal-character handling.
    attrs[3] = 0
    attrs[4] = termios.B115200
    attrs[5] = termios.B115200
    attrs[6][termios.VMIN] = 0
    attrs[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attrs)


class UartLoaderGui:
    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self.messages: queue.Queue[tuple] = queue.Queue()
        self.stop_event = threading.Event()
        self.worker: threading.Thread | None = None
        self.active = False

        project_dir = Path(__file__).resolve().parent.parent
        default_image = project_dir / "firmware" / "hi.bin"

        root.title("RV32 UART 程序下载器")
        root.minsize(680, 480)
        root.columnconfigure(0, weight=1)
        root.rowconfigure(0, weight=1)

        outer = ttk.Frame(root, padding=14)
        outer.grid(row=0, column=0, sticky="nsew")
        outer.columnconfigure(1, weight=1)
        outer.rowconfigure(6, weight=1)

        ttk.Label(outer, text="串口设备").grid(
            row=0, column=0, padx=(0, 8), pady=5, sticky="w"
        )
        self.device_var = tk.StringVar()
        self.device_box = ttk.Combobox(
            outer, textvariable=self.device_var, state="normal"
        )
        self.device_box.grid(row=0, column=1, pady=5, sticky="ew")
        self.refresh_button = ttk.Button(
            outer, text="刷新", command=self.refresh_devices
        )
        self.refresh_button.grid(row=0, column=2, padx=(8, 0), pady=5)

        ttk.Label(outer, text="程序镜像").grid(
            row=1, column=0, padx=(0, 8), pady=5, sticky="w"
        )
        self.image_var = tk.StringVar(
            value=str(default_image) if default_image.is_file() else ""
        )
        self.image_entry = ttk.Entry(outer, textvariable=self.image_var)
        self.image_entry.grid(row=1, column=1, pady=5, sticky="ew")
        self.browse_button = ttk.Button(
            outer, text="选择…", command=self.choose_image
        )
        self.browse_button.grid(row=1, column=2, padx=(8, 0), pady=5)

        ttk.Label(outer, text="串口格式").grid(
            row=2, column=0, padx=(0, 8), pady=5, sticky="w"
        )
        ttk.Label(outer, text="115200 baud，8-N-1，无流控").grid(
            row=2, column=1, columnspan=2, pady=5, sticky="w"
        )

        self.progress = ttk.Progressbar(outer, mode="determinate", maximum=100)
        self.progress.grid(row=3, column=0, columnspan=3, pady=(10, 4), sticky="ew")

        button_row = ttk.Frame(outer)
        button_row.grid(row=4, column=0, columnspan=3, pady=8, sticky="ew")
        button_row.columnconfigure(0, weight=1)
        self.download_button = ttk.Button(
            button_row, text="下载并监听串口", command=self.start_download
        )
        self.download_button.grid(row=0, column=0, sticky="ew")
        self.disconnect_button = ttk.Button(
            button_row, text="断开", command=self.disconnect, state="disabled"
        )
        self.disconnect_button.grid(row=0, column=1, padx=(8, 0))

        self.status_var = tk.StringVar(value="先按一下板上 RESET，再点击下载。")
        ttk.Label(outer, textvariable=self.status_var).grid(
            row=5, column=0, columnspan=3, pady=(0, 8), sticky="w"
        )

        log_frame = ttk.LabelFrame(outer, text="串口输出 / 操作日志", padding=6)
        log_frame.grid(row=6, column=0, columnspan=3, sticky="nsew")
        log_frame.columnconfigure(0, weight=1)
        log_frame.rowconfigure(0, weight=1)
        self.log = tk.Text(log_frame, height=15, wrap="char", state="disabled")
        self.log.grid(row=0, column=0, sticky="nsew")
        scrollbar = ttk.Scrollbar(log_frame, orient="vertical", command=self.log.yview)
        scrollbar.grid(row=0, column=1, sticky="ns")
        self.log.configure(yscrollcommand=scrollbar.set)

        hint = (
            "流程：按 RESET → 点击“下载并监听串口” → 提示完成后按 START。"
            "下载的是易失性程序 RAM，重新复位后需要再次下载。"
        )
        ttk.Label(outer, text=hint, wraplength=640).grid(
            row=7, column=0, columnspan=3, pady=(10, 0), sticky="w"
        )

        self.refresh_devices()
        self.root.after(50, self.poll_messages)
        self.root.protocol("WM_DELETE_WINDOW", self.close_window)

    def refresh_devices(self) -> None:
        previous = self.device_var.get().strip()
        devices = find_serial_devices()
        self.device_box["values"] = devices
        if previous and previous in devices:
            self.device_var.set(previous)
        elif devices:
            self.device_var.set(devices[0])
        elif not previous:
            self.device_var.set("")
        self.status_var.set(
            f"找到 {len(devices)} 个 USB 串口。" if devices else
            "没有找到 ttyACM/ttyUSB 设备，请检查连接后刷新。"
        )

    def choose_image(self) -> None:
        initial = Path(self.image_var.get()).expanduser()
        filename = filedialog.askopenfilename(
            title="选择 RV32 裸二进制镜像",
            initialdir=str(initial.parent if initial.parent.is_dir() else Path.cwd()),
            filetypes=(("Binary image", "*.bin"), ("All files", "*")),
        )
        if filename:
            self.image_var.set(filename)

    def append_log(self, text: str) -> None:
        self.log.configure(state="normal")
        self.log.insert("end", text)
        self.log.see("end")
        self.log.configure(state="disabled")

    def set_controls_active(self, active: bool) -> None:
        self.active = active
        normal_or_disabled = "disabled" if active else "normal"
        self.device_box.configure(state=normal_or_disabled)
        self.image_entry.configure(state=normal_or_disabled)
        self.refresh_button.configure(state=normal_or_disabled)
        self.browse_button.configure(state=normal_or_disabled)
        self.download_button.configure(state=normal_or_disabled)
        self.disconnect_button.configure(state="normal" if active else "disabled")

    def start_download(self) -> None:
        if self.active:
            return

        device = self.device_var.get().strip()
        image_path = Path(self.image_var.get()).expanduser()
        if not device:
            messagebox.showerror("没有串口", "请选择串口设备。")
            return
        if not image_path.is_file():
            messagebox.showerror("文件不存在", f"找不到程序镜像：\n{image_path}")
            return

        try:
            data = image_path.read_bytes()
        except OSError as exc:
            messagebox.showerror("读取失败", str(exc))
            return

        if not data:
            messagebox.showerror("空镜像", "不能下载空文件。")
            return
        if len(data) > MAX_IMAGE_BYTES:
            messagebox.showerror(
                "镜像过大",
                f"当前程序 RAM 最多容纳 {MAX_IMAGE_BYTES} 字节，"
                f"所选文件为 {len(data)} 字节。",
            )
            return

        self.stop_event.clear()
        self.progress["value"] = 0
        self.append_log(
            f"\n--- 打开 {device}，下载 {image_path.name}（{len(data)} 字节）---\n"
        )
        self.status_var.set("正在打开串口…")
        self.set_controls_active(True)
        self.worker = threading.Thread(
            target=self.transfer_worker,
            args=(device, data),
            daemon=True,
        )
        self.worker.start()

    def transfer_worker(self, device: str, data: bytes) -> None:
        fd = -1
        try:
            fd = os.open(device, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
            configure_serial_115200_8n1(fd)
            termios.tcflush(fd, termios.TCIFLUSH)
            self.messages.put(("status", "正在以 115200 baud 下载…"))

            view = memoryview(data)
            sent = 0
            while sent < len(data):
                if self.stop_event.is_set():
                    raise InterruptedError("用户取消")
                _, writable, _ = select.select([], [fd], [], 0.2)
                if not writable:
                    continue
                try:
                    count = os.write(fd, view[sent:])
                except BlockingIOError:
                    continue
                if count <= 0:
                    raise OSError("串口写入返回 0 字节")
                sent += count
                self.messages.put(("progress", sent, len(data)))

            # Wait until the kernel/USB serial transmit queue has drained.
            termios.tcdrain(fd)
            self.messages.put(("uploaded", len(data)))

            # Keep the descriptor open so CPU UART output appears in this GUI
            # immediately after the user presses the physical START button.
            while not self.stop_event.is_set():
                readable, _, _ = select.select([fd], [], [], 0.2)
                if not readable:
                    continue
                try:
                    received = os.read(fd, 4096)
                except BlockingIOError:
                    continue
                if received:
                    self.messages.put(("rx", received))

        except InterruptedError as exc:
            self.messages.put(("status", str(exc)))
            self.messages.put(("log", "\n[已断开]\n"))
        except PermissionError:
            self.messages.put((
                "error",
                "没有串口访问权限",
                f"无法打开 {device}。请检查设备权限，或将当前用户加入 dialout 组。",
            ))
        except OSError as exc:
            detail = exc.strerror or str(exc)
            if exc.errno == errno.EBUSY:
                detail = "设备正被其他串口程序占用"
            self.messages.put(("error", "串口操作失败", f"{device}: {detail}"))
        finally:
            if fd >= 0:
                try:
                    os.close(fd)
                except OSError:
                    pass
            self.messages.put(("done",))

    def disconnect(self) -> None:
        if self.active:
            self.status_var.set("正在断开…")
            self.stop_event.set()

    def poll_messages(self) -> None:
        try:
            while True:
                message = self.messages.get_nowait()
                kind = message[0]
                if kind == "status":
                    self.status_var.set(message[1])
                elif kind == "progress":
                    sent, total = message[1], message[2]
                    self.progress["value"] = sent * 100 / total
                    self.status_var.set(f"正在下载：{sent}/{total} 字节")
                elif kind == "uploaded":
                    count = message[1]
                    self.progress["value"] = 100
                    self.status_var.set("下载完成：现在按一下板上的 START。")
                    self.append_log(
                        f"[下载完成：{count} 字节；正在监听，请按 START]\n"
                    )
                elif kind == "rx":
                    text = message[1].decode("utf-8", errors="backslashreplace")
                    self.append_log(text)
                elif kind == "log":
                    self.append_log(message[1])
                elif kind == "error":
                    self.status_var.set(message[1])
                    self.append_log(f"[错误] {message[2]}\n")
                    messagebox.showerror(message[1], message[2])
                elif kind == "done":
                    self.set_controls_active(False)
                    self.worker = None
        except queue.Empty:
            pass

        if self.root.winfo_exists():
            self.root.after(50, self.poll_messages)

    def close_window(self) -> None:
        self.stop_event.set()
        self.root.destroy()


def main() -> None:
    root = tk.Tk()
    UartLoaderGui(root)
    root.mainloop()


if __name__ == "__main__":
    main()
