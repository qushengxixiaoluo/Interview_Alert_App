import 'package:shared_preferences/shared_preferences.dart';

/// 邮箱同步的「进度点」。
///
/// [lastUid] 是上次扫到的最新一封邮件的 IMAP UID（机器内部用的游标），
/// [newestMailDate] 是那封邮件的发信时间（给人看），
/// [syncedAt] 是游标推进时的本地时刻（发信时间缺失时兜底展示）。
class MailCursor {
  final int? lastUid;
  final DateTime? newestMailDate;
  final DateTime? syncedAt;

  const MailCursor({this.lastUid, this.newestMailDate, this.syncedAt});

  bool get hasSynced => lastUid != null;

  /// 给人看的那句「上次已同步到…」的时间点；发信时间缺失时退回本地同步时刻。
  DateTime? get displayTime => newestMailDate ?? syncedAt;
}

class MailCursorStore {
  static const _keyUid = 'mail_last_uid';
  static const _keyDate = 'mail_last_uid_date';
  static const _keySyncedAt = 'mail_last_synced_at';

  static Future<MailCursor> load() async {
    final prefs = await SharedPreferences.getInstance();
    final uid = prefs.getInt(_keyUid);
    final dateMs = prefs.getInt(_keyDate);
    final syncedMs = prefs.getInt(_keySyncedAt);
    return MailCursor(
      lastUid: uid,
      newestMailDate: dateMs != null
          ? DateTime.fromMillisecondsSinceEpoch(dateMs)
          : null,
      syncedAt: syncedMs != null
          ? DateTime.fromMillisecondsSinceEpoch(syncedMs)
          : null,
    );
  }

  /// 保存游标。[uid] 为 null 表示清空（从头再来）。
  /// [newestMailDate] 是游标那封邮件的发信时间，给人看；没有则只记本地时刻。
  static Future<void> save(int? uid, {DateTime? newestMailDate}) async {
    final prefs = await SharedPreferences.getInstance();
    if (uid == null) {
      await prefs.remove(_keyUid);
      await prefs.remove(_keyDate);
      await prefs.remove(_keySyncedAt);
      return;
    }
    await prefs.setInt(_keyUid, uid);
    await prefs.setInt(_keySyncedAt, DateTime.now().millisecondsSinceEpoch);
    if (newestMailDate != null) {
      await prefs.setInt(_keyDate, newestMailDate.millisecondsSinceEpoch);
    } else {
      await prefs.remove(_keyDate);
    }
  }
}
