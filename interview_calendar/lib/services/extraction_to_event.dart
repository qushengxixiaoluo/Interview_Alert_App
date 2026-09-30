import '../models/event.dart';
import 'llm_service.dart';

/// 把 AI 抽取结果转成 InterviewEvent。
/// AI 助手和邮箱导入共用这一份映射，避免两处各写一遍、以后字段对不上。
InterviewEvent eventFromExtraction(ExtractionResult r, {String? sourceNote}) {
  final notes = [
    if (r.contact.isNotEmpty) '联系人：${r.contact}',
    if (r.summary.isNotEmpty) r.summary,
    if (r.needsReview) '⚠ 待核对：${r.timeIsExplicit ? '置信度偏低' : '时间是推算的，请核对'}',
    if (sourceNote != null && sourceNote.isNotEmpty) sourceNote,
  ].join('\n');

  return InterviewEvent(
    title: r.title.isNotEmpty ? r.title : '事件',
    company: r.company.isNotEmpty ? r.company : null,
    role: r.role.isNotEmpty ? r.role : null,
    round: roundFromString(r.round),
    startTime: r.startTime!,
    endTime: r.startTime!.add(Duration(minutes: r.durationMinutes)),
    location: r.location.isNotEmpty ? r.location : null,
    meetingUrl: r.meetingUrl.isNotEmpty ? r.meetingUrl : null,
    notes: notes.isEmpty ? null : notes,
    color: EventColor.blue,
  );
}

InterviewRound? roundFromString(String round) {
  const map = {
    '一面': InterviewRound.first,
    '二面': InterviewRound.second,
    '终面': InterviewRound.finalRound,
    'HR面': InterviewRound.hr,
    '笔试': InterviewRound.written,
    '测评': InterviewRound.assessment,
  };
  return map[round];
}
