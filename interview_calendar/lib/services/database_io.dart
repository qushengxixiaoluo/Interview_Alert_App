import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/event.dart';
import 'database.dart';

/// 工厂函数：桌面走 JSON 文件，手机走 SQLite。
///
/// 桌面端刻意不用 sqflite_common_ffi —— 它依赖 package:sqlite3，
/// 后者构建时要从 GitHub 下载原生库，而 GitHub 在国内直连会超时。
/// 更要命的是这个下载发生在安卓构建流程里（即使安卓根本用不到 FFI），
/// 会导致完全无关的 APK 打包失败。
DatabaseService createDatabaseService() {
  if (Platform.isAndroid || Platform.isIOS) {
    return SqliteDatabaseService();
  }
  return JsonFileDatabaseService();
}

// ============================================================
//  手机端：SQLite（系统自带，无外部依赖）
// ============================================================
class SqliteDatabaseService with EventQueryMixin implements DatabaseService {
  Database? _db;
  String? _dbPath;

  /// 当前表结构版本。**每次改表结构都要 +1，并在 _onUpgrade 里加上对应的迁移步骤。**
  /// 绝对不能靠 DROP TABLE 重建 —— 那会清空用户数据。
  ///
  /// v1 → v2：新增 completed_at（标记面试完成的时刻）
  static const int schemaVersion = 2;

  static const _table = 'events';

  @override
  bool get isPersistent => _db != null;

  @override
  String get storageLocation => _dbPath ?? '（尚未初始化）';

  Future<Database> get _database async {
    if (_db != null) return _db!;

    // Android / iOS 用系统自带 SQLite，不需要任何额外初始化。
    // 存储位置选「应用支持目录」：安卓落在应用私有目录，卸载才会清除。
    final dir = await getApplicationSupportDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _dbPath = p.join(dir.path, 'interview_calendar.db');

    _db = await openDatabase(
      _dbPath!,
      version: schemaVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
    return _db!;
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE $_table (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        title        TEXT    NOT NULL,
        company      TEXT,
        role         TEXT,
        round_index  INTEGER,
        start_time   INTEGER NOT NULL,
        end_time     INTEGER,
        location     TEXT,
        meeting_url  TEXT,
        color_index  INTEGER NOT NULL DEFAULT 0,
        notes        TEXT,
        completed_at INTEGER,
        created_at   INTEGER NOT NULL,
        updated_at   INTEGER NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX idx_start_time ON $_table (start_time)');
  }

  /// 结构升级。**只允许加字段 / 加表 / 加索引，永远不要 DROP 已有的东西。**
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    await _backupBeforeMigration(db, oldVersion);

    // v1 → v2：增加「完成时刻」。
    // 已有记录 completed_at 为 NULL，正好表示「未完成」，语义天然对齐。
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE $_table ADD COLUMN completed_at INTEGER');
    }
  }

  Future<void> _backupBeforeMigration(Database db, int fromVersion) async {
    try {
      final rows = await db.query(_table);
      final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
      final backup = File('${_dbPath!}.backup_v${fromVersion}_$stamp.json');
      await backup.writeAsString(jsonEncode(rows), encoding: utf8);
      debugPrint('[Database] 迁移前已备份 ${rows.length} 条到 ${backup.path}');
    } catch (e) {
      // 备份失败不应该阻断迁移，但必须留下痕迹
      debugPrint('[Database] 迁移前备份失败：$e');
    }
  }

  @override
  Future<int> insertEvent(InterviewEvent event) async {
    final db = await _database;
    final row = event.toMap()..remove('id');
    return db.insert(_table, row);
  }

  @override
  Future<int> updateEvent(InterviewEvent event) async {
    if (event.id == null) return 0;
    final db = await _database;
    return db.update(_table, event.toMap(), where: 'id = ?', whereArgs: [event.id]);
  }

  @override
  Future<int> deleteEvent(int id) async {
    final db = await _database;
    return db.delete(_table, where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<List<InterviewEvent>> getAllEvents() async {
    final db = await _database;
    final rows = await db.query(_table, orderBy: 'start_time ASC');
    return rows.map(InterviewEvent.fromMap).toList();
  }

  @override
  Future<List<InterviewEvent>> getEventsForMonth(DateTime month) async {
    final db = await _database;
    final start = DateTime(month.year, month.month - 1, 28);
    final end = DateTime(month.year, month.month + 1, 3);
    final rows = await db.query(
      _table,
      where: 'start_time >= ? AND start_time < ?',
      whereArgs: [start.millisecondsSinceEpoch, end.millisecondsSinceEpoch],
      orderBy: 'start_time ASC',
    );
    return rows.map(InterviewEvent.fromMap).toList();
  }

  @override
  Future<List<InterviewEvent>> getEventsForDay(DateTime day) async {
    final db = await _database;
    final start = DateTime(day.year, day.month, day.day);
    final end = start.add(const Duration(days: 1));
    final rows = await db.query(
      _table,
      where: 'start_time >= ? AND start_time < ?',
      whereArgs: [start.millisecondsSinceEpoch, end.millisecondsSinceEpoch],
      orderBy: 'start_time ASC',
    );
    return rows.map(InterviewEvent.fromMap).toList();
  }

  @override
  Future<int> getEventCountForDay(DateTime day) async =>
      (await getEventsForDay(day)).length;

  @override
  Future<String> exportJson() async {
    final db = await _database;
    final rows = await db.query(_table);
    return jsonEncode({'version': schemaVersion, 'events': rows});
  }

  @override
  Future<int> importJson(String json) async {
    final rows = _parseImport(json);
    final db = await _database;

    var count = 0;
    await db.transaction((txn) async {
      for (final row in rows) {
        row.remove('id'); // 重新分配 id，避免和现有记录冲突
        await txn.insert(_table, row);
        count++;
      }
    });
    return count;
  }
}

// ============================================================
//  桌面端：JSON 文件
// ============================================================
/// 桌面端的存储实现。
///
/// 为什么不用 SQLite：桌面没有系统自带的 SQLite 可用，而引入 FFI 实现
/// 会连带触发 GitHub 下载（见文件顶部说明）。个人日历数据量很小
/// （几百条记录、几十 KB），JSON 文件完全够用，而且带来两个额外好处：
/// 文件可以直接打开看、备份就是复制一个文件。
class JsonFileDatabaseService with EventQueryMixin implements DatabaseService {
  /// 当前数据格式版本，将来结构变化时用它做迁移
  static const int schemaVersion = 2;

  final List<InterviewEvent> _events = [];
  int _nextId = 1;
  File? _file;
  bool _loaded = false;
  bool _writable = true;
  String _lastError = '';

  @override
  bool get isPersistent => _writable && _loaded;

  @override
  String get storageLocation {
    if (!_writable && _lastError.isNotEmpty) {
      return '${_file?.path ?? '（尚未初始化）'}\n⚠ 读写失败：$_lastError';
    }
    return _file?.path ?? '（尚未初始化）';
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;

    try {
      final dir = await getApplicationSupportDirectory();
      if (!await dir.exists()) await dir.create(recursive: true);
      _file = File(p.join(dir.path, 'interview_calendar_events.json'));

      if (await _file!.exists()) {
        final raw = await _file!.readAsString(encoding: utf8);
        if (raw.trim().isNotEmpty) {
          final data = jsonDecode(raw);
          final list = (data is Map ? data['events'] : data) as List<dynamic>;
          for (final item in list) {
            final event = InterviewEvent.fromMap(Map<String, dynamic>.from(item as Map));
            _events.add(event);
            if ((event.id ?? 0) >= _nextId) _nextId = (event.id ?? 0) + 1;
          }
        }
      }
    } catch (e) {
      // 读不出来就用空列表继续，功能不中断，但要在界面上能看见原因
      _writable = false;
      _lastError = e.toString();
      debugPrint('[Database] 读取失败：$e');
    }
  }

  /// 原子写入：先写临时文件再改名。
  /// 直接覆盖原文件的话，写到一半断电/崩溃就会得到一个残缺的 JSON，
  /// 下次启动所有数据都读不出来。
  Future<void> _flush() async {
    await _ensureLoaded();
    if (!_writable || _file == null) return;

    try {
      final tmp = File('${_file!.path}.tmp');
      await tmp.writeAsString(
        jsonEncode({
          'version': schemaVersion,
          'events': _events.map((e) => e.toMap()).toList(),
        }),
        encoding: utf8,
      );
      await tmp.rename(_file!.path);
    } catch (e) {
      _writable = false;
      _lastError = e.toString();
      debugPrint('[Database] 写入失败：$e');
    }
  }

  @override
  Future<int> insertEvent(InterviewEvent event) async {
    await _ensureLoaded();
    final id = _nextId++;
    _events.add(event.copyWith(id: id));
    await _flush();
    return id;
  }

  @override
  Future<int> updateEvent(InterviewEvent event) async {
    await _ensureLoaded();
    if (event.id == null) return 0;
    final index = _events.indexWhere((e) => e.id == event.id);
    if (index < 0) return 0;
    _events[index] = event;
    await _flush();
    return 1;
  }

  @override
  Future<int> deleteEvent(int id) async {
    await _ensureLoaded();
    final before = _events.length;
    _events.removeWhere((e) => e.id == id);
    if (_events.length != before) await _flush();
    return before - _events.length;
  }

  @override
  Future<List<InterviewEvent>> getAllEvents() async {
    await _ensureLoaded();
    return List<InterviewEvent>.from(_events)
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
  }

  @override
  Future<List<InterviewEvent>> getEventsForMonth(DateTime month) async {
    await _ensureLoaded();
    return filterByMonth(_events, month);
  }

  @override
  Future<List<InterviewEvent>> getEventsForDay(DateTime day) async {
    await _ensureLoaded();
    return filterByDay(_events, day);
  }

  @override
  Future<int> getEventCountForDay(DateTime day) async =>
      (await getEventsForDay(day)).length;

  @override
  Future<String> exportJson() async {
    await _ensureLoaded();
    return jsonEncode({
      'version': schemaVersion,
      'events': _events.map((e) => e.toMap()).toList(),
    });
  }

  @override
  Future<int> importJson(String json) async {
    await _ensureLoaded();
    final rows = _parseImport(json);
    var count = 0;
    for (final row in rows) {
      final m = Map<String, dynamic>.from(row);
      m['id'] = _nextId++; // 重新分配 id，避免和现有记录冲突
      _events.add(InterviewEvent.fromMap(m));
      count++;
    }
    await _flush();
    return count;
  }
}

/// 解析导入的备份内容。兼容两种格式：
///  - `{"version":2,"events":[...]}`（本 App 导出的）
///  - `[...]`（裸数组，SQLite 迁移备份也是这个形状）
List<Map<String, dynamic>> _parseImport(String json) {
  final data = jsonDecode(json);
  final raw = (data is Map ? data['events'] : data) as List<dynamic>;
  return raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
}
