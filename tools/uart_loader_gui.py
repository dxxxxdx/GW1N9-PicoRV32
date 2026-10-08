#!/usr/bin/env python3
"""Tk GUI for loading a raw RV32 binary over the board's UART bridge."""

from __future__ import annotations

import errno
import fnmatch
import glob
import os
from pathlib import Path
import queue
import select
import signal
import stat
import termios
import threading
import time
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


def find_port_holders(device: str) -> list[tuple[int, str]]:
    """Return (pid, comm) for every process that currently has `device` open.

    Scans /proc instead of shelling out to lsof/fuser: neither is guaranteed to
    be installed (both were missing on the machine this was written on), and
    scanning /proc cannot be fooled by a tool that simply prints nothing.
    Processes we cannot inspect (other users) are skipped silently.
    """
    target = os.path.realpath(device)
    me = os.getpid()
    holders: list[tuple[int, str]] = []

    for entry in glob.glob("/proc/[0-9]*"):
        try:
            pid = int(entry.rsplit("/", 1)[1])
        except ValueError:
            continue
        if pid == me or pid == 1:
            continue

        fd_dir = os.path.join(entry, "fd")
        try:
            fds = os.listdir(fd_dir)
        except OSError:
            continue  # 进程已经退出，或者没有权限看

        busy = False
        for name in fds:
            try:
                link = os.readlink(os.path.join(fd_dir, name))
            except OSError:
                continue
            if link == device or os.path.realpath(link) == target:
                busy = True
                break
        if not busy:
            continue

        try:
            with open(os.path.join(entry, "comm"), "r") as handle:
                comm = handle.read().strip()
        except OSError:
            comm = "?"
        holders.append((pid, comm))

    return holders


def free_serial_device(device: str, log) -> None:
    """Kill whatever holds `device` so os.open() cannot fail with EBUSY.

    Sends SIGTERM first and only escalates to SIGKILL for what survives. The
    previous download leaving its port open is the usual reason a fresh run
    fails, so this runs before every transfer.
    """
    # 安全阀：只对 DEVICE_PATTERNS 里的字符设备动手。
    # 少了这一层，万一设备路径写成了 /dev/null 之类，就会把一大票进程全杀了
    # （实测 /dev/null 被 dbus/pipewire/gnome-shell 等几十个进程开着）。
    try:
        mode = os.stat(device).st_mode
    except OSError:
        return
    if not stat.S_ISCHR(mode) or not any(
        fnmatch.fnmatch(device, pattern) for pattern in DEVICE_PATTERNS
    ):
        log(f"[跳过清理] {device} 不是本工具的串口设备\n")
        return

    holders = find_port_holders(device)
    if not holders:
        return

    for pid, comm in holders:
        log(f"[串口被占用] pid={pid} {comm} → SIGTERM\n")
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass

    deadline = time.monotonic() + 2.0
    while time.monotonic() < deadline:
        if not find_port_holders(device):
            log("[占用已解除]\n")
            return
        time.sleep(0.05)

    for pid, comm in find_port_holders(device):
        log(f"[仍在占用] pid={pid} {comm} → SIGKILL\n")
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
    time.sleep(0.2)


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
        # 会话序号：旧会话退出时也会丢一条 done 进队列，如果不带序号，
        # 它会把刚开起来的新会话状态清掉。
        self.session_seq = 0
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
        # 一律保持可用。下载按钮再点一次 = 自动停掉上一轮再重开，
        # 免得"上次监听还占着端口"变成用户解不开的死结。
        self.device_box.configure(state="normal")
        self.image_entry.configure(state="normal")
        self.refresh_button.configure(state="normal")
        self.browse_button.configure(state="normal")
        self.download_button.configure(state="normal")
        self.disconnect_button.configure(state="normal" if active else "disabled")

    def stop_worker(self, reason: str = "") -> None:
        """干净地结束当前会话：发停止信号并等线程真的退出、fd 真的关掉。

        必须 join，不能只 set 事件就算完 —— 否则新会话的 os.open 会和
        正在退出的旧线程抢端口，直接 EBUSY。
        """
        worker = self.worker
        if worker is None:
            self.set_controls_active(False)
            return

        self.stop_event.set()
        if worker.is_alive():
            if reason:
                self.append_log(f"[{reason}]\n")
            worker.join(timeout=2.0)
            if worker.is_alive():
                self.append_log("[警告] 上次的线程 2 秒内没退出\n")
        self.worker = None
        self.set_controls_active(False)

    def start_download(self) -> None:
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

        # 参数都验过了，才去动上一轮会话 —— 免得手滑点一下就把正在看的
        # 串口输出停掉。原来这里只 clear() 事件就开新线程，旧线程还在监听、
        # fd 还没关，新线程 open 必然 EBUSY，这就是"老被占着"的来源。
        self.stop_worker("重新下载，先释放上一次的串口")

        # 每次会话一个独立事件 + 序号：不会和上一轮互相干扰。
        stop_event = threading.Event()
        self.stop_event = stop_event
        self.session_seq += 1
        session_id = self.session_seq

        self.progress["value"] = 0
        self.append_log(
            f"\n--- 打开 {device}，下载 {image_path.name}（{len(data)} 字节）---\n"
        )
        self.status_var.set("正在打开串口…")
        self.set_controls_active(True)
        self.worker = threading.Thread(
            target=self.transfer_worker,
            args=(device, data, stop_event, session_id),
            daemon=True,
            name="uart-transfer",
        )
        self.worker.start()

    def transfer_worker(self, device: str, data: bytes,
                        stop_event: threading.Event, session_id: int) -> None:
        fd = -1
        try:
            # 每次下载前先踢掉占着串口的进程，否则 os.open 会直接 EBUSY。
            free_serial_device(device, lambda text: self.messages.put(("log", text)))

            fd = os.open(device, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
            configure_serial_115200_8n1(fd)
            termios.tcflush(fd, termios.TCIFLUSH)
            self.messages.put(("status", "正在以 115200 baud 下载…"))

            view = memoryview(data)
            sent = 0
            while sent < len(data):
                if stop_event.is_set():
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
            while not stop_event.is_set():
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
                holders = find_port_holders(device)
                detail = "设备正被占用"
                if holders:
                    detail += "：" + ", ".join(
                        f"pid={pid} {comm}" for pid, comm in holders)
            self.messages.put(("error", "串口操作失败", f"{device}: {detail}"))
        finally:
            if fd >= 0:
                try:
                    os.close(fd)
                except OSError:
                    pass
            self.messages.put(("done", session_id))

    def disconnect(self) -> None:
        if self.active:
            self.status_var.set("正在断开…")
            self.stop_worker("用户断开")

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
                    # 只认当前会话的收尾，旧会话的 done 直接丢掉。
                    if message[1] == self.session_seq:
                        self.set_controls_active(False)
                        self.worker = None
        except queue.Empty:
            pass

        if self.root.winfo_exists():
            self.root.after(50, self.poll_messages)

    def close_window(self) -> None:
        # join 一下再销毁窗口，保证 fd 关掉、端口立刻可用。
        self.stop_worker()
        self.root.destroy()


def main() -> None:
    root = tk.Tk()
    UartLoaderGui(root)
    root.mainloop()


if __name__ == "__main__":
    main()
