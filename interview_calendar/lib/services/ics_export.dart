import '../models/event.dart';

// 条件导入：桌面/手机用临时文件 + 系统分享，浏览器直接把字节交给分享 API。
// 不能直接 import dart:io —— 那会让 web 编译失败。
import 'ics_share_io.dart' if (dart.library.js_interop) 'ics_share_web.dart' as sharer;

/// ICS（iCalendar）文件生成与导出
///
/// ICS 是通用的日历文件格式。导出后可以发给别人，
/// 对方点开就能把这条安排导入到自己手机的日历里。
class IcsExport {
  /// 导出单个事件并调起分享，返回结果描述（供界面提示）
  static Future<String> shareEvent(InterviewEvent event) {
    final content = buildIcs([event]);
    return sharer.shareIcsFile(
      content,
      '${_safeFileName(event)}.ics',
      '面试安排：${event.title}',
    );
  }

  /// 批量导出
  static Future<String> shareEvents(List<InterviewEvent> events, {String? filename}) {
    final content = buildIcs(events);
    return sharer.shareIcsFile(
      content,
      filename ?? '面试安排_${events.length}条.ics',
      '面试安排（共 ${events.length} 条）',
    );
  }

  /// 生成 ICS 文本内容（不涉及文件系统，方便单独测试）
  static String buildIcs(List<InterviewEvent> events) {
    final buffer = StringBuffer()
      ..writeln('BEGIN:VCALENDAR')
      ..writeln('VERSION:2.0')
      ..writeln('PRODID:-//InterviewCalendar//CN')
      ..writeln('CALSCALE:GREGORIAN')
      ..writeln('X-WR-CALNAME:面试安排')
      ..writeln('X-WR-TIMEZONE:Asia/Shanghai');

    for (final event in events) {
      _writeEvent(buffer, event);
    }

    buffer.writeln('END:VCALENDAR');
    return buffer.toString();
  }

  static void _writeEvent(StringBuffer buffer, InterviewEvent event) {
    final uid = 'event-${event.id ?? DateTime.now().millisecondsSinceEpoch}@interview-calendar.local';
    final dtstart = _formatUtc(event.startTime);
    // 截止类事件没有「持续一小时」的语义：不写 DTEND（RFC 5545 视为零时长事件），
    // 否则 23:59 的截止会被外部日历画到第二天 00:59，次日还冒出一个点。
    // 普通事件没设结束时间时仍按惯例补 1 小时。
    final dtend = event.isDeadline
        ? null
        : _formatUtc(
            event.endTime ?? event.startTime.add(const Duration(hours: 1)),
          );

    buffer
      ..writeln('BEGIN:VEVENT')
      ..writeln('UID:$uid')
      ..writeln('DTSTAMP:${_formatUtc(DateTime.now())}')
      ..writeln('SEQUENCE:0')
      // 时间一律用 UTC 字面量：带 TZID 却缺少匹配的 VTIMEZONE 时，
      // 部分客户端会整体偏移 8 小时
      ..writeln('DTSTART:$dtstart');
    if (dtend != null) {
      buffer.writeln('DTEND:$dtend');
    }
    buffer.writeln('SUMMARY:${_escape(_buildSummary(event))}');

    if (event.location != null && event.location!.isNotEmpty) {
      buffer.writeln('LOCATION:${_escape(event.location!)}');
    }
    if (event.meetingUrl != null && event.meetingUrl!.isNotEmpty) {
      buffer.writeln('URL:${event.meetingUrl}');
    }

    final description = _buildDescription(event);
    if (description.isNotEmpty) {
      buffer.writeln('DESCRIPTION:${_escape(description)}');
    }

    // 两个提醒：提前 1 天和提前 1 小时。
    // ACTION:DISPLAY 时 DESCRIPTION 是 RFC 5545 必填项，缺了会被解析器整段丢弃。
    for (final trigger in ['-P1D', '-PT1H']) {
      buffer
        ..writeln('BEGIN:VALARM')
        ..writeln('TRIGGER:$trigger')
        ..writeln('ACTION:DISPLAY')
        ..writeln('DESCRIPTION:${event.isDeadline ? '截止提醒' : '面试提醒'}')
        ..writeln('END:VALARM');
    }

    buffer.writeln('END:VEVENT');
  }

  static String _buildSummary(InterviewEvent event) {
    // 按事件性质选前缀：截止类 → 「截止」；笔试/测评 → 用轮次名；其余 → 「面试」
    final String prefix;
    if (event.isDeadline) {
      prefix = '截止';
    } else if (event.round == InterviewRound.assessment ||
        event.round == InterviewRound.written) {
      prefix = event.round!.label;
    } else {
      prefix = '面试';
    }

    var title = event.company != null && event.company!.isNotEmpty
        ? '$prefix：${event.company}'
        : prefix;
    if (event.role != null && event.role!.isNotEmpty) title += ' - ${event.role}';
    if (event.round != null && !event.isDeadline) title += '（${event.round!.label}）';
    return title;
  }

  static String _buildDescription(InterviewEvent event) {
    final lines = <String>[];
    if (event.company != null && event.company!.isNotEmpty) lines.add('公司：${event.company}');
    if (event.role != null && event.role!.isNotEmpty) lines.add('岗位：${event.role}');
    if (event.round != null) lines.add('轮次：${event.round!.label}');
    if (event.isDeadline) lines.add('这是截止时间，在此之前完成即可');
    if (event.deadline != null && !event.isDeadline) {
      lines.add('截止期限：${_formatLocal(event.deadline!)}');
    }
    if (event.location != null && event.location!.isNotEmpty) lines.add('地点：${event.location}');
    if (event.meetingUrl != null && event.meetingUrl!.isNotEmpty) lines.add('会议链接：${event.meetingUrl}');
    if (event.notes != null && event.notes!.isNotEmpty) {
      lines
        ..add('')
        ..add(event.notes!);
    }
    return lines.join('\\n');
  }

  static String _formatLocal(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
  }

  static String _formatUtc(DateTime dt) {
    final u = dt.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${u.year.toString().padLeft(4, '0')}${two(u.month)}${two(u.day)}'
        'T${two(u.hour)}${two(u.minute)}${two(u.second)}Z';
  }

  static String _escape(String text) => text
      .replaceAll('\\', '\\\\')
      .replaceAll(';', '\\;')
      .replaceAll(',', '\\,')
      .replaceAll('\r\n', '\\n')
      .replaceAll('\n', '\\n');

  /// 文件名里不能出现这些字符，否则部分系统会拒绝写入
  static String _safeFileName(InterviewEvent event) {
    final raw = event.title.trim().isEmpty ? '面试安排' : event.title.trim();
    return raw.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }
}
