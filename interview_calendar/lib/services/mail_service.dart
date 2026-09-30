import '../models/mail_message.dart';

// 条件导入：native 端用 enough_mail（依赖 dart:io 套接字），web 端编译不过，
// 所以用和 database.dart 一样的套路把 dart:io 挡在 web 构建之外。
import 'mail_service_io.dart' if (dart.library.js_interop) 'mail_service_web.dart';

/// 一次拉取的结果，附带「最新一封的 IMAP UID」作为下次同步的游标
class MailFetchResult {
  final List<MailMessage> mails;
  final int? newestUid;
  const MailFetchResult({required this.mails, this.newestUid});
}

/// QQ 邮箱 IMAP 读取服务。
///
/// native（Android / Windows）走 enough_mail 连 imap.qq.com；
/// web 端不支持（IMAP 需要原生 TCP 套接字），调用会抛错。
abstract class MailService {
  /// 连接 imap.qq.com，拉取邮件并解码成最小字段。
  ///
  /// [email] QQ 邮箱地址，[authCode] 授权码（不是 QQ 密码）。
  /// [sinceUid] 为 null 时拉最新 [maxCount] 封（全量）；
  /// 非 null 时只拉 UID 大于它的邮件（增量），最多 [maxCount] 封。
  Future<MailFetchResult> fetchRecentMails({
    required String email,
    required String authCode,
    int? sinceUid,
    int maxCount = 100,
  });

  /// 按日期范围拉取邮件（手动选时间段识别用）。
  /// [start] 起（含当天），[end] 止（含当天），最新优先，最多 [maxCount] 封。
  Future<MailFetchResult> fetchMailsInRange({
    required String email,
    required String authCode,
    required DateTime start,
    required DateTime end,
    int maxCount = 200,
  });

  static MailService create() => createMailService();
}
