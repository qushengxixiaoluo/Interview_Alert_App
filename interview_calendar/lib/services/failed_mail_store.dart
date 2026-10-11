import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// 识别失败的邮件：按 uid 记录累计失败次数。
///
/// 解决两头的矛盾：
///  - 闸门太松：失败邮件被游标跨过 → 永久丢信（需求 2 承诺「不会丢」）
///  - 闸门太死：一封永远失败的邮件让游标永久卡住 → 每次同步整窗重拉、重复计费
///
/// 做法：失败累计计数，达到 [maxAttempts] 次视为「反复失败、放弃」——
/// 不再阻塞游标（下轮同步可通过「识别范围」手动回扫），没到上限的继续拦。
///
/// **谁计数**：只有「邮件本身有问题」的失败（模型对这封邮件反复输出坏结果）。
/// 环境类失败（配置错、网络断、超时、限流）由调用方只拦游标、不计数 ——
/// 计了就会在几次网络故障后把整窗邮件全部「放弃」，环境恢复后反而被永久跳过。
class FailedMailStore {
  static const _kAttempts = 'mail_failed_attempts';
  static const int maxAttempts = 3;
  static const int _maxKeep = 500;

  static Map<String, int>? _cache;
  static String? lastError;

  static Future<Map<String, int>> _load() async {
    if (_cache != null) return _cache!;
    try {
      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 5));
      final raw = prefs.getString(_kAttempts);
      if (raw != null && raw.isNotEmpty) {
        _cache = (jsonDecode(raw) as Map<String, dynamic>)
            .map((k, v) => MapEntry(k, (v as num).toInt()));
      } else {
        _cache = <String, int>{};
      }
      lastError = null;
    } catch (e) {
      _cache = <String, int>{};
      lastError = '$e';
    }
    return _cache!;
  }

  static Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 5));
      await prefs.setString(_kAttempts, jsonEncode(_cache))
          .timeout(const Duration(seconds: 5));
      lastError = null;
    } catch (e) {
      lastError = '$e';
    }
  }

  /// 记一次失败（每次同步同一封最多记一次 —— 调用方按 run 去重）
  static Future<void> recordFailure(String uid) async {
    final map = await _load();
    map[uid] = (map[uid] ?? 0) + 1;
    // 超上限按「失败次数最多（已放弃）的优先删」剪枝 ——
    // 反着删会先把 1-2 次、还在拦游标的条目删掉，闸门直接失效放行丢信
    if (map.length > _maxKeep) {
      final sorted = map.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      for (final e in sorted.take(map.length - _maxKeep)) {
        map.remove(e.key);
      }
    }
    await _save();
  }

  /// 这封邮件后来识别成功了 → 清掉失败记录（重新做人）
  static Future<void> clearFailure(String uid) async {
    final map = await _load();
    if (map.remove(uid) != null) await _save();
  }

  static Future<int> attemptsOf(String uid) async =>
      (await _load())[uid] ?? 0;

  /// 这批失败的 uid 里还有没有「没到放弃次数、必须继续拦游标的」
  static Future<bool> hasBlocking(Iterable<String> uids) async {
    final map = await _load();
    for (final uid in uids) {
      if ((map[uid] ?? 0) < maxAttempts) return true;
    }
    return false;
  }

  /// 过滤掉已放弃（失败达上限）的条目
  static Future<List<T>> filterAbandoned<T>(
    List<T> items,
    String Function(T) uidOf,
  ) async {
    final map = await _load();
    return items
        .where((it) => (map[uidOf(it)] ?? 0) < maxAttempts)
        .toList();
  }
}
