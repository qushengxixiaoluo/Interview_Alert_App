import 'package:flutter/material.dart';

/// 事件颜色标记
enum EventColor {
  blue(0xFF4A90D9, '蓝色'),
  orange(0xFFFF8C42, '橙色'),
  green(0xFF22C55E, '绿色'),
  purple(0xFF7C3AED, '紫色'),
  red(0xFFEF4444, '红色'),
  teal(0xFF14B8A6, '青色');

  final int value;
  final String label;
  const EventColor(this.value, this.label);

  Color get color => Color(value);
}

/// 面试轮次
enum InterviewRound {
  first('一面'),
  second('二面'),
  finalRound('终面'),
  written('笔试'),
  assessment('测评'),
  hr('HR面'),
  other('其他');

  final String label;
  const InterviewRound(this.label);
}

/// 面试事件模型
class InterviewEvent {
  final int? id;
  final String title;
  final String? company;
  final String? role;
  final InterviewRound? round;
  final DateTime startTime;
  final DateTime? endTime;
  final String? location;
  final String? meetingUrl;
  final EventColor color;
  final String? notes;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// 标记完成的时刻。null 表示还没完成。
  /// 用时间戳而不是 bool：既能表达「有没有完成」，又留了「什么时候完成的」这个信息，
  /// 存储成本一样。
  final DateTime? completedAt;

  bool get isCompleted => completedAt != null;

  InterviewEvent({
    this.id,
    required this.title,
    this.company,
    this.role,
    this.round,
    required this.startTime,
    this.endTime,
    this.location,
    this.meetingUrl,
    this.color = EventColor.blue,
    this.notes,
    this.completedAt,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  /// 面试是否已经开始 —— 决定「标记完成」按钮能不能点。
  ///
  /// 提前标记完成会让「哪些面试还没参加」这个信息失真，
  /// 所以开始时间之前一律不允许。
  bool get hasStarted => !DateTime.now().isBefore(startTime);

  /// 距离可以标记完成还有多久（已经可以时返回 null）
  Duration? get timeUntilCompletable =>
      hasStarted ? null : startTime.difference(DateTime.now());

  /// 序列化成数据库行。
  ///
  /// 键名与 SQLite 表结构一一对应，桌面端、手机端、浏览器端共用这一份映射，
  /// 避免多处各写一遍、以后加字段漏改某处导致数据静默丢失。
  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'title': title,
      'company': company,
      'role': role,
      'round_index': round?.index,
      'start_time': startTime.millisecondsSinceEpoch,
      'end_time': endTime?.millisecondsSinceEpoch,
      'location': location,
      'meeting_url': meetingUrl,
      'color_index': color.index,
      'notes': notes,
      'completed_at': completedAt?.millisecondsSinceEpoch,
      'created_at': createdAt.millisecondsSinceEpoch,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };
  }

  /// 从数据库行还原。字段缺失时一律降级成默认值，不要抛异常 ——
  /// 旧版本写入的行没有新字段，读的时候炸掉会让整个日历打不开。
  factory InterviewEvent.fromMap(Map<String, dynamic> map) {
    int? asInt(dynamic v) => v is int ? v : (v is num ? v.toInt() : null);

    final roundIndex = asInt(map['round_index']);
    final colorIndex = asInt(map['color_index']);
    final startMs = asInt(map['start_time']);
    final endMs = asInt(map['end_time']);
    final completedMs = asInt(map['completed_at']);
    final createdMs = asInt(map['created_at']);
    final updatedMs = asInt(map['updated_at']);

    return InterviewEvent(
      id: asInt(map['id']),
      title: (map['title'] ?? '') as String,
      company: map['company'] as String?,
      role: map['role'] as String?,
      round: roundIndex != null && roundIndex >= 0 && roundIndex < InterviewRound.values.length
          ? InterviewRound.values[roundIndex]
          : null,
      startTime: DateTime.fromMillisecondsSinceEpoch(startMs ?? DateTime.now().millisecondsSinceEpoch),
      endTime: endMs != null ? DateTime.fromMillisecondsSinceEpoch(endMs) : null,
      location: map['location'] as String?,
      meetingUrl: map['meeting_url'] as String?,
      color: colorIndex != null && colorIndex >= 0 && colorIndex < EventColor.values.length
          ? EventColor.values[colorIndex]
          : EventColor.blue,
      notes: map['notes'] as String?,
      completedAt: completedMs != null ? DateTime.fromMillisecondsSinceEpoch(completedMs) : null,
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdMs ?? DateTime.now().millisecondsSinceEpoch),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(updatedMs ?? DateTime.now().millisecondsSinceEpoch),
    );
  }

  InterviewEvent copyWith({
    int? id,
    String? title,
    String? company,
    String? role,
    InterviewRound? round,
    DateTime? startTime,
    DateTime? endTime,
    String? location,
    String? meetingUrl,
    EventColor? color,
    String? notes,
    DateTime? completedAt,
    bool clearCompleted = false,
  }) {
    return InterviewEvent(
      id: id ?? this.id,
      title: title ?? this.title,
      company: company ?? this.company,
      role: role ?? this.role,
      round: round ?? this.round,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      location: location ?? this.location,
      meetingUrl: meetingUrl ?? this.meetingUrl,
      color: color ?? this.color,
      notes: notes ?? this.notes,
      // 置空需要用显式开关，否则「取消完成」会被 ?? 挡掉，取消不掉
      completedAt: clearCompleted ? null : (completedAt ?? this.completedAt),
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }
}

