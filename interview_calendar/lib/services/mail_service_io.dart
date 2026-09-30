import 'package:enough_mail/enough_mail.dart';
import '../models/mail_message.dart';
import 'mail_service.dart';

MailService createMailService() => _IoMailService();

class _IoMailService implements MailService {
  MailAccount _account(String email, String authCode) {
    // QQ 邮箱 IMAP：imap.qq.com:993（SSL）。登录名就是完整邮箱地址，
    // 密码用「授权码」。SMTP 只是 MailAccount 必填项，本功能只读不发，随便填一个合法的即可。
    return MailAccount.fromManualSettings(
      name: email.trim(),
      email: email.trim(),
      incomingHost: 'imap.qq.com',
      outgoingHost: 'smtp.qq.com',
      password: authCode.trim(),
    );
  }

  @override
  Future<MailFetchResult> fetchRecentMails({
    required String email,
    required String authCode,
    int? sinceUid,
    int maxCount = 100,
  }) async {
    final client = MailClient(_account(email, authCode));
    try {
      await client.connect(timeout: const Duration(seconds: 30));
      await client.selectInbox();

      final List<MimeMessage> messages;
      if (sinceUid == null) {
        // 首次同步：page=1 表示最新的一页（最近 maxCount 封）
        messages = await client.fetchMessages(count: maxCount, page: 1);
      } else {
        // 增量同步：只取 UID 大于游标的邮件（序列渲染为 "sinceUid+1:*"）
        final seq =
            MessageSequence.fromRangeToLast(sinceUid + 1, isUidSequence: true);
        final fetched = await client.fetchMessageSequence(seq);

        // 服务器不保证返回顺序，也可能多返回；按 UID 升序后只留最新 maxCount 封。
        // 复制一份再排序，避免依赖返回列表本身可写。
        final sorted = List<MimeMessage>.of(fetched)
          ..sort((a, b) => (a.uid ?? 0).compareTo(b.uid ?? 0));
        messages = sorted.length > maxCount
            ? sorted.sublist(sorted.length - maxCount)
            : sorted;
      }

      final mails = messages.map(_toMailMessage).toList();
      return MailFetchResult(mails: mails, newestUid: _maxUid(mails));
    } finally {
      try {
        await client.disconnect();
      } catch (_) {
        // 断开失败不影响结果
      }
    }
  }

  @override
  Future<MailFetchResult> fetchMailsInRange({
    required String email,
    required String authCode,
    required DateTime start,
    required DateTime end,
    int maxCount = 200,
  }) async {
    final client = MailClient(_account(email, authCode));
    try {
      await client.connect(timeout: const Duration(seconds: 30));
      await client.selectInbox();

      // 空 query + since/before → IMAP "SINCE … BEFORE …" 日期范围搜索。
      // before 传 end 的次日，让 end 当天也包含进来。
      final search = MailSearch(
        '',
        SearchQueryType.subject, // query 为空，queryType 用不到
        since: DateTime(start.year, start.month, start.day),
        before:
            DateTime(end.year, end.month, end.day).add(const Duration(days: 1)),
        pageSize: maxCount,
        fetchPreference: FetchPreference.full,
      );
      final result = await client.searchMessages(search);
      final messages = result.messages;

      final mails = messages.map(_toMailMessage).toList();
      return MailFetchResult(mails: mails, newestUid: _maxUid(mails));
    } finally {
      try {
        await client.disconnect();
      } catch (_) {
        // 断开失败不影响结果
      }
    }
  }

  /// 把一封 MimeMessage 转成只保留识别所需字段的 MailMessage
  MailMessage _toMailMessage(MimeMessage msg) {
    // 去重键：优先 Message-ID（全局唯一），缺失退回 UID / 序号
    final messageId = msg.decodeHeaderValue('message-id');
    final uid = msg.uid;
    final key = (messageId != null && messageId.isNotEmpty)
        ? 'mid:$messageId'
        : (uid != null ? 'uid:$uid' : 'seq:${msg.sequenceId}');

    return MailMessage(
      uid: key,
      from: msg.decodeHeaderValue('from') ?? '',
      subject: msg.decodeSubject() ?? '',
      date: msg.decodeDate(),
      textBody: _messageBody(msg),
      imapUid: uid,
    );
  }

  int? _maxUid(List<MailMessage> mails) {
    int? newestUid;
    for (final mail in mails) {
      final uid = mail.imapUid;
      if (uid != null && (newestUid == null || uid > newestUid)) {
        newestUid = uid;
      }
    }
    return newestUid;
  }

  /// 取正文纯文本：优先 text/plain，HTML-only 的邮件退化成剥标签的文本
  String _messageBody(MimeMessage msg) {
    final plain = msg.decodeTextPlainPart();
    if (plain != null && plain.trim().isNotEmpty) return plain;
    return _stripHtml(msg.decodeTextHtmlPart() ?? '');
  }

  String _stripHtml(String html) {
    if (html.isEmpty) return '';
    var text = html
        .replaceAll(RegExp(r'<style[\s\S]*?</style>'), '')
        .replaceAll(RegExp(r'<script[\s\S]*?</script>'), '')
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
    text = text.replaceAll(RegExp(r'[ \t]+'), ' ');
    text = text.replaceAll(RegExp(r'\n\s*\n+'), '\n');
    return text.trim();
  }
}
