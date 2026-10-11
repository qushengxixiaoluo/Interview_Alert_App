import 'package:flutter_test/flutter_test.dart';
import 'package:interview_calendar/models/event.dart';
import 'package:interview_calendar/services/extraction_to_event.dart';
import 'package:interview_calendar/services/llm_service.dart';

/// ExtractionResult 解析（llm_service.dart）+ 抽取结果 → 事件映射（extraction_to_event.dart）
///
/// 全部是纯 Dart 逻辑，不需要 WidgetTester；本文件不发网络请求，
/// 但按约定每个用例前清一次 LlmService 的静态地址探测缓存，避免串测试。
void main() {
  setUp(LlmService.resetEndpointCache);

  group('ExtractionResult.fromJson', () {
    test('deadline：ISO 8601 带时区 → toLocal 正确；interview_start 为 null', () {
      final r = ExtractionResult.fromJson(
        '{"is_interview": false, "category": "assessment", '
        '"summary": "测评需在截止前完成", '
        '"interview_start": null, "deadline": "2026-10-15T23:59:00+08:00"}',
      );

      expect(r.hasError, isFalse);
      expect(r.startTime, isNull);
      expect(r.deadline, isNotNull);
      // 解析后必须是本地时间，且时刻与带时区的原始值一致
      expect(r.deadline, DateTime.parse('2026-10-15T23:59:00+08:00').toLocal());
      expect(r.deadline!.isUtc, isFalse);
      expect(r.isDeadlineOnly, isTrue);
      expect(r.hasTime, isTrue);
    });

    test('非 JSON 字符串 → hasError 且 errorKind == output', () {
      final r = ExtractionResult.fromJson('随便一段话');

      expect(r.hasError, isTrue);
      expect(r.errorKind, LlmErrorKind.output);
      expect(r.error, contains('解析模型输出失败'));
    });

    test('_mapRound：英文 / 中文 round 都映射成中文', () {
      String roundOf(String s) =>
          ExtractionResult.fromJson('{"round": "$s"}').round;

      expect(roundOf('assessment'), '测评');
      expect(roundOf('测评'), '测评');
      expect(roundOf('笔试'), '笔试');
      expect(roundOf('written'), '笔试');
      expect(roundOf('三面'), '三面');
      expect(roundOf('third'), '三面');
      expect(roundOf('first'), '一面');
      expect(roundOf('终面'), '终面');
      // 不认识的轮次原样保留
      expect(roundOf('交叉面'), '交叉面');
    });
  });

  group('ExtractionResult.fromTaskJson', () {
    test('due_time + is_deadline=true → startTime 为 null、deadline 有值', () {
      final due = DateTime.parse('2026-10-20T18:00:00+08:00').toLocal();
      final r = ExtractionResult.fromTaskJson({
        'title': '完成性格测评',
        'due_time': '2026-10-20T18:00:00+08:00',
        'is_deadline': true,
      });

      expect(r.startTime, isNull);
      expect(r.deadline, due);
      expect(r.isDeadlineOnly, isTrue);
      expect(r.hasTime, isTrue);
      expect(r.isInterview, isTrue); // 截图任务固定按面试处理
    });

    test('due_time + is_deadline=false → startTime 有值', () {
      final due = DateTime.parse('2026-10-20T18:00:00+08:00').toLocal();
      final r = ExtractionResult.fromTaskJson({
        'title': '三面',
        'due_time': '2026-10-20T18:00:00+08:00',
        'is_deadline': false,
      });

      expect(r.startTime, due);
      expect(r.deadline, isNull); // 没给 deadline 字段 → null
      expect(r.isDeadlineOnly, isFalse);
      expect(r.hasTime, isTrue);
    });
  });

  group('roundFromString', () {
    test('中文轮次 → 对应枚举', () {
      expect(roundFromString('测评'), InterviewRound.assessment);
      expect(roundFromString('三面'), InterviewRound.third);
      expect(roundFromString('一面'), InterviewRound.first);
      expect(roundFromString('二面'), InterviewRound.second);
      expect(roundFromString('终面'), InterviewRound.finalRound);
      expect(roundFromString('笔试'), InterviewRound.written);
      expect(roundFromString('HR面'), InterviewRound.hr);
    });

    test('不认识的轮次 → null', () {
      expect(roundFromString('交叉面'), isNull);
      expect(roundFromString(''), isNull);
    });
  });

  group('isActionableExtraction', () {
    final someTime = DateTime.parse('2026-10-20T18:00:00+08:00').toLocal();

    test('出错的结果 → false', () {
      final r = ExtractionResult(
        error: '解析模型输出失败',
        errorKind: LlmErrorKind.output,
        category: 'assessment',
        deadline: someTime,
      );
      expect(isActionableExtraction(r), isFalse);
    });

    test('category=assessment 且只有 deadline → true', () {
      final r = ExtractionResult(category: 'assessment', deadline: someTime);
      expect(r.isDeadlineOnly, isTrue);
      expect(isActionableExtraction(r), isTrue);
    });

    test('category=rejection → false（即使有时间）', () {
      final r = ExtractionResult(category: 'rejection', startTime: someTime);
      expect(isActionableExtraction(r), isFalse);
    });

    test('category=other 且 isInterview=false → false（即使有时间）', () {
      final r = ExtractionResult(category: 'other', startTime: someTime);
      expect(r.isInterview, isFalse);
      expect(isActionableExtraction(r), isFalse);
    });

    test('isInterview=true 但没有任何时间 → false', () {
      const r = ExtractionResult(isInterview: true, category: 'interview_invite');
      expect(r.hasTime, isFalse);
      expect(isActionableExtraction(r), isFalse);
    });

    // 黑名单否决：模型把 is_interview 误标 true 也不能放进来
    test('category=cancel 且 isInterview=true → false（黑名单否决）', () {
      final r = ExtractionResult(
        isInterview: true,
        category: 'cancel',
        startTime: someTime,
      );
      expect(isActionableExtraction(r), isFalse);
    });

    test('category=rejection 且 isInterview=true → false（黑名单否决）', () {
      final r = ExtractionResult(
        isInterview: true,
        category: 'rejection',
        startTime: someTime,
      );
      expect(isActionableExtraction(r), isFalse);
    });

    test('category=offer 且带截止时间 → false（offer 不进清单）', () {
      final r = ExtractionResult(category: 'offer', deadline: someTime);
      expect(isActionableExtraction(r), isFalse);
    });

    test('needsReview 不以 isInterview 为前提：纯截止测评也要核对', () {
      final r = ExtractionResult(
        isInterview: false,
        category: 'assessment',
        deadline: someTime,
        timeIsExplicit: false,
        confidence: 0.9,
      );
      expect(r.needsReview, isTrue,
          reason: 'is_interview=false 的测评，时间是推算的同样要提示核对');
      // 时间明确且置信度够 → 不用核对
      final ok = ExtractionResult(
        isInterview: false,
        category: 'assessment',
        deadline: someTime,
        timeIsExplicit: true,
        confidence: 0.9,
      );
      expect(ok.needsReview, isFalse);
      // 没有任何时间锚点 → 不谈核对
      const noTime = ExtractionResult(
        isInterview: true,
        timeIsExplicit: false,
        confidence: 0.5,
      );
      expect(noTime.needsReview, isFalse);
    });

    test('category=interview_invite 有 startTime → true', () {
      final r = ExtractionResult(
        isInterview: true,
        category: 'interview_invite',
        startTime: someTime,
      );
      expect(isActionableExtraction(r), isTrue);
    });

    test('category=reschedule 有时间 → true', () {
      final r = ExtractionResult(category: 'reschedule', startTime: someTime);
      expect(isActionableExtraction(r), isTrue);
    });
  });

  group('eventFromExtraction', () {
    test('纯截止：startTime 取 deadline、endTime 为 null、isDeadline=true', () {
      final dl = DateTime.parse('2026-10-15T23:59:00+08:00').toLocal();
      final r = ExtractionResult(
        title: '性格测评',
        category: 'assessment',
        deadline: dl,
        summary: '测评链接已发，15 号前完成',
      );

      final e = eventFromExtraction(r, sourceNote: '来自邮件：校招测评通知');
      expect(e, isNotNull);
      final event = e!;
      expect(event.isDeadline, isTrue);
      expect(event.startTime, dl);
      expect(event.deadline, dl);
      expect(event.endTime, isNull);
      // notes 同时包含摘要和 sourceNote
      expect(event.notes, contains('测评链接已发，15 号前完成'));
      expect(event.notes, contains('来自邮件：校招测评通知'));
    });

    test('有固定场次：endTime = startTime + duration，deadline 保留', () {
      final start = DateTime.parse('2026-10-20T14:00:00+08:00').toLocal();
      final dl = DateTime.parse('2026-10-19T23:59:00+08:00').toLocal();
      final r = ExtractionResult(
        isInterview: true,
        title: '三面',
        company: '某大厂',
        round: '三面',
        startTime: start,
        deadline: dl,
        durationMinutes: 90,
        timeIsExplicit: true,
        confidence: 0.9,
      );

      final e = eventFromExtraction(r);
      expect(e, isNotNull);
      final event = e!;
      expect(event.isDeadline, isFalse);
      expect(event.startTime, start);
      expect(event.endTime, start.add(const Duration(minutes: 90)));
      expect(event.deadline, dl); // 附加截止期限被保留
      // round 经 roundFromString 转成枚举
      expect(event.round, roundFromString(r.round));
      expect(event.round, InterviewRound.third);
      expect(event.company, '某大厂');
    });

    test('startTime 和 deadline 都为 null → 返回 null', () {
      expect(eventFromExtraction(const ExtractionResult(title: '没有时间')),
          isNull);
    });
  });
}
