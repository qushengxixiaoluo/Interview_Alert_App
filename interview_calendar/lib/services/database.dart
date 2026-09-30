import '../models/event.dart';

// 条件导入：桌面/手机走 SQLite，浏览器走 localStorage。
// database_io.dart 里用到了 dart:io 和 sqflite，这两个在 web 上编译不过，
// 所以必须靠条件导入把它挡在 web 构建之外。
import 'database_io.dart' if (dart.library.js_interop) 'database_web.dart';

/// 事件存储接口
///
/// 实现分两套：
///  - SQLite（Windows / Android / iOS / macOS / Linux），数据落在应用支持目录
///  - localStorage（浏览器）
///
/// 两套都不在 App 的安装目录里存数据，所以更新代码、重新编译都不会丢记录。
abstract class DatabaseService {
  static DatabaseService? _instance;

  static DatabaseService get instance {
    _instance ??= createDatabaseService();
    return _instance!;
  }

  /// 存储是否持久化成功（false 表示退回了内存，关掉就没了）
  bool get isPersistent;

  /// 存储位置描述，用于在设置里展示，方便用户自己备份
  String get storageLocation;

  Future<int> insertEvent(InterviewEvent event);
  Future<int> updateEvent(InterviewEvent event);
  Future<int> deleteEvent(int id);
  Future<List<InterviewEvent>> getAllEvents();
  Future<List<InterviewEvent>> getEventsForMonth(DateTime month);
  Future<List<InterviewEvent>> getEventsForDay(DateTime day);
  Future<int> getEventCountForDay(DateTime day);

  /// 导出全部数据为 JSON 字符串（备份用）
  Future<String> exportJson();

  /// 从 JSON 恢复数据，返回导入条数
  Future<int> importJson(String json);
}

/// 供两套实现共用的查询逻辑，避免重复写一遍筛选代码
mixin EventQueryMixin implements DatabaseService {
  List<InterviewEvent> filterByMonth(List<InterviewEvent> all, DateTime month) {
    final start = DateTime(month.year, month.month - 1, 28);
    final end = DateTime(month.year, month.month + 1, 3);
    return all.where((e) => e.startTime.isAfter(start) && e.startTime.isBefore(end)).toList()
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
  }

  List<InterviewEvent> filterByDay(List<InterviewEvent> all, DateTime day) {
    final start = DateTime(day.year, day.month, day.day);
    final end = start.add(const Duration(days: 1));
    return all
        .where((e) =>
            !e.startTime.isBefore(start) && e.startTime.isBefore(end))
        .toList()
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
  }
}
