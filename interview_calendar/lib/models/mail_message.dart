/// 从邮箱拉下来的一封邮件（只保留识别面试所需的最小字段）
class MailMessage {
  /// 唯一标识，用于去重。优先用 Message-ID，缺失时退回 IMAP UID。
  final String uid;

  /// 发件人（原始字符串，可能带 `名字 <email>`）
  final String from;

  /// 主题
  final String subject;

  /// 发信时间（可能为空）
  final DateTime? date;

  /// 正文纯文本
  final String textBody;

  /// 原始 IMAP UID，用作增量同步的游标（`uid` 优先存 Message-ID，不适合比较大小）
  final int? imapUid;

  const MailMessage({
    required this.uid,
    required this.from,
    required this.subject,
    required this.textBody,
    this.date,
    this.imapUid,
  });

  /// 发件人展示名：去掉 `<email>` 只留名字部分
  String get displayFrom {
    final name = from.trim();
    final lt = name.indexOf('<');
    if (lt > 0) return name.substring(0, lt).trim();
    return name.isEmpty ? '(无发件人)' : name;
  }

  /// 主题为空时的兜底展示
  String get displaySubject => subject.trim().isEmpty ? '(无主题)' : subject.trim();
}
