import 'package:flutter_test/flutter_test.dart';
import 'package:interview_calendar/models/event.dart';
import 'package:interview_calendar/services/ics_export.dart';

void main() {
  group('InterviewEvent.toMap/fromMap 往返', () {
    test('deadline、isDeadline、completedAt、round、color 全部保真', () {
      final deadline = DateTime(2026, 10, 15, 23, 59);
      final completedAt = DateTime(2026, 10, 12, 10, 30);
      final event = InterviewEvent(
        id: 42,
        title: '笔试',
        company: '某大厂',
        role: '后端工程师',
        round: InterviewRound.written,
        startTime: DateTime(2026, 10, 14, 19, 0),
        deadline: deadline,
        isDeadline: false,
        completedAt: completedAt,
        color: EventColor.purple,
      );

      final restored = InterviewEvent.fromMap(event.toMap());

      expect(restored.deadline, deadline);
      expect(restored.isDeadline, false);
      expect(restored.completedAt, completedAt);
      expect(restored.round, InterviewRound.written);
      expect(restored.color, EventColor.purple);
      expect(restored.title, '笔试');
      expect(restored.startTime, event.startTime);
      expect(restored.isCompleted, true);
    });

    test('isDeadline=true 时往返后仍是 true', () {
      final event = InterviewEvent(
        title: '10月15日前完成测评',
        startTime: DateTime(2026, 10, 15),
        isDeadline: true,
      );
      final restored = InterviewEvent.fromMap(event.toMap());
      expect(restored.isDeadline, true);
    });

    test('旧数据行缺 deadline/is_deadline/completed_at 键 → fromMap 不抛异常', () {
      // 旧版本写入的行没有这三个新字段
      final oldRow = <String, dynamic>{
        'id': 1,
        'title': '一面',
        'company': '老公司',
        'role': null,
        'round_index': 0,
        'start_time': DateTime(2026, 1, 1, 10).millisecondsSinceEpoch,
        'end_time': null,
        'location': null,
        'meeting_url': null,
        'color_index': 0,
        'notes': null,
        'created_at': DateTime(2026, 1, 1).millisecondsSinceEpoch,
        'updated_at': DateTime(2026, 1, 1).millisecondsSinceEpoch,
      };

      InterviewEvent? event;
      expect(() => event = InterviewEvent.fromMap(oldRow), returnsNormally);
      expect(event, isNotNull);
      // event 在闭包里被赋值（write-captured），flow analysis 不会把它提升成非空，
      // 所以每次访问都要显式 `!`。
      expect(event!.deadline, isNull);
      expect(event!.isDeadline, false);
      expect(event!.completedAt, isNull);
      expect(event!.isCompleted, false);
    });

    test('is_deadline 存成 int 1/0 → fromMap 正确转 bool', () {
      final base = <String, dynamic>{
        'title': '任务',
        'start_time': DateTime(2026, 10, 10).millisecondsSinceEpoch,
      };

      final asOne = InterviewEvent.fromMap({...base, 'is_deadline': 1});
      expect(asOne.isDeadline, true);

      final asZero = InterviewEvent.fromMap({...base, 'is_deadline': 0});
      expect(asZero.isDeadline, false);

      // toMap 落库永远是 int 1/0，不是 bool
      final trueEvent = InterviewEvent(
        title: '截止任务',
        startTime: DateTime(2026, 10, 10),
        isDeadline: true,
      );
      expect(trueEvent.toMap()['is_deadline'], 1);

      final falseEvent = InterviewEvent(
        title: '普通面试',
        startTime: DateTime(2026, 10, 10),
        isDeadline: false,
      );
      expect(falseEvent.toMap()['is_deadline'], 0);
    });
  });

  group('hasStarted / timeUntilCompletable', () {
    test('截止类事件（isDeadline=true）startTime 在未来 → 随时可完成', () {
      final event = InterviewEvent(
        title: '10月20日前完成测评',
        startTime: DateTime.now().add(const Duration(days: 3)),
        isDeadline: true,
      );
      expect(event.hasStarted, true);
      expect(event.timeUntilCompletable, isNull);
    });

    test('普通事件 startTime 在未来 → 未开始，timeUntilCompletable 非 null', () {
      final future = DateTime.now().add(const Duration(hours: 5));
      final event = InterviewEvent(title: '一面', startTime: future);
      expect(event.hasStarted, false);
      final remaining = event.timeUntilCompletable;
      expect(remaining, isNotNull);
      // 剩余时间应为正且不超过 5 小时（留出测试执行的余量）
      expect(remaining!.inMilliseconds, greaterThan(0));
      expect(remaining, lessThanOrEqualTo(const Duration(hours: 5)));
    });

    test('普通事件 startTime 已过去 → 已开始，timeUntilCompletable==null', () {
      final event = InterviewEvent(
        title: '一面',
        startTime: DateTime.now().subtract(const Duration(minutes: 10)),
      );
      expect(event.hasStarted, true);
      expect(event.timeUntilCompletable, isNull);
    });
  });

  group('copyWith', () {
    test('传 isDeadline:true 覆盖 false', () {
      final event = InterviewEvent(
        title: '测评',
        startTime: DateTime(2026, 10, 10),
        isDeadline: false,
      );
      final updated = event.copyWith(isDeadline: true);
      expect(updated.isDeadline, true);
      // 原对象不可变，不受影响
      expect(event.isDeadline, false);
    });

    test('不传 isDeadline 时保留原值（true 不被冲掉）', () {
      final event = InterviewEvent(
        title: '截止任务',
        startTime: DateTime(2026, 10, 10),
        isDeadline: true,
      );
      final updated = event.copyWith(title: '改个标题');
      expect(updated.isDeadline, true);
      expect(updated.title, '改个标题');
    });

    test('clearCompleted 置空 completedAt；默认保留原值', () {
      final event = InterviewEvent(
        title: '一面',
        startTime: DateTime(2026, 10, 10),
        completedAt: DateTime(2026, 10, 10, 12),
      );
      // 默认（不传 completedAt、不开 clearCompleted）→ 保留
      expect(event.copyWith(title: 'x').completedAt, event.completedAt);
      // 显式 clearCompleted → 置空（取消完成）
      final cleared = event.copyWith(clearCompleted: true);
      expect(cleared.completedAt, isNull);
      expect(cleared.isCompleted, false);
      // 传新 completedAt → 覆盖
      final newTime = DateTime(2026, 10, 11, 9);
      expect(event.copyWith(completedAt: newTime).completedAt, newTime);
    });
  });

  group('InterviewRound 枚举 index 约束', () {
    test('third 的 index 必须大于 other（新值只能追加到末尾）', () {
      // DB 按 index 存 round_index：往中间插值会让旧数据错位到别的轮次。
      // 这里把当前顺序写死，任何会让 other/third 换位的改动都会挂掉。
      expect(InterviewRound.first.index, 0);
      expect(InterviewRound.second.index, 1);
      expect(InterviewRound.finalRound.index, 2);
      expect(InterviewRound.written.index, 3);
      expect(InterviewRound.assessment.index, 4);
      expect(InterviewRound.hr.index, 5);
      expect(InterviewRound.other.index, 6);
      expect(InterviewRound.third.index, 7);
      // 核心约束：third 追加在 other 之后，index 更大
      expect(
        InterviewRound.third.index,
        greaterThan(InterviewRound.other.index),
      );
      // 只能追加：values 长度就是「已有值个数」，新增必须出现在末尾之后
      expect(InterviewRound.values.length, 8);
      expect(InterviewRound.values.last, InterviewRound.third);
    });
  });

  group('IcsExport.buildIcs', () {
    test('输出包含 VCALENDAR 包裹', () {
      final event = InterviewEvent(
        title: '一面',
        startTime: DateTime(2026, 10, 14, 10),
      );
      final ics = IcsExport.buildIcs([event]);
      expect(ics, contains('BEGIN:VCALENDAR'));
      expect(ics, contains('END:VCALENDAR'));
      expect(ics, contains('BEGIN:VEVENT'));
      expect(ics, contains('END:VEVENT'));
    });

    test('isDeadline 事件 SUMMARY 以「截止：」开头', () {
      final event = InterviewEvent(
        title: '完成测评',
        company: '某公司',
        startTime: DateTime(2026, 10, 15),
        isDeadline: true,
      );
      final ics = IcsExport.buildIcs([event]);
      final summary = _summaryOf(ics);
      expect(summary, startsWith('截止：'));
    });

    test('round=assessment 且非截止 → SUMMARY 以「测评：」开头', () {
      final event = InterviewEvent(
        title: '测评',
        company: '某公司',
        round: InterviewRound.assessment,
        startTime: DateTime(2026, 10, 14, 19),
        isDeadline: false,
      );
      final ics = IcsExport.buildIcs([event]);
      expect(_summaryOf(ics), startsWith('测评：'));
    });

    test('普通面试 → SUMMARY 以「面试：」开头', () {
      final event = InterviewEvent(
        title: '一面',
        company: '某公司',
        round: InterviewRound.first,
        startTime: DateTime(2026, 10, 14, 10),
      );
      final ics = IcsExport.buildIcs([event]);
      expect(_summaryOf(ics), startsWith('面试：'));
    });

    test('deadline!=null 且非截止 → DESCRIPTION 含「截止期限」', () {
      final event = InterviewEvent(
        title: '笔试',
        company: '某公司',
        round: InterviewRound.written,
        startTime: DateTime(2026, 10, 14, 19),
        deadline: DateTime(2026, 10, 16, 23, 59),
        isDeadline: false,
      );
      final ics = IcsExport.buildIcs([event]);
      expect(ics, contains('DESCRIPTION:'));
      expect(ics, contains('截止期限'));
      // 普通事件（deadline 为 null）不该出现「截止期限」
      final noDeadline = InterviewEvent(
        title: '一面',
        company: '某公司',
        startTime: DateTime(2026, 10, 14, 10),
      );
      expect(IcsExport.buildIcs([noDeadline]), isNot(contains('截止期限')));
    });

    test('截止类事件不写 DTEND（零时长，23:59 不会跨到次日）', () {
      final event = InterviewEvent(
        title: '测评截止',
        company: '某公司',
        round: InterviewRound.assessment,
        startTime: DateTime(2026, 10, 15, 23, 59),
        isDeadline: true,
      );
      final ics = IcsExport.buildIcs([event]);
      expect(ics, isNot(contains('DTEND:')), reason: '截止事件应省略 DTEND');
      expect(ics, contains('DTSTART:'));
      // 普通事件没有 endTime 时仍按惯例补 1 小时（保留 DTEND）
      final normal = InterviewEvent(
        title: '一面',
        startTime: DateTime(2026, 10, 15, 14),
      );
      expect(IcsExport.buildIcs([normal]), contains('DTEND:'));
    });
  });
}

/// 从 ICS 文本里取出第一条 SUMMARY 的值（跳过转义换行的场景本测试不涉及）
String _summaryOf(String ics) {
  final line = ics
      .split('\n')
      .firstWhere((l) => l.startsWith('SUMMARY:'), orElse: () => '');
  return line.startsWith('SUMMARY:') ? line.substring('SUMMARY:'.length) : '';
}
