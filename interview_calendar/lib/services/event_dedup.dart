import 'package:flutter/material.dart';
import '../models/event.dart';

/// 重复面试的处理动作
enum DupAction { overwrite, skip, cancel }

/// 判断日历里是否已有「同一公司 + 相近开始时间」的面试（5 分钟内算重复）。
/// 邮箱导入和截图识别共用同一份判重逻辑，避免两处标准不一致。
InterviewEvent? findDuplicateEvent(InterviewEvent event, List<InterviewEvent> existing) {
  final company = (event.company ?? '').trim().toLowerCase();
  if (company.isEmpty) return null;
  for (final e in existing) {
    final eCompany = (e.company ?? '').trim().toLowerCase();
    if (eCompany == company &&
        e.startTime.difference(event.startTime).abs() <= const Duration(minutes: 5)) {
      return e;
    }
  }
  return null;
}

/// 弹窗问用户「日历里已有重复的，是否覆盖」。
/// [overwriteHint] 是问句里「是否用 X 覆盖它」的 X（邮件流程传「新邮件里的信息」）。
Future<DupAction?> showDuplicateDialog(
  BuildContext context, {
  required InterviewEvent event,
  required InterviewEvent dup,
  required String overwriteHint,
}) {
  return showDialog<DupAction>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('检测到重复面试'),
      content: Text(
        '日历里已有一条「${event.company}」在 ${_formatDateTime(dup.startTime)} 的面试。\n\n'
        '是否用$overwriteHint覆盖它？',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, DupAction.cancel),
          child: const Text('取消全部'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, DupAction.skip),
          child: const Text('跳过'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, DupAction.overwrite),
          child: const Text('覆盖'),
        ),
      ],
    ),
  );
}

String _formatDateTime(DateTime dt) {
  final weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  return '${dt.month}月${dt.day}日 ${weekdays[dt.weekday - 1]} '
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
}
