import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// 记录已经处理过（加入日历 / 明确忽略）的邮件标识，下次同步不再重复出现。
///
/// 面试邮件数量很少，用 SharedPreferences 存一个 JSON 数组足够；
/// 只增不减，但留一个上限兜底，防止极端情况下无限膨胀。
class ProcessedMailStore {
  static const _kProcessed = 'mail_processed_uids';
  static const int _maxKeep = 1000;

  static List<String>? _cache;

  static Future<Set<String>> load() async {
    if (_cache != null) return _cache!.toSet();
    try {
      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 5));
      final raw = prefs.getString(_kProcessed);
      if (raw != null && raw.isNotEmpty) {
        _cache = (jsonDecode(raw) as List<dynamic>).cast<String>();
      } else {
        _cache = <String>[];
      }
    } catch (_) {
      _cache = <String>[];
    }
    return _cache!.toSet();
  }

  static Future<void> markProcessed(Iterable<String> uids) async {
    final set = await load();
    set.addAll(uids);
    _cache = set.toList();
    if (_cache!.length > _maxKeep) {
      _cache = _cache!.sublist(_cache!.length - _maxKeep);
    }
    try {
      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 5));
      await prefs.setString(_kProcessed, jsonEncode(_cache))
          .timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  /// 从候选里过滤掉已处理的，返回「未处理」的邮件
  static Future<List<T>> filterUnprocessed<T>(
    List<T> items,
    String Function(T) uidOf,
  ) async {
    final processed = await load();
    return items.where((it) => !processed.contains(uidOf(it))).toList();
  }
}
