import '../models/event.dart';
import 'database.dart';

/// 冲突检测结果
class ConflictCheck {
  final bool hasConflict;
  final List<InterviewEvent> conflictingEvents;
  final String message;

  const ConflictCheck({
    this.hasConflict = false,
    this.conflictingEvents = const [],
    this.message = '',
  });
}

/// 时间冲突检测器
class ConflictDetector {
  final DatabaseService _db;

  ConflictDetector(this._db);

  /// 检查新事件是否与已有事件冲突
  /// 冲突定义：两个事件的时间段有重叠
  Future<ConflictCheck> check({
    required DateTime newStart,
    required DateTime? newEnd,
    int? excludeEventId,
  }) async {
    final newEndTime = newEnd ?? newStart.add(const Duration(hours: 1));
    final allEvents = await _db.getAllEvents();

    final conflicts = <InterviewEvent>[];
    for (final event in allEvents) {
      // 排除自身（编辑场景）
      if (excludeEventId != null && event.id == excludeEventId) continue;

      final eventEnd = event.endTime ?? event.startTime.add(const Duration(hours: 1));

      // 时间段重叠检测：A.start < B.end && A.end > B.start
      if (newStart.isBefore(eventEnd) && newEndTime.isAfter(event.startTime)) {
        conflicts.add(event);
      }
    }

    if (conflicts.isEmpty) {
      return const ConflictCheck();
    }

    final buffer = StringBuffer('与 ${conflicts.length} 个已有事件冲突：\n');
    for (final c in conflicts) {
      buffer.write('· ${c.title}（${_formatTime(c.startTime)}）\n');
    }

    return ConflictCheck(
      hasConflict: true,
      conflictingEvents: conflicts,
      message: buffer.toString(),
    );
  }

  String _formatTime(DateTime dt) {
    return '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
