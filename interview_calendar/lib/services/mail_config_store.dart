import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一份 QQ 邮箱配置（支持保存多份，随时切换同步用哪份）
class MailConfig {
  final String id;

  /// 自定义名称（如「QQ 主号」），为空时用邮箱地址展示
  final String name;
  final String email;
  final String authCode;

  const MailConfig({
    required this.id,
    this.name = '',
    this.email = '',
    this.authCode = '',
  });

  bool get isConfigured => email.trim().isNotEmpty && authCode.trim().isNotEmpty;

  String get displayName {
    final n = name.trim();
    if (n.isNotEmpty) return n;
    final e = email.trim();
    return e.isEmpty ? '未命名邮箱' : e;
  }

  MailConfig copyWith({String? name, String? email, String? authCode}) => MailConfig(
        id: id,
        name: name ?? this.name,
        email: email ?? this.email,
        authCode: authCode ?? this.authCode,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'email': email,
        'authCode': authCode,
      };

  factory MailConfig.fromMap(Map<String, dynamic> m) => MailConfig(
        id: (m['id'] ?? '').toString().isEmpty
            ? 'mc_${DateTime.now().microsecondsSinceEpoch}'
            : m['id'].toString(),
        name: (m['name'] ?? '').toString(),
        email: (m['email'] ?? '').toString(),
        authCode: (m['authCode'] ?? '').toString(),
      );
}

/// 邮箱配置的持久化存储：多份配置 + 一份「使用中」。
///
/// 和 AI 档案（ProfileStore）同样存 SharedPreferences：
/// flutter_secure_storage 在部分手机上重启后读不到值（等于没保存），
/// 而 SharedPreferences 一直稳定。旧版本存在加密存储里的授权码，
/// 首次读取时会自动迁移进配置列表，不会丢。
class MailConfigStore {
  static const _kList = 'mail_configs';
  static const _kActiveId = 'mail_active_id';

  // 旧版单账号的两个 key，只用于迁移
  static const _kLegacyEmail = 'mail_email';
  static const _kLegacyAuthCode = 'mail_auth_code';

  /// 只用来迁移旧数据，新数据不再往里写
  static const _secure = FlutterSecureStorage();

  /// 上次读取时的持久化状态。false 表示存储不可用，仅内存里还有值。
  static bool _persistent = true;
  static String? _lastError;

  static bool get isPersistent => _persistent;
  static String? get lastError => _lastError;

  static String newId() => 'mc_${DateTime.now().microsecondsSinceEpoch}';

  static Future<List<MailConfig>> loadAll() async {
    try {
      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 5));
      final raw = prefs.getString(_kList);

      if (raw == null || raw.isEmpty) {
        return _migrateLegacy(prefs);
      }

      final list = (jsonDecode(raw) as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .map(MailConfig.fromMap)
          .toList();
      _persistent = true;
      return list;
    } catch (e) {
      _persistent = false;
      _lastError = e.toString();
      return const [];
    }
  }

  /// 当前「使用中」的配置；一份配置都没有时返回 null
  static Future<MailConfig?> loadActive() async {
    final all = await loadAll();
    if (all.isEmpty) return null;
    try {
      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 5));
      final activeId = prefs.getString(_kActiveId);
      return all.firstWhere((c) => c.id == activeId, orElse: () => all.first);
    } catch (_) {
      return all.first;
    }
  }

  static Future<void> setActiveId(String id) async {
    try {
      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 5));
      await prefs.setString(_kActiveId, id).timeout(const Duration(seconds: 5));
      _persistent = true;
    } catch (e) {
      _persistent = false;
      _lastError = e.toString();
    }
  }

  static Future<void> upsert(MailConfig config) async {
    try {
      final list = await loadAll();
      final index = list.indexWhere((c) => c.id == config.id);
      if (index >= 0) {
        list[index] = config;
      } else {
        list.add(config);
      }
      await _writeAll(list);

      // 第一份配置自动设为使用中
      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 5));
      final activeId = prefs.getString(_kActiveId);
      if (activeId == null || activeId.isEmpty) {
        await prefs.setString(_kActiveId, config.id);
      }
      _persistent = true;
    } catch (e) {
      _persistent = false;
      _lastError = e.toString();
    }
  }

  static Future<void> delete(String id) async {
    try {
      final list = await loadAll();
      list.removeWhere((c) => c.id == id);
      await _writeAll(list);

      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 5));
      final activeId = prefs.getString(_kActiveId);
      if (activeId == id) {
        if (list.isNotEmpty) {
          await prefs.setString(_kActiveId, list.first.id);
        } else {
          await prefs.remove(_kActiveId);
        }
      }
      _persistent = true;
    } catch (e) {
      _persistent = false;
      _lastError = e.toString();
    }
  }

  static Future<void> _writeAll(List<MailConfig> list) async {
    final prefs = await SharedPreferences.getInstance()
        .timeout(const Duration(seconds: 5));
    await prefs
        .setString(_kList, jsonEncode(list.map((c) => c.toMap()).toList()))
        .timeout(const Duration(seconds: 5));
  }

  /// 旧版单账号数据 → 迁移进配置列表
  static Future<List<MailConfig>> _migrateLegacy(SharedPreferences prefs) async {
    final legacyEmail = prefs.getString(_kLegacyEmail) ?? '';
    if (legacyEmail.isEmpty) {
      _persistent = true;
      return const [];
    }

    // 授权码：先读 SharedPreferences，再兜底读加密存储（更早的版本）
    var authCode = prefs.getString(_kLegacyAuthCode) ?? '';
    if (authCode.isEmpty) {
      try {
        final legacy = await _secure
            .read(key: _kLegacyAuthCode)
            .timeout(const Duration(seconds: 5));
        if (legacy != null && legacy.isNotEmpty) authCode = legacy;
      } catch (_) {
        // 读不到就当作没有，不影响迁移
      }
    }

    final migrated = MailConfig(
      id: newId(),
      name: '',
      email: legacyEmail,
      authCode: authCode,
    );
    await _writeAll([migrated]);
    await prefs.setString(_kActiveId, migrated.id);

    await prefs.remove(_kLegacyEmail);
    await prefs.remove(_kLegacyAuthCode);
    try {
      await _secure.delete(key: _kLegacyAuthCode);
    } catch (_) {}

    _persistent = true;
    return [migrated];
  }
}
