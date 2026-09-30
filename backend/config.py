"""配置加载。

密钥可以写在 config.yaml 里，也可以用环境变量提供 —— 环境变量优先级更高，
这样凭据可以不落盘。
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

from .models import Reminder

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CONFIG_PATH = ROOT / "config.yaml"


def default_data_dir() -> Path:
    """运行期状态目录。

    刻意放在 %LOCALAPPDATA% 而不是项目目录：这台机器的桌面是 OneDrive 重定向的，
    同步中的 SQLite 会因并发写入损坏，而且库里存着 HR 联系方式和面试安排，
    不应该被同步到 OneDrive。
    """
    base = os.environ.get("LOCALAPPDATA") or os.environ.get("APPDATA")
    return Path(base) / "InterviewAlert" if base else ROOT / "data"

ENV_MAIL_USER = "INTERVIEW_ALERT_MAIL_USER"
ENV_MAIL_AUTH_CODE = "INTERVIEW_ALERT_MAIL_AUTH_CODE"
ENV_DEEPSEEK_KEY = "INTERVIEW_ALERT_DEEPSEEK_KEY"


class ConfigError(Exception):
    """配置缺失或非法。"""


@dataclass
class MailConfig:
    host: str = "imap.qq.com"
    port: int = 993
    user: str = ""
    auth_code: str = ""
    folder: str = "INBOX"
    lookback_days: int = 30
    idle_timeout: int = 1500
    poll_interval: int = 300


@dataclass
class LLMConfig:
    base_url: str = "https://api.deepseek.com"
    api_key: str = ""
    model: str = "deepseek-flash"
    timeout: int = 90


@dataclass
class ServerConfig:
    host: str = "0.0.0.0"
    port: int = 8787


@dataclass
class CalendarConfig:
    default_hour: int = 9
    default_duration_minutes: int = 60
    timezone: str = "Asia/Shanghai"


@dataclass
class Config:
    mail: MailConfig = field(default_factory=MailConfig)
    llm: LLMConfig = field(default_factory=LLMConfig)
    reminder: Reminder = field(default_factory=Reminder)
    server: ServerConfig = field(default_factory=ServerConfig)
    calendar: CalendarConfig = field(default_factory=CalendarConfig)
    db_path: Path = field(default_factory=lambda: default_data_dir() / "interview_alert.db")

    def validate_for_mail(self) -> None:
        missing = []
        if not self.mail.user:
            missing.append(f"mail.user（或环境变量 {ENV_MAIL_USER}）")
        if not self.mail.auth_code:
            missing.append(f"mail.auth_code（或环境变量 {ENV_MAIL_AUTH_CODE}）")
        if missing:
            raise ConfigError(
                "缺少邮箱配置：" + "、".join(missing) + "\n"
                "授权码获取方式：QQ邮箱 → 设置 → 账户 → POP3/IMAP/SMTP服务 → "
                "开启 IMAP/SMTP 服务 → 生成授权码（16 位）。注意不是 QQ 密码。"
            )

    def validate_for_llm(self) -> None:
        if not self.llm.api_key:
            raise ConfigError(
                f"缺少大模型 API key：llm.api_key（或环境变量 {ENV_DEEPSEEK_KEY}）\n"
                "申请地址：https://platform.deepseek.com"
            )


def _section(raw: dict[str, Any], name: str) -> dict[str, Any]:
    value = raw.get(name) or {}
    if not isinstance(value, dict):
        raise ConfigError(f"配置项 {name} 应该是一个映射，实际是 {type(value).__name__}")
    return value


def _build(cls: type, values: dict[str, Any], name: str):
    """按 dataclass 的字段过滤，未知字段直接报错而不是静默忽略 —— 拼错的键
    如果被静默吞掉，表现是「配置了但不生效」，非常难排查。"""
    known = {f.name for f in cls.__dataclass_fields__.values()}  # type: ignore[attr-defined]
    unknown = set(values) - known
    if unknown:
        raise ConfigError(
            f"配置项 {name} 里有无法识别的字段：{', '.join(sorted(unknown))}；"
            f"可用字段：{', '.join(sorted(known))}"
        )
    return cls(**values)


def load_config(path: Path | None = None) -> Config:
    path = path or DEFAULT_CONFIG_PATH
    raw: dict[str, Any] = {}
    if path.exists():
        with open(path, encoding="utf-8") as fh:
            raw = yaml.safe_load(fh) or {}
        if not isinstance(raw, dict):
            raise ConfigError(f"{path} 的顶层结构应该是一个映射")

    config = Config(
        mail=_build(MailConfig, _section(raw, "mail"), "mail"),
        llm=_build(LLMConfig, _section(raw, "llm"), "llm"),
        reminder=_build(Reminder, _section(raw, "reminder"), "reminder"),
        server=_build(ServerConfig, _section(raw, "server"), "server"),
        calendar=_build(CalendarConfig, _section(raw, "calendar"), "calendar"),
    )

    # 环境变量优先，方便把凭据放在文件之外
    config.mail.user = os.environ.get(ENV_MAIL_USER) or config.mail.user
    config.mail.auth_code = os.environ.get(ENV_MAIL_AUTH_CODE) or config.mail.auth_code
    config.llm.api_key = os.environ.get(ENV_DEEPSEEK_KEY) or config.llm.api_key

    # 刻意不把空的 lead_minutes 兜回默认值：显式写 lead_minutes: [] 就是
    # 「不要任何闹钟」，只把事件写进日历。未配置时由 Reminder 的默认值兜底。
    config.db_path = default_data_dir() / "interview_alert.db"
    return config
