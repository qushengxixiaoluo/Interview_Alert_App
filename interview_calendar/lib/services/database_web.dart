import 'dart:convert';

import 'package:web/web.dart' as web;

import '../models/event.dart';
import 'database.dart';

/// 浏览器实现：localStorage
///
/// 注意：浏览器的存储按「域名 + 端口」隔离。用 `flutter run -d chrome`
/// 每次会分配随机端口，端口一变就相当于换了个存储空间，看起来像数据丢了。
/// 所以网页版要固定端口跑：
///     flutter run -d chrome --web-port=8080
class WebDatabaseService with EventQueryMixin implements DatabaseService {
  static const _key = 'interview_calendar_events_v1';

  final List<InterviewEvent> _events = [];
  int _nextId = 1;
  bool _persistent = true;
  String _lastError = '';

  WebDatabaseService() {
    _load();
  }

  /// localStorage 不可用时（隐私模式、存储被禁用）退回内存
  @override
  bool get isPersistent => _persistent;

  @override
  String get storageLocation => _persistent
      ? '浏览器 localStorage（键名 $_key）'
      : '内存（localStorage 不可用：$_lastError）';

  void _load() {
    try {
      final raw = web.window.localStorage.getItem(_key);
      if (raw == null || raw.isEmpty) return;
      final list = jsonDecode(raw) as List<dynamic>;
      for (final item in list) {
        final event = InterviewEvent.fromMap(Map<String, dynamic>.from(item as Map));
        _events.add(event);
        if ((event.id ?? 0) >= _nextId) _nextId = (event.id ?? 0) + 1;
      }
    } catch (e) {
      _persistent = false;
      _lastError = e.toString();
    }
  }

  void _save() {
    if (!_persistent) return;
    try {
      web.window.localStorage.setItem(
        _key,
        jsonEncode(_events.map((e) => e.toMap()).toList()),
      );
    } catch (e) {
      // 配额写满等情况下退回内存，功能不中断
      _persistent = false;
      _lastError = e.toString();
    }
  }

  @override
  Future<int> insertEvent(InterviewEvent event) async {
    final id = _nextId++;
    _events.add(event.copyWith(id: id));
    _save();
    return id;
  }

  @override
  Future<int> updateEvent(InterviewEvent event) async {
    if (event.id == null) return 0;
    final index = _events.indexWhere((e) => e.id == event.id);
    if (index < 0) return 0;
    _events[index] = event;
    _save();
    return 1;
  }

  @override
  Future<int> deleteEvent(int id) async {
    final before = _events.length;
    _events.removeWhere((e) => e.id == id);
    if (_events.length != before) _save();
    return before - _events.length;
  }

  @override
  Future<List<InterviewEvent>> getAllEvents() async {
    return List<InterviewEvent>.from(_events)
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
  }

  @override
  Future<List<InterviewEvent>> getEventsForMonth(DateTime month) async =>
      filterByMonth(_events, month);

  @override
  Future<List<InterviewEvent>> getEventsForDay(DateTime day) async =>
      filterByDay(_events, day);

  @override
  Future<int> getEventCountForDay(DateTime day) async =>
      (await getEventsForDay(day)).length;

  @override
  Future<String> exportJson() async => jsonEncode({
    'version': 1,
    'events': _events.map((e) => e.toMap()).toList(),
  });

  @override
  Future<int> importJson(String json) async {
    final data = jsonDecode(json);
    final rows = (data is Map ? data['events'] : data) as List<dynamic>;
    var count = 0;
    for (final raw in rows) {
      final m = Map<String, dynamic>.from(raw as Map);
      m['id'] = _nextId++;
      _events.add(InterviewEvent.fromMap(m));
      count++;
    }
    _save();
    return count;
  }
}

/// 条件导入要求的工厂函数
DatabaseService createDatabaseService() => WebDatabaseService();
