// findDuplicateEvent 判重逻辑测试。
//
// 覆盖 lib/services/event_dedup.dart：
//   - 同公司 + 5 分钟内 → 判重
//   - 场次事件 vs 截止事件 → 不判重（一个是日程、一个是期限）
//   - 两个截止事件：岗位/轮次不同 → 不判重（23:59 聚集是常态）
//   - 两个截止事件：同岗位同时刻 → 判重
import 'package:flutter_test/flutter_test.dart';
import 'package:interview_calendar/models/event.dart';
import 'package:interview_calendar/services/event_dedup.dart';

InterviewEvent _ev({
  required String title,
  String? company,
  String? role,
  InterviewRound? round,
  required DateTime startTime,
  bool isDeadline = false,
  DateTime? deadline,
}) {
  return InterviewEvent(
    title: title,
    company: company,
    role: role,
    round: round,
    startTime: startTime,
    isDeadline: isDeadline,
    deadline: deadline,
  );
}

void main() {
  final t = DateTime(2026, 10, 15, 23, 59);

  test('同公司 + 5 分钟内 → 判重', () {
    final existing = [
      _ev(title: '一面', company: 'Acme', startTime: t),
    ];
    final incoming = _ev(title: '一面', company: 'acme', startTime: t.add(const Duration(minutes: 3)));
    expect(findDuplicateEvent(incoming, existing), isNotNull);
  });

  test('超过 5 分钟 / 不同公司 → 不判重', () {
    final existing = [
      _ev(title: '一面', company: 'Acme', startTime: t),
    ];
    final later = _ev(title: '一面', company: 'Acme', startTime: t.add(const Duration(minutes: 10)));
    expect(findDuplicateEvent(later, existing), isNull);
    final other = _ev(title: '一面', company: 'Beta', startTime: t);
    expect(findDuplicateEvent(other, existing), isNull);
  });

  test('场次事件 vs 截止事件 → 不判重（即使同公司同时刻）', () {
    final existing = [
      _ev(title: '测评截止', company: 'Acme', isDeadline: true, startTime: t),
    ];
    final session = _ev(title: '一面', company: 'Acme', startTime: t);
    expect(findDuplicateEvent(session, existing), isNull,
        reason: '场次和截止是两种东西，不能互相覆盖');
    // 反向同理
    final deadline = _ev(title: '测评截止', company: 'Acme', isDeadline: true, startTime: t);
    expect(findDuplicateEvent(deadline, [
      _ev(title: '一面', company: 'Acme', startTime: t),
    ]), isNull);
  });

  test('两个截止事件：岗位不同 → 不判重（23:59 聚集是常态）', () {
    final existing = [
      _ev(title: '性格测评截止', company: 'Acme', role: '后端', isDeadline: true, startTime: t),
    ];
    final incoming = _ev(
        title: '网申截止', company: 'Acme', role: '前端', isDeadline: true, startTime: t);
    expect(findDuplicateEvent(incoming, existing), isNull,
        reason: '同公司同一天两个不同任务都 23:59 截止，不能被吞掉');
  });

  test('两个截止事件：同岗位同时刻 → 判重', () {
    final existing = [
      _ev(title: '测评截止', company: 'Acme', role: '后端', round: InterviewRound.assessment,
          isDeadline: true, startTime: t),
    ];
    final incoming = _ev(
        title: '测评截止', company: 'Acme', role: '后端', round: InterviewRound.assessment,
        isDeadline: true, startTime: t.add(const Duration(minutes: 2)));
    expect(findDuplicateEvent(incoming, existing), isNotNull);
  });

  test('截止事件：岗位其一为空 → 不因岗位否决（空视为未知）', () {
    final existing = [
      _ev(title: '测评截止', company: 'Acme', isDeadline: true, startTime: t),
    ];
    final incoming =
        _ev(title: '测评截止', company: 'Acme', role: '后端', isDeadline: true, startTime: t);
    expect(findDuplicateEvent(incoming, existing), isNotNull);
  });
}
