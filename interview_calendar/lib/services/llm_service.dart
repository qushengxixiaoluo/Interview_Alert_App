import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
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

/// 失败的类别。用途有两个：
///  1. 给出更有针对性的中文提示；
///  2. 决定批量识别失败后要不要降级重试（[isRetryable]）。
enum LlmErrorKind {
  /// 成功 / 无错误
  none,

  /// 配置问题（Key 错、地址错、模型名错）—— 重试不会有变化
  config,

  /// 网络不通 / DNS / 跨域
  network,

  /// 请求超时
  timeout,

  /// 配额 / 限流（429、402）
  quota,

  /// 服务端错误（5xx）或请求体过大 —— 稍后重试或拆小批次可能成功
  server,

  /// 模型输出问题（空内容、截断、JSON 解析失败）—— 换个请求可能就好
  output,

  /// 服务端返回了看不懂的东西（HTML、非 JSON、结构异常）
  protocol,

  /// 未分类
  unknown,
}

extension LlmErrorKindX on LlmErrorKind {
  /// 批量识别整批失败时，值为 true 才值得逐封重试一次。
  /// 配置类错误（401/404…）重试只是浪费时间，直接提示用户去改配置。
  bool get isRetryable =>
      this == LlmErrorKind.quota ||
      this == LlmErrorKind.server ||
      this == LlmErrorKind.timeout ||
      this == LlmErrorKind.network ||
      this == LlmErrorKind.output ||
      this == LlmErrorKind.unknown;
}

// none/config/protocol 不可重试 —— 上面的白名单已经隐含了这一点

/// LLM 抽取结果
class ExtractionResult {
  final bool isInterview;
  final String title;
  final String company;
  final String role;
  final String round;

  /// 面试 / 笔试的固定场次开始时间。纯截止类任务（测评、材料提交）为 null。
  final DateTime? startTime;

  /// 截止时间。两种情况会用到：
  ///  - 只有截止期限、没有固定场次（startTime == null，整体按「截止事件」处理）
  ///  - 有固定场次但另附一个截止期限（startTime != null，两者都展示）
  final DateTime? deadline;

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
  final LlmErrorKind errorKind;

  const ExtractionResult({
    this.isInterview = false,
    this.title = '',
    this.company = '',
    this.role = '',
    this.round = '',
    this.startTime,
    this.deadline,
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
    this.errorKind = LlmErrorKind.unknown,
  });

  bool get hasError => error != null;

  /// 需要人工核对：有时间锚点，但时间是推算的 / 置信度偏低。
  /// 不以 isInterview 为前提 —— 测评（is_interview=false）同样需要核对。
  bool get needsReview => hasTime && (!timeIsExplicit || confidence < 0.75);

  /// 有没有可用于建日历事件的时间（固定场次或截止期限，至少要有一个）
  bool get hasTime => startTime != null || deadline != null;

  /// 纯截止类（只有截止期限）→ 事件时间就是截止时间
  bool get isDeadlineOnly => startTime == null && deadline != null;

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
        deadline: _parseTime(m['deadline']),
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
      return ExtractionResult(
        error: '解析模型输出失败：$e\n\n模型输出片段：'
            '${jsonStr.length > 200 ? '${jsonStr.substring(0, 200)}…' : jsonStr}',
        errorKind: LlmErrorKind.output,
      );
    }
  }

  /// 从「截图任务」的 JSON 映射成抽取结果（截图流程用，标题优先取任务标题）。
  /// `due_time` 是截止期限时（is_deadline=true），放进 deadline 而不是 startTime。
  factory ExtractionResult.fromTaskJson(Map<String, dynamic> m) {
    final title = (m['title'] ?? '').toString().trim();
    final summary = (m['summary'] ?? '').toString();
    final dueTime = _parseTime(m['due_time']);
    final isDeadline = m['is_deadline'] == true;
    return ExtractionResult(
      isInterview: true,
      title: title.isNotEmpty
          ? title
          : (summary.isNotEmpty ? summary : '任务'),
      company: (m['company'] ?? '').toString(),
      role: (m['role'] ?? '').toString(),
      round: _mapRound(m['round']),
      startTime: isDeadline ? null : dueTime,
      deadline: isDeadline ? dueTime : _parseTime(m['deadline']),
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
      '三面': '三面', 'third': '三面', 'round3': '三面', '第三轮': '三面',
      '终面': '终面', 'final': '终面',
      'hr': 'HR面', 'hr面': 'HR面',
      '笔试': '笔试', 'written': '笔试', 'written_test': '笔试',
      '测评': '测评', 'assessment': '测评', '性格测试': '测评', '认知测评': '测评',
      '在线测试': '笔试', 'online_test': '笔试',
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
  final LlmErrorKind errorKind;

  const ScreenshotTasksResult({
    this.recognizedText = '',
    this.tasks = const [],
    this.error,
    this.errorKind = LlmErrorKind.unknown,
  });

  bool get hasError => error != null;
}

// ============================================================
//  一次 HTTP 调用的内部结果
// ============================================================

class _Endpoint {
  final ApiFormat format;
  final String url;
  const _Endpoint(this.format, this.url);
}

class _ChatResult {
  final String? text;
  final String? error;
  final LlmErrorKind kind;
  final String? finishReason;
  final String? reasoning;
  final String url;
  final ApiFormat? format;

  const _ChatResult.ok({
    required this.text,
    required this.finishReason,
    required this.reasoning,
    required this.url,
    required this.format,
  })  : error = null,
        kind = LlmErrorKind.none;

  const _ChatResult.fail({
    required this.error,
    required this.kind,
    this.url = '',
    this.format,
  })  : text = null,
        finishReason = null,
        reasoning = null;

  bool get ok => error == null;
}

/// LLM 服务
class LlmService {
  final LlmProfile profile;
  final http.Client _client;

  /// 探测成功的接口地址缓存（按 baseUrl 归一化），同一配置第二次请求不再走候选探测。
  /// static：一次会话内多批邮件共享探测结果。
  static final Map<String, _Endpoint> _endpointCache = {};

  /// 仅测试用：清掉探测缓存
  @visibleForTesting
  static void resetEndpointCache() => _endpointCache.clear();

  LlmService(this.profile, {http.Client? client}) : _client = client ?? http.Client();

  /// 推理模型（如 MiMo、DeepSeek-R）会先消耗大量 token 做思考，
  /// 而思考 token 也计入 max_tokens —— 给小了会导致 content 返回空字符串，
  /// 必须留足空间。所以思考开启时用更大的预算。
  int get _maxTokens => profile.thinkingEnabled ? 8000 : 4000;

  /// 批量抽取/截图识别的 max_tokens：输出更长，留更多空间避免截断。
  int get _maxBatchTokens => profile.thinkingEnabled ? 16000 : 8000;

  // ============================================================
  //  核心：带格式自动探测的一次对话请求
  // ============================================================

  /// 按「猜的格式优先 → 只有 200 才算命中、否则换下一个候选地址」的顺序发请求。
  ///
  /// 用户只填一个域名就行：带不带 /v1、OpenAI 还是 Anthropic 格式、
  /// 甚至直接把完整接口地址粘进来，都能自己试出来。
  /// 网关用 403/401 回错误路径的情况也在探测范围内（见循环内注释）。
  Future<_ChatResult> _sendChat({
    required String system,
    required String prompt,
    Uint8List? image,
    String imageMime = 'image/jpeg',
    required int maxTokens,
    double? temperature,
    required Duration timeout,
  }) async {
    if (!profile.isConfigured) {
      return const _ChatResult.fail(
        error: '请先在设置中选择或配置一个 AI 档案',
        kind: LlmErrorKind.config,
      );
    }

    final endpoints = _orderedEndpoints();
    final cacheKey = profile.baseUrl.trim();
    final cached = _endpointCache[cacheKey];

    // 探测循环：**只有 200 才算命中**，其余状态都继续试下一个候选地址。
    // （很多网关对不存在的路由回 403/401 而不是 404 —— 只认 404 会让自动识别在
    // 这类网关上整条链路失效；失败响应也绝不能进缓存，否则一次失败锁死整个会话。）
    final failures = <({int status, _ChatResult result})>[];
    for (final ep in endpoints) {
      final resp = await _tryPost(
        ep: ep,
        system: system,
        prompt: prompt,
        image: image,
        imageMime: imageMime,
        maxTokens: maxTokens,
        temperature: temperature,
        timeout: timeout,
      );
      if (!resp.ok) {
        // 请求本身失败了（网络/超时/地址非法）—— 换地址没意义，直接报出去
        return resp;
      }

      final body = resp.text ?? '';
      // 状态码在 _tryPost 里暂存在 finishReason 字段（见其注释）
      final status = int.tryParse(resp.finishReason ?? '') ?? 0;

      if (status == 200) {
        // 只有「响应体也是合格的 API 结构」才算真正命中：
        // nginx/SPA 对未知路径经常回 200 + HTML，这种地址进了缓存会锁死整个会话
        final parsed = _parseSuccessBody(body, ep, maxTokens);
        if (parsed.ok) _endpointCache[cacheKey] = ep;
        return parsed;
      }

      final fail = _ChatResult.fail(
        error: _explainStatus(status, body, ep.url, ep.format),
        kind: _kindFromStatus(status),
        url: ep.url,
        format: ep.format,
      );

      // 端点此前已确认过（200 验证过）→ 非 200 是请求内容的问题
      // （Key 错、模型名错、限流），换格式/换路径没意义，直接报
      if (cached != null && ep.url == cached.url) return fail;

      failures.add((status: status, result: fail));
    }

    if (failures.isEmpty) {
      return const _ChatResult.fail(
        error: 'API 地址为空或不合法，检查 AI 档案里的 API 地址。',
        kind: LlmErrorKind.config,
      );
    }

    // 全部候选都没成功 → 挑语义最明确的那个报给用户：
    // 401（Key 错）> 403（无权限）> 400/422（请求错）> 402/429（配额）
    // > 5xx/其它 > 404/405（地址不存在）
    ({int status, _ChatResult result}) best = failures.first;
    int score(int s) {
      if (s == 401) return 6;
      if (s == 403) return 5;
      if (s == 400 || s == 422) return 4;
      if (s == 402 || s == 429) return 3;
      if (s == 404 || s == 405) return 1;
      return 2;
    }

    for (final f in failures) {
      if (score(f.status) > score(best.status)) best = f;
    }

    if (best.status == 404 || best.status == 405) {
      // 全是「地址不存在」—— 拼上尝试过的清单，让用户照着查地址
      final tried = endpoints.map((e) => '  - ${e.url}').join('\n');
      return _ChatResult.fail(
        error: '接口地址不存在（${best.status}）\n\n'
            '已依次尝试：\n$tried\n\n'
            '请检查 AI 档案里的 API 地址（通常只需填域名，如 https://api.openai.com）。',
        kind: LlmErrorKind.config,
        url: best.result.url,
      );
    }
    return best.result;
  }

  /// 候选地址顺序：缓存过的放最前，否则按域名提示的格式优先。
  List<_Endpoint> _orderedEndpoints() {
    final cacheKey = profile.baseUrl.trim();
    final hint = profile.formatHint ?? ApiFormat.openAi;

    final ordered = <_Endpoint>[];
    void add(ApiFormat f) {
      for (final u in profile.urlsFor(f)) {
        if (!ordered.any((e) => e.url == u)) ordered.add(_Endpoint(f, u));
      }
    }

    final cached = _endpointCache[cacheKey];
    if (cached != null) ordered.add(cached);
    add(hint);
    add(hint == ApiFormat.openAi ? ApiFormat.anthropic : ApiFormat.openAi);
    return ordered;
  }

  /// 发一次请求。返回的 _ChatResult 里：
  ///  - ok=true：error 为 null，text 里暂存响应原文，finishReason 暂存状态码
  ///  - ok=false：error 是人话错误，kind 是类别
  /// （状态码借用 finishReason 字段传递，避免为一次探测再造类型）
  Future<_ChatResult> _tryPost({
    required _Endpoint ep,
    required String system,
    required String prompt,
    required Uint8List? image,
    required String imageMime,
    required int maxTokens,
    required double? temperature,
    required Duration timeout,
  }) async {
    final headers = _headers(ep.format);
    final body = _encodeBody(
      format: ep.format,
      system: system,
      prompt: prompt,
      image: image,
      imageMime: imageMime,
      maxTokens: maxTokens,
      temperature: temperature,
    );

    try {
      final resp = await _client
          .post(
            Uri.parse(ep.url),
            headers: headers,
            body: utf8.encode(body),
          )
          .timeout(timeout);

      final text = utf8.decode(resp.bodyBytes, allowMalformed: true);
      return _ChatResult.ok(
        text: text,
        finishReason: resp.statusCode.toString(),
        reasoning: null,
        url: ep.url,
        format: ep.format,
      );
    } on TimeoutException {
      return _ChatResult.fail(
        error: '请求超时（${timeout.inSeconds} 秒无响应）。\n\n地址：${ep.url}\n'
            '可能是网络不通，或模型响应太慢（思考模式开着时尤其慢，可在 AI 档案里关掉思考再试）。',
        kind: LlmErrorKind.timeout,
        url: ep.url,
        format: ep.format,
      );
    } on FormatException {
      return _ChatResult.fail(
        error: 'API 地址格式不正确：${ep.url}\n地址要以 http(s):// 开头。',
        kind: LlmErrorKind.config,
        url: ep.url,
        format: ep.format,
      );
    } on http.ClientException catch (e) {
      return _ChatResult.fail(
        error: '网络请求失败：${e.message}\n\n地址：${ep.url}\n'
            '浏览器里常见于跨域限制（CORS）—— 换桌面版通常可解决。',
        kind: LlmErrorKind.network,
        url: ep.url,
        format: ep.format,
      );
    } catch (e) {
      // dart:io 的 SocketException/HandshakeException 在 Web 上不存在，
      // 统一按类型名/消息特征分类（llm_service 要能在浏览器里编译）
      final s = e.toString();
      if (s.contains('SocketException') ||
          s.contains('Failed host lookup') ||
          s.contains('Connection refused') ||
          s.contains('Connection reset') ||
          s.contains('Connection closed')) {
        return _ChatResult.fail(
          error: '无法连接服务器。\n\n地址：${ep.url}\n检查网络，或确认 API 地址是否写对。',
          kind: LlmErrorKind.network,
          url: ep.url,
          format: ep.format,
        );
      }
      if (s.contains('HandshakeException') || s.contains('Certificate')) {
        return _ChatResult.fail(
          error: 'HTTPS 连接失败：$s\n\n地址：${ep.url}\n可能是网络代理或证书问题。',
          kind: LlmErrorKind.network,
          url: ep.url,
          format: ep.format,
        );
      }
      return _ChatResult.fail(
        error: '请求出错：$s\n\n地址：${ep.url}',
        kind: LlmErrorKind.unknown,
        url: ep.url,
        format: ep.format,
      );
    }
  }

  Map<String, String> _headers(ApiFormat format) {
    if (format == ApiFormat.anthropic) {
      return {
        'Content-Type': 'application/json; charset=utf-8',
        'x-api-key': profile.apiKey.trim(),
        'anthropic-version': '2023-06-01',
        // 让 Anthropic 允许浏览器（Web 版）直连；桌面端带上也无害
        'anthropic-dangerous-direct-browser-access': 'true',
      };
    }
    return {
      'Content-Type': 'application/json; charset=utf-8',
      'Authorization': 'Bearer ${profile.apiKey.trim()}',
    };
  }

  String _encodeBody({
    required ApiFormat format,
    required String system,
    required String prompt,
    required Uint8List? image,
    required String imageMime,
    required int maxTokens,
    required double? temperature,
  }) {
    final model = profile.model.trim();

    if (format == ApiFormat.anthropic) {
      // Anthropic 的内容块列表：有图就 [image, text]，否则纯文本
      final content = <Map<String, dynamic>>[];
      if (image != null) {
        content.add({
          'type': 'image',
          'source': {
            'type': 'base64',
            'media_type': imageMime,
            'data': base64Encode(image),
          },
        });
      }
      content.add({'type': 'text', 'text': prompt});

      return jsonEncode({
        'model': model,
        'max_tokens': maxTokens,
        'system': system,
        'messages': [
          {'role': 'user', 'content': content},
        ],
        // 扩展思考要求 temperature=1（或不传），传别的值会被 400 拒掉。
        // budget 必须 < max_tokens，小请求（如连通性测试）放不下思考预算 → 不开。
        if (profile.thinkingEnabled && maxTokens > 4096 + 512)
          'thinking': {'type': 'enabled', 'budget_tokens': 4096}
        else if (temperature != null)
          'temperature': temperature,
      });
    }

    // OpenAI 兼容格式
    final userContent = <Map<String, dynamic>>[];
    if (image != null) {
      userContent.add({
        'type': 'image_url',
        'image_url': {'url': 'data:$imageMime;base64,${base64Encode(image)}'},
      });
    }
    userContent.add({'type': 'text', 'text': prompt});

    return jsonEncode({
      'model': model,
      'messages': [
        {'role': 'system', 'content': system},
        {'role': 'user', 'content': userContent},
      ],
      'max_tokens': maxTokens,
      if (temperature != null) 'temperature': temperature,
      if (!profile.thinkingEnabled) 'reasoning_effort': 'none',
    });
  }

  /// 200 响应 → 取出模型文本。同时兼容 OpenAI（choices）和 Anthropic（content）两种结构。
  _ChatResult _parseSuccessBody(String body, _Endpoint ep, int maxTokens) {
    Object? data;
    try {
      data = jsonDecode(body);
    } catch (_) {
      final head = body.length > 200 ? '${body.substring(0, 200)}…' : body;
      return _ChatResult.fail(
        error: '服务端返回的不是有效 JSON（多半是地址指向了网页而不是 API 接口）。\n\n'
            '地址：${ep.url}\n响应开头：$head',
        kind: LlmErrorKind.protocol,
        url: ep.url,
        format: ep.format,
      );
    }
    if (data is! Map<String, dynamic>) {
      final head = body.length > 200 ? '${body.substring(0, 200)}…' : body;
      return _ChatResult.fail(
        error: '服务端返回了无法识别的内容。\n\n地址：${ep.url}\n响应开头：$head',
        kind: LlmErrorKind.protocol,
        url: ep.url,
        format: ep.format,
      );
    }

    // 有的服务 200 里也塞 error
    if (data['error'] != null) {
      return _ChatResult.fail(
        error: '接口返回错误：${_friendlyApiErrorMessage(data)}\n\n地址：${ep.url}',
        kind: LlmErrorKind.unknown,
        url: ep.url,
        format: ep.format,
      );
    }

    String? content;
    String? finishReason;
    String? reasoning;

    final choices = data['choices'];
    if (choices is List && choices.isNotEmpty && choices.first is Map) {
      // OpenAI 兼容结构
      final choice = choices.first as Map;
      final message = choice['message'];
      content = _contentToString(message is Map ? message['content'] : null);
      finishReason = choice['finish_reason']?.toString();
      if (message is Map) {
        reasoning = message['reasoning_content']?.toString() ??
            message['reasoning']?.toString();
      }
    } else if (data.containsKey('content')) {
      // Anthropic 结构：content 是块列表（text / thinking）
      final c = data['content'];
      if (c is List) {
        final texts = <String>[];
        final thoughts = <String>[];
        for (final block in c) {
          if (block is! Map) continue;
          if (block['type'] == 'text') texts.add(block['text']?.toString() ?? '');
          if (block['type'] == 'thinking') thoughts.add(block['thinking']?.toString() ?? '');
        }
        content = texts.join();
        reasoning = thoughts.isEmpty ? null : thoughts.join();
      } else if (c is String) {
        content = c;
      }
      finishReason = data['stop_reason']?.toString();
    } else {
      final head = body.length > 200 ? '${body.substring(0, 200)}…' : body;
      return _ChatResult.fail(
        error: '响应结构无法识别（既没有 choices 也没有 content）。\n\n'
            '地址：${ep.url}\n模型：${profile.model}\n响应开头：$head',
        kind: LlmErrorKind.protocol,
        url: ep.url,
        format: ep.format,
      );
    }

    if (content == null || content.trim().isEmpty) {
      // 推理模型把 token 全用在思考上时会出现这种情况
      final reasonLen = reasoning?.length ?? 0;
      final truncated = finishReason == 'length' || finishReason == 'max_tokens';
      final budget = maxTokens;
      return _ChatResult.fail(
        error: truncated
            ? '模型输出被长度限制截断（推理过程占满了 $budget token）。'
                '可以关掉思考模式、换一个非推理模型，或把文本截短一些再试。'
            : '模型返回了空内容'
                '${reasonLen > 0 ? '（推理内容 $reasonLen 字，但未给出结果）' : ''}'
                '${finishReason != null ? '（finish_reason=$finishReason）' : ''}',
        kind: LlmErrorKind.output,
        url: ep.url,
        format: ep.format,
      );
    }

    return _ChatResult.ok(
      text: content,
      finishReason: finishReason,
      reasoning: reasoning,
      url: ep.url,
      format: ep.format,
    );
  }

  static String? _contentToString(dynamic c) {
    if (c == null) return null;
    if (c is String) return c;
    if (c is List) {
      // 个别兼容实现会返回 [{type:text,text:...}] 这种块列表
      final buf = StringBuffer();
      for (final part in c) {
        if (part is Map && part['type'] == 'text') {
          buf.write(part['text']?.toString() ?? '');
        } else if (part is String) {
          buf.write(part);
        }
      }
      return buf.toString();
    }
    return c.toString();
  }

  /// 从各种错误响应体里抠出服务端给的人话
  static String _friendlyApiErrorMessage(Map<String, dynamic> data) {
    final err = data['error'];
    if (err is Map) {
      final msg = err['message'] ?? err['type'] ?? err['detail'];
      if (msg != null && msg.toString().trim().isNotEmpty) return msg.toString();
    } else if (err is String && err.trim().isNotEmpty) {
      return err;
    }
    final msg = data['message'] ?? data['detail'];
    if (msg != null && msg.toString().trim().isNotEmpty) return msg.toString();
    final s = jsonEncode(data);
    return s.length > 300 ? '${s.substring(0, 300)}…' : s;
  }

  static LlmErrorKind _kindFromStatus(int status) {
    if (status == 429 || status == 402) return LlmErrorKind.quota;
    if (status >= 500) return LlmErrorKind.server;
    if (status == 413) return LlmErrorKind.server; // 请求体过大，拆小批次能救
    if (status == 400 ||
        status == 401 ||
        status == 403 ||
        status == 404 ||
        status == 405 ||
        status == 422) {
      return LlmErrorKind.config;
    }
    return LlmErrorKind.unknown;
  }

  /// 把各种失败翻译成能直接照着排查的中文提示
  String _explainStatus(int status, String body, String url, ApiFormat format) {
    final buffer = StringBuffer();
    switch (status) {
      case 400:
        buffer.write('请求被拒（400）：多半是模型名写错了，或请求参数不被支持。');
        break;
      case 401:
        buffer.write('认证失败（401）：API Key 无效或已过期。');
        break;
      case 402:
        buffer.write('余额不足（402）：账户欠费或套餐已用完。');
        break;
      case 403:
        buffer.write('拒绝访问（403）：Key 无权限，或地址写成了网页控制台。');
        break;
      case 404:
        buffer.write('地址不存在（404）：检查 API 地址是否写错。');
        break;
      case 405:
        buffer.write('接口不允许该请求方式（405）：API 地址可能不对。');
        break;
      case 408:
        buffer.write('请求超时（408）：服务端处理超时，稍后再试。');
        break;
      case 413:
        buffer.write('请求体过大（413）：内容太长了，减少每批邮件数量或截短文本再试。');
        break;
      case 422:
        buffer.write('参数无法处理（422）：检查模型名和请求内容。');
        break;
      case 429:
        buffer.write('请求过于频繁（429）：稍后再试或检查配额。');
        break;
      default:
        if (status >= 500) {
          buffer.write('服务端错误（$status）：接口那边出了问题，稍后再试。');
        } else {
          buffer.write('请求失败（$status）。');
        }
    }
    // 服务端返回的错误详情（OpenAI/Anthropic 都是 JSON error.message）
    final friendly = _tryExtractErrorMessage(body);
    if (friendly != null) buffer.write('\n服务端说明：$friendly');
    buffer.write('\n\n请求地址：$url');
    buffer.write('\n接口格式：${format == ApiFormat.anthropic ? 'Anthropic' : 'OpenAI 兼容'}');
    buffer.write('\n模型：${profile.model}');
    // 响应体可能很长，截断显示
    final trimmed = body.length > 300 ? '${body.substring(0, 300)}...' : body;
    buffer.write('\n响应：$trimmed');
    return buffer.toString();
  }

  static String? _tryExtractErrorMessage(String body) {
    try {
      final data = jsonDecode(body);
      if (data is Map<String, dynamic>) {
        final msg = _friendlyApiErrorMessage(data);
        if (msg.isNotEmpty) {
          return msg.length > 300 ? '${msg.substring(0, 300)}…' : msg;
        }
      }
    } catch (_) {
      // 不是 JSON 就算了，外面还有响应片段
    }
    return null;
  }

  // ============================================================
  //  对外接口
  // ============================================================

  /// 测试连接：发一条最小请求，确认地址/key/模型三者都对。
  /// 成功信息里带上探测出的接口格式，用户能确认自动识别的结果。
  Future<TestResult> testConnection() async {
    if (profile.apiKey.trim().isEmpty) {
      return const TestResult(ok: false, message: 'API Key 为空');
    }

    final sw = Stopwatch()..start();
    final res = await _sendChat(
      system: '你是连通性测试助手。',
      prompt: '回复"ok"',
      maxTokens: 500,
      temperature: null,
      timeout: Duration(seconds: profile.thinkingEnabled ? 60 : 30),
    );
    sw.stop();

    if (res.ok) {
      final fmt = res.format == ApiFormat.anthropic ? 'Anthropic' : 'OpenAI 兼容';
      return TestResult(
        ok: true,
        message: '连接成功（$fmt · ${res.url}）',
        statusCode: 200,
        elapsedMs: sw.elapsedMilliseconds,
      );
    }
    return TestResult(
      ok: false,
      message: res.error ?? '未知错误',
      elapsedMs: sw.elapsedMilliseconds,
    );
  }

  /// 从文本中抽取面试信息
  Future<ExtractionResult> extractFromText(String text) async {
    if (!profile.isConfigured) {
      return const ExtractionResult(
        error: '请先在设置中选择或配置一个 AI 档案',
        errorKind: LlmErrorKind.config,
      );
    }

    final res = await _sendChat(
      system: '你是面试信息抽取助手，只输出 JSON，不要任何解释或 markdown 标记。',
      prompt: _buildPrompt(text, DateTime.now()),
      maxTokens: _maxTokens,
      temperature: 0.1,
      timeout: const Duration(seconds: 90),
    );

    if (!res.ok) {
      return ExtractionResult(error: res.error, errorKind: res.kind);
    }
    return ExtractionResult.fromJson(res.text!);
  }

  /// 批量抽取：一次请求同时判断多封邮件，返回与输入一一对应的结果列表。
  ///
  /// 邮箱导入用它，避免逐封串行调用又慢又费。每封邮件都把全文送进 AI，
  /// 由 AI 通读后再判定 is_interview，不靠关键词预筛。
  /// 失败时所有位置都填同一个 error（带 errorKind），由调用方决定要不要逐封降级重试。
  Future<List<ExtractionResult>> extractBatch(List<String> texts) async {
    if (texts.isEmpty) return const [];
    if (!profile.isConfigured) {
      return List.filled(
        texts.length,
        const ExtractionResult(
          error: '请先在设置中选择或配置一个 AI 档案',
          errorKind: LlmErrorKind.config,
        ),
      );
    }

    final res = await _sendChat(
      system: '你是面试信息抽取助手，只输出 JSON 数组，不要任何解释或 markdown 标记。',
      prompt: _buildBatchPrompt(texts, DateTime.now()),
      maxTokens: _maxBatchTokens,
      temperature: 0.1,
      timeout: const Duration(seconds: 180),
    );

    if (!res.ok) {
      return List.filled(
        texts.length,
        ExtractionResult(error: res.error, errorKind: res.kind),
      );
    }

    List<dynamic> list;
    try {
      list = ExtractionResult._decodeLenientArray(res.text!);
    } catch (e) {
      final err = '解析批量结果失败：$e\n\n把每批邮件数调小一点再试；'
          '仍失败的话可换个模型。';
      return List.filled(
        texts.length,
        ExtractionResult(error: err, errorKind: LlmErrorKind.output),
      );
    }

    final results = <ExtractionResult>[];
    for (var i = 0; i < texts.length; i++) {
      if (i < list.length && list[i] is Map) {
        results.add(ExtractionResult.fromJson(jsonEncode(list[i])));
      } else if (i < list.length) {
        // 位置在但不是对象（模型抽风输出了字符串/数字）
        results.add(const ExtractionResult(
          error: '模型返回了无法识别的条目',
          errorKind: LlmErrorKind.output,
        ));
      } else {
        results.add(const ExtractionResult(
          error: '模型未返回该封邮件的结果',
          errorKind: LlmErrorKind.output,
        ));
      }
    }
    return results;
  }

  /// 从截图识别文字并总结任务（走模型的视觉能力，图片以 base64 发送）。
  ///
  /// 返回识别出的全文 [ScreenshotTasksResult.recognizedText] 和任务列表
  /// [ScreenshotTasksResult.tasks]，任务条目与邮件抽取同构，可直接进候选确认流。
  Future<ScreenshotTasksResult> extractTasksFromImage(
    Uint8List bytes, {
    String mimeType = 'image/jpeg',
  }) async {
    if (!profile.isConfigured) {
      return const ScreenshotTasksResult(
        error: '请先在设置中选择或配置一个 AI 档案',
        errorKind: LlmErrorKind.config,
      );
    }
    if (bytes.isEmpty) {
      return const ScreenshotTasksResult(
        error: '图片内容为空',
        errorKind: LlmErrorKind.output,
      );
    }
    // base64 会再膨胀约三分之一，太大的原图 API 会拒收
    if (bytes.length > 12 * 1024 * 1024) {
      return const ScreenshotTasksResult(
        error: '图片太大（超过 12MB）。请裁剪或换一张小一点的截图。',
        errorKind: LlmErrorKind.output,
      );
    }

    final res = await _sendChat(
      system: '你是文字识别与任务整理助手，只输出 JSON，不要任何解释或 markdown 标记。',
      prompt: _buildImagePrompt(DateTime.now()),
      image: bytes,
      imageMime: mimeType,
      maxTokens: _maxBatchTokens,
      temperature: 0.1,
      timeout: const Duration(seconds: 150),
    );

    if (!res.ok) {
      var err = res.error ?? '未知错误';
      if (err.contains('400')) {
        err += '\n\n可能是当前模型不支持图片输入，可以换一个支持视觉的模型'
            '（如 gpt-4o、qwen-vl-max）再试。';
      }
      return ScreenshotTasksResult(error: err, errorKind: res.kind);
    }

    try {
      final m = ExtractionResult._decodeLenient(res.text!);
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
      return ScreenshotTasksResult(
        error: '解析模型输出失败：$e',
        errorKind: LlmErrorKind.output,
      );
    }
  }

  // ============================================================
  //  Prompt
  // ============================================================

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
      "is_deadline": true 或 false,
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
- due_time 是「必须在此之前完成」的期限（截止时间、提交期限）时 is_deadline 设为 true；
  是面试/笔试的开始时间则设为 false
- 一张截图里可能有多个任务，逐条拆开''';
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
  "deadline": "截止时间，ISO 8601；没有则空字符串",
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
- 笔试、在线测评、性格/认知测试邀请设 category=assessment（is_interview 保持 false）
- 时间分两类：有固定场次（如"9月22日 19:00 开考"）填 interview_start；
  只有期限（如"请于10月15日23:59前完成"）填 deadline，interview_start 留空；
  两者都有就都填。网申截止、材料提交期限、offer 回复期限同样填 deadline
- 如果原文没写明确时间，time_is_explicit 设为 false，给出你推测的时间
- "下周三下午两点"这类相对时间，请基于上面的当前时间换算
- 改期设 category=reschedule，取消设 cancel，拒信设 rejection
- 找不到的字段填空字符串

文本：
$text''';
  }

  /// 批量版的抽取 prompt：一次给多封邮件，要求输出等长的 JSON 数组。
  String _buildBatchPrompt(List<String> texts, DateTime now) {
    final weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    final wd = weekdays[now.weekday - 1];

    final header = '''当前时间：${now.year}年${now.month}月${now.day}日 星期$wd ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}

下面是 ${texts.length} 封邮件。请逐封通读全文，判断是否为需要跟进的招聘邮件（面试邀约、改期、笔试/测评通知）并抽取信息。
严格输出一个 JSON 数组，长度恰好 ${texts.length}，第 i 个元素对应第 i 封邮件，每个元素结构如下：

{
  "is_interview": true 或 false,
  "category": "interview_invite" | "reschedule" | "cancel" | "assessment" | "rejection" | "offer" | "other",
  "confidence": 0.0 到 1.0,
  "company": "公司名",
  "role": "岗位名",
  "round": "一面/二面/三面/终面/HR面/笔试/测评/其他",
  "interview_start": "ISO 8601 格式，例如 2026-09-25T14:30:00+08:00",
  "deadline": "截止时间，ISO 8601；没有则空字符串",
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
- 笔试、在线测评、性格/认知测试邀请设 category=assessment（is_interview 保持 false）
- 时间分两类：有固定场次（如"9月22日 19:00 开考"）填 interview_start；
  只有期限（如"请于10月15日23:59前完成"）填 deadline，interview_start 留空；
  两者都有就都填。网申截止、材料提交期限、offer 回复期限同样填 deadline
- 如果原文没写明确时间，time_is_explicit 设为 false，给出你推测的时间
- "下周三下午两点"这类相对时间，请基于上面的当前时间换算
- 改期设 category=reschedule，取消设 cancel（此时 is_interview 必须为 false），拒信设 rejection，offer 设 category=offer
- 找不到的字段填空字符串''';

    final sb = StringBuffer(header);
    for (var i = 0; i < texts.length; i++) {
      sb.write('\n\n===== 邮件${i + 1} =====\n${texts[i]}');
    }
    return sb.toString();
  }
}
