"""iCalendar (RFC 5545) 生成。

这是整个方案的地基：面试提醒能不能准时响，完全取决于生成的 ICS 是否被手机
日历正确解析。几处踩过坑、且后果严重的地方：

1. **时间一律输出 UTC。** 带 TZID 的 DTSTART 要求同时给出匹配的 VTIMEZONE，
   否则严格解析器（小米日历用的是 ical4j）会退回 UTC 或 floating，事件整体
   偏移 8 小时。而 VTIMEZONE 里 TZOFFSETFROM 与 TZOFFSETTO 相等又会被部分
   解析器嫌弃。直接写 UTC 字面量在所有平台上都无歧义，且中国无夏令时，
   -P1D 依然落在前一天的同一本地时刻。

2. **UID 必须跨更新保持稳定**（由数据库主键派生）。UID 一变，手机上就是新增
   一条事件而不是原地更新。

3. **内容变化后 SEQUENCE 必须自增**，否则客户端比对本地副本后会静默忽略更新。

4. **ACTION:DISPLAY 的 VALARM 必须带 DESCRIPTION**，这是 RFC 5545 的强制要求，
   缺了会被严格解析器整段丢弃 —— 这是「闹钟没响」最常见的真实原因。

5. **长行按 75 字节折行，且不能把 UTF-8 汉字从中间劈开。**

6. **订阅源里不要出现 STATUS:CANCELLED**，部分客户端会把它渲染成一条永久存在的
   「已取消」事件。订阅源的语义是：事件从源里消失 = 删除。取消的事件直接不输出。
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from .models import Event, Reminder

PRODID = "-//InterviewAlert//面试邀约提醒//CN"
CALENDAR_NAME = "面试安排"

_FOLD_LIMIT = 75


def _escape(text: str) -> str:
    """转义 ICS 属性值里的特殊字符。

    反斜杠必须最先替换，否则后续插入的反斜杠会被二次转义。
    """
    if not text:
        return ""
    return (
        text.replace("\\", "\\\\")
        .replace(";", "\\;")
        .replace(",", "\\,")
        .replace("\r\n", "\\n")
        .replace("\n", "\\n")
        .replace("\r", "\\n")
    )


def _fold(line: str) -> str:
    """按 75 字节折行，续行以单个空格开头。

    按字节而非字符计数，并且绝不从 UTF-8 多字节序列中间切开 —— 中文描述的
    字节数几乎必然超过 75，折行写错会导致整个日历解析失败。
    """
    data = line.encode("utf-8")
    if len(data) <= _FOLD_LIMIT:
        return line

    chunks: list[str] = []
    start = 0
    limit = _FOLD_LIMIT
    while start < len(data):
        end = min(start + limit, len(data))
        while end < len(data) and (data[end] & 0xC0) == 0x80:  # UTF-8 续字节
            end -= 1
        if end == start:  # 理论上不可达（单字符最长 4 字节），保险起见
            end = min(start + limit, len(data))
        chunks.append(data[start:end].decode("utf-8"))
        start = end
        limit = _FOLD_LIMIT - 1  # 续行开头多一个空格
    return "\r\n ".join(chunks)


def _utc(dt: datetime) -> str:
    """转成 ICS 的 UTC 时间字面量。naive 时间按 UTC 处理。"""
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def _duration(minutes: int) -> str:
    """把「提前分钟数」转成 RFC 5545 duration 字面量。

    整天用 nominal 的 P{n}D 而不是 PT{n}H —— 跨夏令时时 nominal 才是对的
    （中国无夏令时，这里两者等价，但语义上 P1D 更正确）。
    """
    if minutes % (24 * 60) == 0:
        return f"-P{minutes // (24 * 60)}D"
    if minutes % 60 == 0:
        return f"-PT{minutes // 60}H"
    return f"-PT{minutes}M"


def alarm_times(event: Event, reminder: Reminder) -> list[datetime]:
    """算出这个事件实际会在哪些时刻触发闹钟。"""
    if event.start_at is None:
        return []
    return [event.start_at - timedelta(minutes=m) for m in reminder.lead_minutes]


def alarms_already_passed(event: Event, reminder: Reminder, now: datetime) -> bool:
    """所有闹钟时刻是否都已经过去。

    这种情况真实存在且很致命：面试在明天 14:30，而事件今天 15:00 才创建 ——
    「提前 24 小时」那个时刻早就过了，闹钟永远不会响。调用方必须检测到这一点
    并走兜底提醒通道，不能默认「写进日历就有人提醒我」。
    """
    times = alarm_times(event, reminder)
    return bool(times) and all(t <= now for t in times)


def _description(event: Event) -> str:
    lines: list[str] = []
    if event.company:
        lines.append(f"公司：{event.company}")
    if event.role:
        lines.append(f"岗位：{event.role}")
    if event.round:
        lines.append(f"轮次：{event.round}")
    if event.contact:
        lines.append(f"联系人：{event.contact}")
    if event.location:
        lines.append(f"地点：{event.location}")
    if event.meeting_url:
        lines.append(f"会议链接：{event.meeting_url}")
    if event.notes:
        lines.append("")
        lines.append(event.notes)
    if event.needs_review and event.review_reason:
        lines.append("")
        lines.append(f"⚠ 待核对：{event.review_reason}")
    return "\n".join(lines)


def build_event(
    event: Event,
    reminder: Reminder,
    dtstamp: datetime | None = None,
) -> list[str]:
    """把一个 Event 渲染成 VEVENT 内容行（尚未折行）。"""
    if event.id is None:
        raise ValueError("事件必须先落库拿到主键，UID 依赖它保持稳定")
    if event.start_at is None:
        raise ValueError(f"事件 {event.id} 缺少开始时间")

    dtstamp = dtstamp or datetime.now(timezone.utc)

    lines: list[str] = [
        "BEGIN:VEVENT",
        f"UID:{event.uid}",
        f"DTSTAMP:{_utc(dtstamp)}",
        f"SEQUENCE:{event.sequence}",
        f"SUMMARY:{_escape(event.summary)}",
        f"DTSTART:{_utc(event.start_at)}",
    ]
    if event.end_at:
        lines.append(f"DTEND:{_utc(event.end_at)}")
    if event.location:
        lines.append(f"LOCATION:{_escape(event.location)}")
    if event.meeting_url:
        lines.append(f"URL:{_escape(event.meeting_url)}")

    description = _description(event)
    if description:
        lines.append(f"DESCRIPTION:{_escape(description)}")

    lines.append(f"LAST-MODIFIED:{_utc(event.updated_at or dtstamp)}")
    lines.append(f"STATUS:{event.ics_status}")

    # 每个提醒时刻一个 VALARM。
    #
    # 注意这里不对「待确认」做任何保留 —— VALARM 可能被安卓整段剥离（RFC 9074
    # 建议客户端剥离第三方数据里的 VALARM），可靠的那条路是日历账户的默认提醒。
    # 既然 VALARM 只是尽力而为，就没有理由再因为「时间还没核对」而少设一道；
    # 漏掉一场面试的代价远大于多响一次。待确认状态体现在 SUMMARY 的【待确认】前缀上。
    for lead in reminder.lead_minutes:
        lines.extend(
            [
                "BEGIN:VALARM",
                f"TRIGGER:{_duration(lead)}",
                "ACTION:DISPLAY",
                # ACTION:DISPLAY 时 DESCRIPTION 是 RFC 5545 的必填项，
                # 缺失会导致严格解析器整段丢弃这个 VALARM。
                f"DESCRIPTION:{_escape(reminder.alarm_description)}",
                "END:VALARM",
            ]
        )

    lines.append("END:VEVENT")
    return lines


def build_calendar(
    events: list[Event],
    reminder: Reminder,
    dtstamp: datetime | None = None,
) -> str:
    """生成完整的 VCALENDAR。

    只应传入「要出现在日历上」的事件 —— 被取消或被用户否决的事件不要传进来。
    订阅源的删除语义是「从源里消失」，而不是发一个 STATUS:CANCELLED。
    """
    dtstamp = dtstamp or datetime.now(timezone.utc)
    lines: list[str] = [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        f"PRODID:{PRODID}",
        "CALSCALE:GREGORIAN",
        # 不输出 METHOD：部分客户端在订阅源上遇到 METHOD:PUBLISH 会行为异常
        f"X-WR-CALNAME:{_escape(CALENDAR_NAME)}",
        "X-WR-TIMEZONE:Asia/Shanghai",
        # 提示客户端刷新间隔。注意是 PT15M，写成 P1H 会被 ical4j 判为非法
        # 并导致整个导入静默失败。
        "REFRESH-INTERVAL;VALUE=DURATION:PT15M",
        "X-PUBLISHED-TTL:PT15M",
    ]

    for event in events:
        lines.extend(build_event(event, reminder, dtstamp))

    lines.append("END:VCALENDAR")
    return "\r\n".join(_fold(line) for line in lines) + "\r\n"
