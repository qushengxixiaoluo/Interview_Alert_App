"""Windows 控制台编码修正。

中文 Windows 的控制台默认是 GBK（代码页 936），而 Python 3.13 默认用 UTF-8
输出。两者不一致的表现就是满屏乱码，更糟的情况是写日志时抛 UnicodeEncodeError
直接把进程干掉 —— 而且往往正好发生在出错、最需要日志的时候。

解决办法是把控制台代码页切到 UTF-8（65001），同时把 stdout/stderr 显式设成
UTF-8 且不因个别字符失败而中断。
"""

from __future__ import annotations

import sys


def enable_utf8_console() -> None:
    """让控制台能正确显示中文。在程序入口调用一次即可。"""
    if sys.platform == "win32":
        try:
            import ctypes

            kernel32 = ctypes.windll.kernel32
            kernel32.SetConsoleOutputCP(65001)
            kernel32.SetConsoleCP(65001)
        except Exception:
            # 没有真正的控制台时（比如被重定向到文件、或作为服务运行）会失败，
            # 这不是错误，下面的 stream 重配置仍然有效。
            pass

    for stream in (sys.stdout, sys.stderr):
        try:
            # line_buffering：输出被重定向到文件或管道时 Python 会改用块缓冲，
            # 日志要等到缓冲区满才落盘。这个程序的日志是实时状态显示
            # （「有设备拉取了日历」之类），必须逐行可见。
            stream.reconfigure(encoding="utf-8", errors="replace", line_buffering=True)
        except (AttributeError, ValueError):
            pass

# 注意：本模块只管控制台。写日志文件时，每个 handler 都必须显式传
# encoding="utf-8" —— 服务模式下没有控制台，handler 会退回系统默认的 GBK，
# 中文日志会直接抛 UnicodeEncodeError 把进程干掉。
