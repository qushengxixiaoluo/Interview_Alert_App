"""Step 0 验证：证明「面试事件能不能出现在手机日历里」。

验证目标很具体：**事件写进手机日历，你打开日历能看见**。
不涉及闹钟 —— 「到点响铃」是另一回事（安卓会剥离订阅源里的闹钟设置），
既然不强依赖它，就不必为它先做实测。

为什么这一步仍然必须做：
  * 网页 App 在国内安卓上收不到推送，手机自带日历才是你日常真正会看的地方；
  * ICS 由小米日历（内部用 ical4j）解析，它对格式很严格，而且**出错时不报错**，
    只是事件不出现 —— 所以必须用真机确认，查文档查不出来。

只用标准库，不需要 pip install 任何东西。

用法：
    python spike.py                # 造 3 个测试事件：明天、后天、5 天后
    python spike.py --days 0 1 2   # 指定第几天后，0 = 今天
"""

from __future__ import annotations

import argparse
import socket
import sys
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from backend.console import enable_utf8_console  # noqa: E402
from backend.ics import build_calendar  # noqa: E402
from backend.models import Event, Reminder  # noqa: E402

PORT = 8787
ICS_PATH = "/calendar.ics"

# 测试事件统一放在下午，方便在一个月视图里一眼认出来
TEST_HOUR = 14
TEST_MINUTE = 30


def lan_ip() -> str:
    """拿到本机在局域网里的地址。

    连一个外部地址只是为了问操作系统「你会用哪张网卡出去」，UDP 不会真的发包。
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.connect(("223.5.5.5", 80))
        return sock.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        sock.close()


def build_test_events(day_offsets: list[int], now: datetime) -> tuple[list[Event], Reminder]:
    """构造测试事件，落在 N 天之后的下午。"""
    local_tz = now.astimezone().tzinfo
    reminder = Reminder(lead_minutes=[24 * 60])
    events: list[Event] = []

    for index, offset in enumerate(day_offsets, start=1):
        day = (now.astimezone(local_tz) + timedelta(days=offset)).replace(
            hour=TEST_HOUR, minute=TEST_MINUTE, second=0, microsecond=0
        )
        events.append(
            Event(
                id=index,
                company=f"测试公司{index}",
                role="后端开发工程师",
                round="一面",
                start_at=day,
                end_at=day + timedelta(minutes=60),
                location="线上 - 腾讯会议",
                meeting_url="https://meeting.tencent.com/test",
                notes=(
                    "这是验证日历订阅链路的测试事件。\n"
                    "如果你在手机日历里看到了它，说明邮件自动进日历这条路是通的。\n"
                    "验证完可以直接删掉。"
                ),
                needs_review=False,
                sequence=0,
                updated_at=now,
            )
        )
    return events, reminder


def _unfold(ics_text: str) -> list[str]:
    """把折行的物理行还原成逻辑行。

    按逻辑行检查内容，按物理行检查折行 —— 两者混在一起会互相干扰
    （折行本身会把一个属性拆到两行，字符串计数就不准了）。
    """
    logical: list[str] = []
    for raw in ics_text.split("\r\n"):
        if raw.startswith(" ") and logical:
            logical[-1] += raw[1:]
        elif raw:
            logical.append(raw)
    return logical


def _blocks(lines: list[str], name: str) -> list[list[str]]:
    """取出所有 BEGIN:name ... END:name 块。"""
    found: list[list[str]] = []
    current: list[str] | None = None
    for line in lines:
        if line == f"BEGIN:{name}":
            current = []
        elif line == f"END:{name}" and current is not None:
            found.append(current)
            current = None
        elif current is not None:
            current.append(line)
    return found


def validate(ics_text: str) -> list[str]:
    """对生成的 ICS 做结构性检查。

    这些正是会让小米日历（ical4j）**静默**拒绝整个文件的几类问题 ——
    没有报错，事件就是不出现，所以必须自己检查。
    """
    problems: list[str] = []
    physical = ics_text.split("\r\n")
    logical = _unfold(ics_text)

    # --- 折行与换行（必须看物理行）---
    for lineno, line in enumerate(physical, start=1):
        if len(line.encode("utf-8")) > 75:
            problems.append(f"第 {lineno} 行超过 75 字节，未正确折行")
        if "\n" in line or "\r" in line:
            problems.append(f"第 {lineno} 行含裸换行符，必须用 CRLF")

    if ics_text.encode("utf-8")[:3] == b"\xef\xbb\xbf":
        problems.append("文件开头有 UTF-8 BOM，部分解析器会拒绝")
    if not ics_text.startswith("BEGIN:VCALENDAR"):
        problems.append("文件未以 BEGIN:VCALENDAR 开头")
    if not ics_text.endswith("\r\n"):
        problems.append("文件未以 CRLF 结尾")

    # --- 结构（看逻辑行）---
    if len(_blocks(logical, "VCALENDAR")) != 1:
        problems.append("VCALENDAR 块缺失或嵌套")
    if "METHOD:" in ics_text:
        problems.append("订阅源不应包含 METHOD")

    events = _blocks(logical, "VEVENT")
    if not events:
        problems.append("没有任何 VEVENT")

    for index, event in enumerate(events, start=1):
        for required in ("UID:", "DTSTAMP:", "DTSTART:", "SEQUENCE:", "SUMMARY:"):
            if not any(line.startswith(required) for line in event):
                problems.append(f"第 {index} 个 VEVENT 缺少必填属性 {required}")
        # 时间必须是 UTC 字面量；带 TZID 却没有匹配的 VTIMEZONE 会整体偏移 8 小时
        starts = [l for l in event if l.startswith("DTSTART")]
        if starts and ("TZID" in starts[0] or not starts[0].endswith("Z")):
            problems.append(f"第 {index} 个 VEVENT 的 DTSTART 不是 UTC 字面量：{starts[0]}")

    for index, alarm in enumerate(_blocks(logical, "VALARM"), start=1):
        # ACTION:DISPLAY 缺 DESCRIPTION 会被严格解析器整段丢弃。
        # 现在是可选功能，但既然输出了就不该是坏的。
        if any(l == "ACTION:DISPLAY" for l in alarm) and not any(
            l.startswith("DESCRIPTION:") for l in alarm
        ):
            problems.append(f"第 {index} 个 VALARM 是 DISPLAY 但缺少 DESCRIPTION")
        if not any(l.startswith("TRIGGER:") for l in alarm):
            problems.append(f"第 {index} 个 VALARM 缺少 TRIGGER")

    return problems


class Server(ThreadingHTTPServer):
    """Windows 上必须关掉 SO_REUSEADDR。

    HTTPServer 默认 allow_reuse_address = 1。在 Linux 上这只影响 TIME_WAIT 状态
    的地址复用，无害；但在 Windows 上 SO_REUSEADDR 允许**第二个**套接字绑定一个
    已经被占用的端口 —— 不报错，只是永远收不到连接。

    后果极具误导性：你看到启动横幅打印成功，以为服务正常，实际上所有请求都被
    那个残留的旧实例接走了，而新实例的日志里一片空白。宁可这里直接报错。
    """

    allow_reuse_address = False
    daemon_threads = True


class Handler(BaseHTTPRequestHandler):
    ics_bytes: bytes = b""
    hits: list[str] = []

    def do_GET(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        if path != ICS_PATH:
            self.send_error(404)
            return

        stamp = datetime.now().strftime("%H:%M:%S")
        Handler.hits.append(stamp)
        print(f"  [{stamp}] 有设备拉取了日历，来自 {self.address_string()}")

        self.send_response(200)
        self.send_header("Content-Type", "text/calendar; charset=utf-8")
        self.send_header("Content-Length", str(len(self.ics_bytes)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(self.ics_bytes)

    def do_HEAD(self) -> None:  # noqa: N802
        self.send_response(200)
        self.send_header("Content-Type", "text/calendar; charset=utf-8")
        self.end_headers()

    def log_message(self, fmt: str, *args) -> None:
        pass  # 自己的日志已经够用，屏蔽默认的逐请求刷屏


def main() -> int:
    enable_utf8_console()
    parser = argparse.ArgumentParser(description="日历订阅 Step 0 验证")
    parser.add_argument(
        "--days",
        type=int,
        nargs="+",
        default=[1, 2, 5],
        help="测试事件放在几天后，可给多个（默认 1 2 5；0 表示今天）",
    )
    parser.add_argument("--port", type=int, default=PORT)
    args = parser.parse_args()

    now = datetime.now(timezone.utc)
    events, reminder = build_test_events(sorted(args.days), now)
    ics = build_calendar(events, reminder)

    problems = validate(ics)
    if problems:
        print("生成的 ICS 有问题，先修这些再继续：")
        for problem in problems:
            print(f"  ✗ {problem}")
        return 1

    # 同时落一份文件，方便走「本地文件导入」这条路做对照
    out_file = Path(__file__).resolve().parent / "spike.ics"
    out_file.write_text(ics, encoding="utf-8", newline="")

    ip = lan_ip()
    url = f"http://{ip}:{args.port}{ICS_PATH}"

    print("=" * 68)
    print("  ICS 结构检查通过")
    print("=" * 68)
    print(f"""
订阅地址：  {url}
本地文件：  {out_file}

造了这些测试事件：""")
    for event in events:
        local = event.start_at.astimezone().strftime("%m-%d %H:%M")
        print(f"  · {local}  {event.summary}")

    print("""
──────────────────────────────────────────────────────────────────
【这一步只验证一件事：手机日历里能不能看见上面这几个事件】

先把日历加入手机，两种方式任选：

  方式 A（零安装，先试这个）
    小米日历 → 右上角菜单 → 设置 → 日程导入 → URL 导入
    → 粘贴上面的订阅地址 → 保存

  方式 B（若方式 A 不支持自动刷新）
    装 ICSx⁵：https://github.com/bitfireAT/icsx5/releases
    添加日历 → 输入订阅地址 → 保存 → 同步频率设为 15 分钟

然后看手机上有没有出现「测试公司1 / 2 / 3」这几条事件。

【观察要点】
  · 这个窗口必须一直开着 —— 关掉手机就连不上了
  · 加入之后先在手机上手动同步一次
  · 窗口里出现「有设备拉取了日历」= 手机确实连上了
  · 日历里看见测试事件 = 这一步通过

【如果没看见】
  · 窗口里连「拉取了日历」都没有 → 手机没连上，多半是没连同一个 WiFi，
    或者 Windows 防火墙拦了。先解决这个，再谈日历。
  · 有「拉取了日历」但日历是空的 → ICS 被手机拒了，把窗口里的输出发我。

顺带说明：ICS 里也带了「提前一天」的闹钟设置。如果手机上顺便响了，
那是赚到的（本来就是你要的）；如果没响也不影响这一步的结论。

按 Ctrl+C 结束。
──────────────────────────────────────────────────────────────────
""")

    Handler.ics_bytes = ics.encode("utf-8")
    try:
        server = Server(("0.0.0.0", args.port), Handler)
    except OSError as exc:
        print(f"\n端口 {args.port} 已被占用：{exc}")
        print("多半是上一次的 spike.py 还在后台跑。先关掉它，或者换个端口：")
        print(f"    python spike.py --port {args.port + 1}")
        return 1

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print(f"\n结束。共收到 {len(Handler.hits)} 次拉取：{', '.join(Handler.hits) or '无'}")
        if not Handler.hits:
            print("一次拉取都没有 —— 手机没连上，先排查网络和防火墙。")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
