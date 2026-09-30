import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../models/llm_profile.dart';

/// 连接测试结果
class TestResult {
  final bool ok;
  final String message;
  final int? statusCode;
  final int? elapsedMs;

  const TestResult({required this.ok, required this.message, this.statusCode, this.elapsedMs});
}

/// LLM 抽取结果
class ExtractionResult {
  final bool isInterview;
  final String title;
  final String company;
  final String role;
  final String round;
  final DateTime? startTime;
  final int durationMinutes;
  final bool timeIsExplicit;
  final String location;
  final String meetingUrl;
  final String contact;
  final String notes;
  final double confidence;
  final String category;
  final String summary;
  final String rawJson;
  final String? error;

  const ExtractionResult({
    this.isInterview = false,
    this.title = '',
    this.company = '',
    this.role = '',
    this.round = '',
    this.startTime,
    this.durationMinutes = 60,
    this.timeIsExplicit = false,
    this.location = '',
    this.meetingUrl = '',
    this.contact = '',
    this.notes = '',
    this.confidence = 0.0,
    this.category = 'other',
    this.summary = '',
    this.rawJson = '',
    this.error,
  });

  bool get hasError => error != null;
  bool get needsReview => isInterview && (!timeIsExplicit || confidence < 0.75);

  factory ExtractionResult.fromJson(String jsonStr) {
    try {
      final Map<String, dynamic> m = _decodeLenient(jsonStr);
      return ExtractionResult(
        isInterview: m['is_interview'] == true,
        title: _buildTitle(m),
        company: (m['company'] ?? '').toString(),
        role: (m['role'] ?? '').toString(),
        round: _mapRound(m['round']),
        startTime: _parseTime(m['interview_start']),
        durationMinutes: _toInt(m['duration_minutes'], 60),
        timeIsExplicit: m['time_is_explicit'] == true,
        location: (m['location'] ?? '').toString(),
        meetingUrl: (m['meeting_url'] ?? '').toString(),
        contact: (m['contact'] ?? '').toString(),
        notes: (m['notes'] ?? '').toString(),
        confidence: _toDouble(m['confidence']),
        category: (m['category'] ?? 'other').toString(),
        summary: (m['summary'] ?? '').toString(),
        rawJson: jsonStr,
      );
    } catch (e) {
      return ExtractionResult(error: '解析模型输出失败：$e');
    }
  }

  /// 从「截图任务」的 JSON 映射成抽取结果（截图流程用，标题优先取任务标题）
  factory ExtractionResult.fromTaskJson(Map<String, dynamic> m) {
    final title = (m['title'] ?? '').toString().trim();
    final summary = (m['summary'] ?? '').toString();
    return ExtractionResult(
      isInterview: true,
      title: title.isNotEmpty
          ? title
          : (summary.isNotEmpty ? summary : '任务'),
      company: (m['company'] ?? '').toString(),
      role: (m['role'] ?? '').toString(),
      round: _mapRound(m['round']),
      startTime: _parseTime(m['due_time']),
      durationMinutes: _toInt(m['duration_minutes'], 60),
      timeIsExplicit: m['time_is_explicit'] == true,
      location: (m['location'] ?? '').toString(),
      meetingUrl: (m['meeting_url'] ?? '').toString(),
      contact: (m['contact'] ?? '').toString(),
      notes: (m['notes'] ?? '').toString(),
      confidence: _toDouble(m['confidence']),
      category: 'other',
      summary: summary,
    );
  }

  /// 宽容解析：模型偶尔会用 ```json 包裹，或者前后带解释文字
  static Map<String, dynamic> _decodeLenient(String raw) {
    var text = raw.trim();

    // 去掉 markdown 代码块包裹
    if (text.startsWith('```')) {
      final firstNewline = text.indexOf('\n');
      if (firstNewline > 0) text = text.substring(firstNewline + 1);
      if (text.endsWith('```')) text = text.substring(0, text.length - 3);
      text = text.trim();
    }

    try {
      return jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      // 退一步：截取第一个 { 到最后一个 } 之间的内容
      final start = text.indexOf('{');
      final end = text.lastIndexOf('}');
      if (start >= 0 && end > start) {
        return jsonDecode(text.substring(start, end + 1)) as Map<String, dynamic>;
      }
      rethrow;
    }
  }

  /// 批量解析：模型输出是 JSON 数组，做同样的宽容处理（去 markdown 包裹、截取 [] 之间）
  static List<dynamic> _decodeLenientArray(String raw) {
    var text = raw.trim();

    if (text.startsWith('```')) {
      final firstNewline = text.indexOf('\n');
      if (firstNewline > 0) text = text.substring(firstNewline + 1);
      if (text.endsWith('```')) text = text.substring(0, text.length - 3);
      text = text.trim();
    }

    try {
      return jsonDecode(text) as List<dynamic>;
    } catch (_) {
      final start = text.indexOf('[');
      final end = text.lastIndexOf(']');
      if (start >= 0 && end > start) {
        return jsonDecode(text.substring(start, end + 1)) as List<dynamic>;
      }
      rethrow;
    }
  }

  static int _toInt(dynamic v, int fallback) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? fallback;
    return fallback;
  }

  static double _toDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0.0;
    return 0.0;
  }

  static String _buildTitle(Map<String, dynamic> m) {
    final company = (m['company'] ?? '').toString();
    final summary = (m['summary'] ?? '').toString();
    if (company.isNotEmpty) return company;
    if (summary.isNotEmpty) return summary;
    return '面试';
  }

  static String _mapRound(dynamic round) {
    if (round == null) return '';
    final s = round.toString();
    const map = {
      '一面': '一面', 'first': '一面', 'round1': '一面', '第一轮': '一面',
      '二面': '二面', 'second': '二面', 'round2': '二面', '第二轮': '二面',
      '三面': '三面', 'round3': '三面', '第三轮': '三面',
      '终面': '终面', 'final': '终面',
      'hr': 'HR面', 'hr面': 'HR面',
      '笔试': '笔试', 'written': '笔试',
      '测评': '测评', 'assessment': '测评',
    };
    return map[s.toLowerCase()] ?? s;
  }

  static DateTime? _parseTime(dynamic timeStr) {
    if (timeStr == null) return null;
    final s = timeStr.toString().trim();
    if (s.isEmpty || s.toLowerCase() == 'null') return null;
    try {
      return DateTime.parse(s).toLocal();
    } catch (_) {
      return null;
    }
  }
}

/// 截图识别结果：识别出的文字 + 从图里总结出的任务列表
class ScreenshotTasksResult {
  final String recognizedText;
  final List<ExtractionResult> tasks;
  final String? error;

  const ScreenshotTasksResult({
    this.recognizedText = '',
    this.tasks = const [],
    this.error,
  });

  bool get hasError => error != null;
}

/// LLM 服务
class LlmService {
  final LlmProfile profile;

  LlmService(this.profile);

  /// 推理模型（如 MiMo、DeepSeek-R）会先消耗大量 token 做思考，
  /// 而思考 token 也计入 max_tokens —— 给小了会导致 content 返回空字符串，
  /// 必须留足空间。所以思考开启时用更大的预算。
  int get _maxTokens => profile.thinkingEnabled ? 8000 : 4000;

  /// 批量抽取/截图识别的 max_tokens：输出更长，留更多空间避免截断。
  int get _maxBatchTokens => profile.thinkingEnabled ? 16000 : 8000;

  /// 测试连接：发一条最小请求，确认地址/key/模型三者都对
  Future<TestResult> testConnection() async {
    if (profile.apiKey.trim().isEmpty) {
      return const TestResult(ok: false, message: 'API Key 为空');
    }

    final url = profile.chatUrl;
    final sw = Stopwatch()..start();

    try {
      final response = await http
          .post(
            Uri.parse(url),
            headers: {
              'Content-Type': 'application/json; charset=utf-8',
              'Authorization': 'Bearer ${profile.apiKey.trim()}',
            },
            body: utf8.encode(jsonEncode({
              'model': profile.model.trim(),
              'messages': [
                {'role': 'user', 'content': '回复"ok"'},
              ],
              'max_tokens': 500,
              if (!profile.thinkingEnabled) 'reasoning_effort': 'none',
            })),
          )
          .timeout(Duration(seconds: profile.thinkingEnabled ? 60 : 30));

      sw.stop();
      final body = utf8.decode(response.bodyBytes);

      if (response.statusCode == 200) {
        return TestResult(
          ok: true,
          message: '连接成功',
          statusCode: 200,
          elapsedMs: sw.elapsedMilliseconds,
        );
      }

      return TestResult(
        ok: false,
        message: _explainError(response.statusCode, body, url),
        statusCode: response.statusCode,
        elapsedMs: sw.elapsedMilliseconds,
      );
    } catch (e) {
      sw.stop();
      return TestResult(
        ok: false,
        message: _explainException(e, url),
        elapsedMs: sw.elapsedMilliseconds,
      );
    }
  }

  /// 从文本中抽取面试信息
  Future<ExtractionResult> extractFromText(String text) async {
    if (!profile.isConfigured) {
      return const ExtractionResult(error: '请先在设置中选择或配置一个 AI 档案');
    }

    final url = profile.chatUrl;
    final prompt = _buildPrompt(text, DateTime.now());

    try {
      final response = await http
          .post(
            Uri.parse(url),
            headers: {
              'Content-Type': 'application/json; charset=utf-8',
              'Authorization': 'Bearer ${profile.apiKey.trim()}',
            },
            body: utf8.encode(jsonEncode({
              'model': profile.model.trim(),
              'messages': [
                {'role': 'system', 'content': '你是面试信息抽取助手，只输出 JSON，不要任何解释或 markdown 标记。'},
                {'role': 'user', 'content': prompt},
              ],
              'max_tokens': _maxTokens,
              'temperature': 0.1,
              if (!profile.thinkingEnabled) 'reasoning_effort': 'none',
            })),
          )
          .timeout(const Duration(seconds: 90));

      final body = utf8.decode(response.bodyBytes);

      if (response.statusCode != 200) {
        return ExtractionResult(
          error: _explainError(response.statusCode, body, url),
        );
      }

      final data = jsonDecode(body);
      final message = data['choices']?[0]?['message'];
      final content = message?['content']?.toString() ?? '';
      final finishReason = data['choices']?[0]?['finish_reason']?.toString();

      if (content.trim().isEmpty) {
        // 推理模型把 token 全用在思考上时会出现这种情况
        final reasoning = message?['reasoning_content']?.toString() ?? '';
        return ExtractionResult(
          error: finishReason == 'length'
              ? '模型输出被长度限制截断（推理过程占满了 $_maxTokens token）。'
                  '可以换一个非推理模型，或者把文本截短一些再试。'
              : '模型返回了空内容${reasoning.isNotEmpty ? '（推理内容 ${reasoning.length} 字，但未给出结果）' : ''}',
        );
      }

      return ExtractionResult.fromJson(content);
    } catch (e) {
      return ExtractionResult(error: _explainException(e, url));
    }
  }

  /// 批量抽取：一次请求同时判断多封邮件，返回与输入一一对应的结果列表。
  ///
  /// 邮箱导入用它，避免逐封串行调用又慢又费。每封邮件都把全文送进 AI，
  /// 由 AI 通读后再判定 is_interview，不靠关键词预筛。
  Future<List<ExtractionResult>> extractBatch(List<String> texts) async {
    if (texts.isEmpty) return const [];
    if (!profile.isConfigured) {
      return List.filled(
        texts.length,
        const ExtractionResult(error: '请先在设置中选择或配置一个 AI 档案'),
      );
    }

    final url = profile.chatUrl;
    final prompt = _buildBatchPrompt(texts, DateTime.now());

    try {
      final response = await http
          .post(
            Uri.parse(url),
            headers: {
              'Content-Type': 'application/json; charset=utf-8',
              'Authorization': 'Bearer ${profile.apiKey.trim()}',
            },
            body: utf8.encode(jsonEncode({
              'model': profile.model.trim(),
              'messages': [
                {'role': 'system', 'content': '你是面试信息抽取助手，只输出 JSON 数组，不要任何解释或 markdown 标记。'},
                {'role': 'user', 'content': prompt},
              ],
              'max_tokens': _maxBatchTokens,
              'temperature': 0.1,
              if (!profile.thinkingEnabled) 'reasoning_effort': 'none',
            })),
          )
          .timeout(const Duration(seconds: 180));

      final body = utf8.decode(response.bodyBytes);

      if (response.statusCode != 200) {
        final err = _explainError(response.statusCode, body, url);
        return List.filled(texts.length, ExtractionResult(error: err));
      }

      final data = jsonDecode(body);
      final message = data['choices']?[0]?['message'];
      final content = message?['content']?.toString() ?? '';
      final finishReason = data['choices']?[0]?['finish_reason']?.toString();

      if (content.trim().isEmpty) {
        final reasoning = message?['reasoning_content']?.toString() ?? '';
        final err = finishReason == 'length'
            ? '模型输出被长度限制截断（推理过程占满了 token）。可换非推理模型，或减少每批邮件数量。'
            : '模型返回了空内容${reasoning.isNotEmpty ? '（推理内容 ${reasoning.length} 字，但未给出结果）' : ''}';
        return List.filled(texts.length, ExtractionResult(error: err));
      }

      final list = ExtractionResult._decodeLenientArray(content);
      final results = <ExtractionResult>[];
      for (var i = 0; i < texts.length; i++) {
        if (i < list.length) {
          results.add(ExtractionResult.fromJson(jsonEncode(list[i])));
        } else {
          results.add(const ExtractionResult(error: '模型未返回该封邮件的结果'));
        }
      }
      return results;
    } catch (e) {
      return List.filled(
        texts.length,
        ExtractionResult(error: _explainException(e, url)),
      );
    }
  }

  /// 从截图识别文字并总结任务（走模型的视觉能力，图片以 base64 data URI 发送）。
  ///
  /// 返回识别出的全文 [ScreenshotTasksResult.recognizedText] 和任务列表
  /// [ScreenshotTasksResult.tasks]，任务条目与邮件抽取同构，可直接进候选确认流。
  Future<ScreenshotTasksResult> extractTasksFromImage(
    Uint8List bytes, {
    String mimeType = 'image/jpeg',
  }) async {
    if (!profile.isConfigured) {
      return const ScreenshotTasksResult(error: '请先在设置中选择或配置一个 AI 档案');
    }
    if (bytes.isEmpty) {
      return const ScreenshotTasksResult(error: '图片内容为空');
    }
    // base64 会再膨胀约三分之一，太大的原图 API 会拒收
    if (bytes.length > 12 * 1024 * 1024) {
      return const ScreenshotTasksResult(
        error: '图片太大（超过 12MB）。请裁剪或换一张小一点的截图。',
      );
    }

    final url = profile.chatUrl;
    final b64 = base64Encode(bytes);
    final prompt = _buildImagePrompt(DateTime.now());

    try {
      final response = await http
          .post(
            Uri.parse(url),
            headers: {
              'Content-Type': 'application/json; charset=utf-8',
              'Authorization': 'Bearer ${profile.apiKey.trim()}',
            },
            body: utf8.encode(jsonEncode({
              'model': profile.model.trim(),
              'messages': [
                {
                  'role': 'system',
                  'content': '你是文字识别与任务整理助手，只输出 JSON，不要任何解释或 markdown 标记。',
                },
                {
                  'role': 'user',
                  'content': [
                    {
                      'type': 'image_url',
                      'image_url': {'url': 'data:$mimeType;base64,$b64'},
                    },
                    {'type': 'text', 'text': prompt},
                  ],
                },
              ],
              'max_tokens': _maxBatchTokens,
              'temperature': 0.1,
              if (!profile.thinkingEnabled) 'reasoning_effort': 'none',
            })),
          )
          .timeout(const Duration(seconds: 150));

      final body = utf8.decode(response.bodyBytes);

      if (response.statusCode != 200) {
        var err = _explainError(response.statusCode, body, url);
        if (response.statusCode == 400) {
          err += '\n\n可能是当前模型不支持图片输入，可以换一个支持视觉的模型'
              '（如 gpt-4o、qwen-vl-max）再试。';
        }
        return ScreenshotTasksResult(error: err);
      }

      final data = jsonDecode(body);
      final message = data['choices']?[0]?['message'];
      final content = message?['content']?.toString() ?? '';
      final finishReason = data['choices']?[0]?['finish_reason']?.toString();

      if (content.trim().isEmpty) {
        final reasoning = message?['reasoning_content']?.toString() ?? '';
        return ScreenshotTasksResult(
          error: finishReason == 'length'
              ? '模型输出被长度限制截断（推理过程占满了 token）。'
                  '可以关掉思考模式或换一个非推理模型再试。'
              : '模型返回了空内容'
                  '${reasoning.isNotEmpty ? '（推理内容 ${reasoning.length} 字，但未给出结果）' : ''}',
        );
      }

      final m = ExtractionResult._decodeLenient(content);
      final recognized = (m['recognized_text'] ?? '').toString();
      final tasksRaw = m['tasks'];
      final tasks = <ExtractionResult>[];
      if (tasksRaw is List) {
        for (final t in tasksRaw) {
          if (t is Map) {
            tasks.add(ExtractionResult.fromTaskJson(Map<String, dynamic>.from(t)));
          }
        }
      }
      return ScreenshotTasksResult(recognizedText: recognized, tasks: tasks);
    } catch (e) {
      return ScreenshotTasksResult(error: _explainException(e, url));
    }
  }

  /// 截图识别的 prompt：先转写图中文字，再从文字里拆任务。
  String _buildImagePrompt(DateTime now) {
    final weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    final wd = weekdays[now.weekday - 1];
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');

    return '''当前时间：${now.year}年${now.month}月${now.day}日 星期$wd $hh:$mm

这是一张截图。请：
1. 识别图中所有可读文字（recognized_text）
2. 从中总结出需要完成的任务/事项（tasks）：面试安排、笔试测评、材料提交、证件准备、回复确认等都算任务

严格输出这个 JSON 结构：
{
  "recognized_text": "识别到的全部文字，按阅读顺序",
  "tasks": [
    {
      "title": "任务标题",
      "company": "公司名，没有则空",
      "role": "岗位，没有则空",
      "round": "一面/二面/三面/终面/HR面/笔试/测评/其他，没有则空",
      "due_time": "ISO 8601 时间，如 2026-09-30T14:00:00+08:00；推算不出就空字符串",
      "time_is_explicit": true 或 false,
      "duration_minutes": 60,
      "location": "地点，没有则空",
      "meeting_url": "会议链接，没有则空",
      "notes": "其他重要信息",
      "summary": "一句话摘要"
    }
  ]
}

规则：
- 只输出 JSON，不要任何解释或 markdown 标记
- 图里没有任务就返回空数组
- "下周三下午两点"这类相对时间基于当前时间换算，time_is_explicit 设为 false
- 一张截图里可能有多个任务，逐条拆开''';
  }

  /// 把各种失败翻译成能直接照着排查的中文提示
  String _explainError(int status, String body, String url) {
    final buffer = StringBuffer();
    switch (status) {
      case 401:
        buffer.write('认证失败（401）：API Key 无效或已过期。');
        break;
      case 403:
        buffer.write('拒绝访问（403）：Key 无权限，或地址写成了网页控制台。');
        break;
      case 404:
        buffer.write('地址不存在（404）：检查 API 地址是否写错。');
        break;
      case 429:
        buffer.write('请求过于频繁（429）：稍后再试或检查配额。');
        break;
      case 400:
        buffer.write('请求被拒（400）：多半是模型名写错了。');
        break;
      default:
        buffer.write('请求失败（$status）。');
    }
    buffer.write('\n\n请求地址：$url');
    buffer.write('\n模型：${profile.model}');
    // 响应体可能很长，截断显示
    final trimmed = body.length > 300 ? '${body.substring(0, 300)}...' : body;
    buffer.write('\n响应：$trimmed');
    return buffer.toString();
  }

  String _explainException(Object e, String url) {
    final s = e.toString();
    if (s.contains('TimeoutException')) {
      return '请求超时。\n\n地址：$url\n可能是网络不通，或模型响应太慢。';
    }
    if (s.contains('SocketException') || s.contains('Failed host lookup')) {
      return '无法连接服务器。\n\n地址：$url\n检查网络，或确认 API 地址是否写对。';
    }
    if (s.contains('ClientException')) {
      return '网络请求失败（浏览器里常见于跨域限制 CORS）。\n\n'
          '地址：$url\n'
          '如果是在 Chrome 里跑，浏览器的跨域策略可能拦住了请求，'
          '换用桌面版（flutter run -d windows）通常就没这个问题。';
    }
    return '请求出错：$s\n\n地址：$url';
  }

  String _buildPrompt(String text, DateTime now) {
    final weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    final wd = weekdays[now.weekday - 1];

    return '''当前时间：${now.year}年${now.month}月${now.day}日 星期$wd ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}

请从下面的文本中抽取面试信息，严格按这个 JSON 结构输出：

{
  "is_interview": true 或 false,
  "category": "interview_invite" | "reschedule" | "cancel" | "assessment" | "rejection" | "offer" | "other",
  "confidence": 0.0 到 1.0,
  "company": "公司名",
  "role": "岗位名",
  "round": "一面/二面/三面/终面/HR面/笔试/测评/其他",
  "interview_start": "ISO 8601 格式，例如 2026-09-25T14:30:00+08:00",
  "duration_minutes": 60,
  "time_is_explicit": true 或 false,
  "location": "地点",
  "meeting_url": "会议链接",
  "contact": "联系人",
  "notes": "其他重要信息",
  "summary": "一句话摘要"
}

判断规则：
- 只有"邀请你参加面试"才算 is_interview=true。感谢投递、简历已收到、自动回复、拒信都算 false
- 如果原文没写明确时间，time_is_explicit 设为 false，interview_start 给出你推测的时间
- "下周三下午两点"这类相对时间，请基于上面的当前时间换算
- 改期设 category=reschedule，取消设 cancel，笔试/测评设 assessment，拒信设 rejection
- 找不到的字段填空字符串

文本：
$text''';
  }

  /// 批量版的抽取 prompt：一次给多封邮件，要求输出等长的 JSON 数组。
  String _buildBatchPrompt(List<String> texts, DateTime now) {
    final weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    final wd = weekdays[now.weekday - 1];

    final header = '''当前时间：${now.year}年${now.month}月${now.day}日 星期$wd ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}

下面是 ${texts.length} 封邮件。请逐封通读全文，判断是否为面试邀约并抽取信息。
严格输出一个 JSON 数组，长度恰好 ${texts.length}，第 i 个元素对应第 i 封邮件，每个元素结构如下：

{
  "is_interview": true 或 false,
  "category": "interview_invite" | "reschedule" | "cancel" | "assessment" | "rejection" | "offer" | "other",
  "confidence": 0.0 到 1.0,
  "company": "公司名",
  "role": "岗位名",
  "round": "一面/二面/三面/终面/HR面/笔试/测评/其他",
  "interview_start": "ISO 8601 格式，例如 2026-09-25T14:30:00+08:00",
  "duration_minutes": 60,
  "time_is_explicit": true 或 false,
  "location": "地点",
  "meeting_url": "会议链接",
  "contact": "联系人",
  "notes": "其他重要信息",
  "summary": "一句话摘要"
}

判断规则：
- 只有"邀请你参加面试"才算 is_interview=true。感谢投递、简历已收到、自动回复、拒信、offer 通知都算 false
- 如果原文没写明确时间，time_is_explicit 设为 false，interview_start 给出你推测的时间
- "下周三下午两点"这类相对时间，请基于上面的当前时间换算
- 改期设 category=reschedule，取消设 cancel，笔试/测评设 assessment，拒信设 rejection，offer 设 category=offer
- 找不到的字段填空字符串''';

    final sb = StringBuffer(header);
    for (var i = 0; i < texts.length; i++) {
      sb.write('\n\n===== 邮件${i + 1} =====\n${texts[i]}');
    }
    return sb.toString();
  }
}
