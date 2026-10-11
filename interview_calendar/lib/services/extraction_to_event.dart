import '../models/event.dart';
import 'llm_service.dart';

/// 把 AI 抽取结果转成 InterviewEvent。
/// AI 助手和邮箱导入共用这一份映射，避免两处各写一遍、以后字段对不上。
///
/// 返回 null 表示抽取结果里没有可用的时间（既无场次也无截止期限），建不了事件 ——
/// 调用方要先用 [isActionableExtraction] 过滤，正常流程不会走到 null。
InterviewEvent? eventFromExtraction(ExtractionResult r, {String? sourceNote}) {
  final anchor = r.startTime ?? r.deadline;
  if (anchor == null) return null;

  // 纯截止类（如测评「10月15日前完成」）：事件时间就是截止时间本身
  final deadlineOnly = r.startTime == null;

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
    startTime: anchor,
    endTime: deadlineOnly
        ? null
        : anchor.add(Duration(minutes: r.durationMinutes)),
    isDeadline: deadlineOnly,
    deadline: r.deadline,
    location: r.location.isNotEmpty ? r.location : null,
    meetingUrl: r.meetingUrl.isNotEmpty ? r.meetingUrl : null,
    notes: notes.isEmpty ? null : notes,
    color: EventColor.blue,
  );
}

/// 这条抽取结果值不值得进「待确认清单」？
///
/// 规则（纯函数，方便测试）：
///  - 出错的结果不要
///  - 类别要是需要跟进的：面试邀约 / 改期 / 笔试测评（isInterview 兜底）
///  - 至少要有一个时间锚点：固定场次或截止期限
///
/// 拒信、取消、offer、广告等不进清单 —— 它们不是需要马上行动的事。
bool isActionableExtraction(ExtractionResult r) {
  if (r.hasError) return false;

  // 黑名单先行否决：这些类别即使模型把 is_interview 误标成 true 也不进清单。
  // 尤其 cancel —— 改期/取消邮件里通常带着原定时间，一误标就会把「已取消的
  // 面试」加进日历。offer 不进清单（提示词层同样约定 is_interview=false）。
  const rejectedCategories = {'cancel', 'rejection', 'offer'};
  if (rejectedCategories.contains(r.category)) return false;

  const actionableCategories = {'interview_invite', 'reschedule', 'assessment'};
  if (!r.isInterview && !actionableCategories.contains(r.category)) return false;
  return r.hasTime;
}

/// 该类别的结果不该进日历（取消 / 拒信 / Offer）。
/// 邮箱导入用 [isActionableExtraction] 整体判定；AI 助手的手动保存链路
/// （用户粘什么都可能）用这个单独拦 —— 否则「已取消的面试」也能被存进日历。
bool isRejectedCategory(ExtractionResult r) =>
    r.category == 'cancel' ||
    r.category == 'rejection' ||
    r.category == 'offer';

InterviewRound? roundFromString(String round) {
  const map = {
    '一面': InterviewRound.first,
    '二面': InterviewRound.second,
    '三面': InterviewRound.third,
    '终面': InterviewRound.finalRound,
    'HR面': InterviewRound.hr,
    '笔试': InterviewRound.written,
    '测评': InterviewRound.assessment,
  };
  return map[round];
}
