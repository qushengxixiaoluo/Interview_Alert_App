import 'mail_service.dart';

MailService createMailService() => _WebMailService();

/// web 端没有原生 TCP 套接字，连不了 IMAP 服务器。
class _WebMailService implements MailService {
  @override
  Future<MailFetchResult> fetchRecentMails({
    required String email,
    required String authCode,
    int? sinceUid,
    int maxCount = 100,
  }) async {
    throw UnsupportedError('网页版无法连接邮箱服务器（IMAP 需要原生套接字），请使用安卓或桌面版。');
  }

  @override
  Future<MailFetchResult> fetchMailsInRange({
    required String email,
    required String authCode,
    required DateTime start,
    required DateTime end,
    int maxCount = 200,
  }) async {
    throw UnsupportedError('网页版无法连接邮箱服务器（IMAP 需要原生套接字），请使用安卓或桌面版。');
  }
}
