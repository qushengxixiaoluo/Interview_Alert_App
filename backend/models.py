"""领域模型。"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime

# 事件状态
STATUS_TENTATIVE = "tentative"
STATUS_CONFIRMED = "confirmed"
STATUS_CANCELLED = "cancelled"

# 邮件处理状态
MSG_PENDING = "pending"
MSG_EXTRACTED = "extracted"
MSG_FAILED = "failed"

# 大模型对邮件的分类
CAT_INVITE = "interview_invite"
CAT_RESCHEDULE = "reschedule"
CAT_CANCEL = "cancel"
CAT_ASSESSMENT = "assessment"  # 笔试 / 测评，不是面试
CAT_REJECTION = "rejection"
CAT_OFFER = "offer"
CAT_OTHER = "other"

VALID_CATEGORIES = {
    CAT_INVITE,
    CAT_RESCHEDULE,
    CAT_CANCEL,
    CAT_ASSESSMENT,
    CAT_REJECTION,
    CAT_OFFER,
    CAT_OTHER,
}

# 相对已有事件的动作
ACTION_NEW = "new"
ACTION_UPDATE = "update"
ACTION_CANCEL = "cancel"
ACTION_NONE = "none"

VALID_ACTIONS = {ACTION_NEW, ACTION_UPDATE, ACTION_CANCEL, ACTION_NONE}


@dataclass
class Reminder:
    """提醒策略。

    刻意定义在 models 而不是 config 里：ics.py 需要它，而 config 依赖 PyYAML。
    保持领域层零依赖，ICS 生成才能在没有任何第三方包的环境下跑起来
    （Step 0 的验证脚本就靠这一点做到免安装）。
    """

    # 提前多少分钟提醒。1440 = 前一天同一时刻。
    lead_minutes: list[int] = field(default_factory=lambda: [24 * 60])
    alarm_description: str = "明天有面试"


@dataclass
class Extraction:
    """大模型对一封邮件抽取出的结构化结果。"""

    is_interview: bool = False
    category: str = CAT_OTHER
    confidence: float = 0.0
    company: str = ""
    role: str = ""
    round: str = ""
    interview_start: datetime | None = None
    duration_minutes: int | None = None
    time_is_explicit: bool = False
    location: str = ""
    meeting_url: str = ""
    contact: str = ""
    candidate_slots: list[str] = field(default_factory=list)
    needs_user_input: list[str] = field(default_factory=list)
    related_event_id: int | None = None
    action: str = ACTION_NONE
    summary: str = ""
    evidence: str = ""

    @property
    def needs_review(self) -> bool:
        """是否需要人工核对。

        时间不是明确写出来的、邮件给了多个候选时间、或者模型自己就不确定 ——
        这几种情况都不能当作已确认，必须在 App 里标红要求核对。
        """
        if not self.is_interview:
            return False
        if not self.time_is_explicit:
            return True
        if self.candidate_slots:
            return True
        if self.confidence < 0.75:
            return True
        return False

    def review_reason(self) -> str:
        reasons = []
        if not self.time_is_explicit:
            reasons.append("邮件未写明具体时间，当前时间是推算的")
        if self.candidate_slots:
            reasons.append("邮件给出多个候选时间，需选择其一")
        if self.confidence < 0.75:
            reasons.append(f"模型置信度偏低（{self.confidence:.0%}）")
        return "；".join(reasons)


@dataclass
class Event:
    """日历事件，对应 ICS 里的一个 VEVENT。"""

    id: int | None = None
    source_message_id: int | None = None
    company: str = ""
    role: str = ""
    round: str = ""
    start_at: datetime | None = None
    end_at: datetime | None = None
    timezone: str = "Asia/Shanghai"
    location: str = ""
    meeting_url: str = ""
    contact: str = ""
    notes: str = ""
    status: str = STATUS_TENTATIVE
    needs_review: bool = True
    review_reason: str = ""
    sequence: int = 0
    created_at: datetime | None = None
    updated_at: datetime | None = None

    @property
    def summary(self) -> str:
        """日历上显示的标题。

        「待确认」体现在标题前缀上，而不是 ICS 的 STATUS —— 部分日历 UI 对
        TENTATIVE 事件的提醒处理不一致，而这里的提醒是硬需求，不能冒这个险。
        """
        title = f"面试：{self.company}" if self.company else "面试"
        if self.role:
            title += f" - {self.role}"
        if self.round:
            title += f"（{self.round}）"
        if self.needs_review:
            title = f"【待确认】{title}"
        return title

    @property
    def ics_status(self) -> str:
        return "CONFIRMED"

    @property
    def uid(self) -> str:
        """ICS UID。必须由数据库主键派生，保证事件被修改时 UID 不变 ——
        否则手机上会出现重复事件，而不是原地更新。"""
        return f"event-{self.id}@interview-alert.local"
