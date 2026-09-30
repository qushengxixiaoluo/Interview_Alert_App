import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/llm_profile.dart';

/// AI 配置档案的持久化存储。
///
/// 设计原则：**存储不可用也不能让 App 用不了**。
/// SharedPreferences 在 web / 桌面上偶尔会因为插件未注册、存储被禁用等原因
/// 抛异常或挂起，这时候退回内存存储，功能照常，只是关掉 App 后配置不保留。
class ProfileStore {
  static const _kProfiles = 'llm_profiles';
  static const _kActiveId = 'llm_active_profile';

  static List<LlmProfile>? _cache;
  static String? _activeIdCache;
  static bool _persistent = true;
  static String? _lastError;

  /// 存储是否可用。false 表示当前只在内存里，关掉就没了。
  static bool get isPersistent => _persistent;

  /// 最近一次存储错误的描述，用于在界面上提示
  static String? get lastError => _lastError;

  static Future<List<LlmProfile>> loadAll() async {
    if (_cache != null) return _cache!;

    try {
      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 5));
      final raw = prefs.getString(_kProfiles);

      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw) as List<dynamic>;
        final profiles = list
            .map((e) => LlmProfile.fromMap(Map<String, dynamic>.from(e as Map)))
            .toList();
        if (profiles.isNotEmpty) {
          _cache = profiles;
          return profiles;
        }
      }
      // 没有已存配置，写入预设
      _cache = LlmProfile.presets();
      await _writeAll(_cache!);
      return _cache!;
    } catch (e) {
      // 存储用不了，退回内存，App 继续可用
      _markUnavailable(e);
      _cache = LlmProfile.presets();
      return _cache!;
    }
  }

  static Future<void> saveAll(List<LlmProfile> profiles) async {
    _cache = profiles;
    await _writeAll(profiles);
  }

  static Future<void> _writeAll(List<LlmProfile> profiles) async {
    try {
      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 5));
      await prefs
          .setString(_kProfiles, jsonEncode(profiles.map((p) => p.toMap()).toList()))
          .timeout(const Duration(seconds: 5));
      _persistent = true;
      _lastError = null;
    } catch (e) {
      _markUnavailable(e);
    }
  }

  static Future<String?> loadActiveId() async {
    if (_activeIdCache != null) return _activeIdCache;
    try {
      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 5));
      _activeIdCache = prefs.getString(_kActiveId);
      return _activeIdCache;
    } catch (e) {
      _markUnavailable(e);
      return null;
    }
  }

  static Future<void> setActiveId(String id) async {
    _activeIdCache = id;
    try {
      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 5));
      await prefs.setString(_kActiveId, id).timeout(const Duration(seconds: 5));
    } catch (e) {
      _markUnavailable(e);
    }
  }

  static Future<LlmProfile?> loadActive() async {
    final profiles = await loadAll();
    if (profiles.isEmpty) return null;
    final activeId = await loadActiveId();
    return profiles.firstWhere(
      (p) => p.id == activeId,
      orElse: () => profiles.first,
    );
  }

  static Future<void> upsert(LlmProfile profile) async {
    final profiles = List<LlmProfile>.from(await loadAll());
    final index = profiles.indexWhere((p) => p.id == profile.id);
    if (index >= 0) {
      profiles[index] = profile;
    } else {
      profiles.add(profile);
    }
    await saveAll(profiles);
  }

  static Future<void> delete(String id) async {
    final profiles = List<LlmProfile>.from(await loadAll());
    profiles.removeWhere((p) => p.id == id);
    await saveAll(profiles);
    final activeId = await loadActiveId();
    if (activeId == id && profiles.isNotEmpty) {
      await setActiveId(profiles.first.id);
    }
  }

  static String newId() => 'p_${DateTime.now().microsecondsSinceEpoch}';

  static void _markUnavailable(Object e) {
    _persistent = false;
    _lastError = e.toString();
    if (kDebugMode) {
      debugPrint('[ProfileStore] 持久化存储不可用，已退回内存：$e');
    }
  }
}
