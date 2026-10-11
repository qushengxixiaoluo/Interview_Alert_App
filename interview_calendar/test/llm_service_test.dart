// LlmService 网络与解析逻辑测试（MockClient，不发真实请求）。
//
// 覆盖 lib/services/llm_service.dart：
//   - extractFromText：OpenAI / Anthropic 两种 200 结构解析、markdown 包裹的宽容解码
//   - 端点探测：404/405 换下一个候选地址（带 /v1 ↔ 不带 /v1、OpenAI ↔ Anthropic）
//   - 错误分类：401=config、429=quota、HTML=protocol、空内容=output、超时=timeout
//   - isRetryable：quota 可重试、config 不可重试
//   - extractBatch：数组比输入短 / 条目不是对象时的兜底 error
//   - 未配置（apiKey 空）直接返回 config 错误
//
// 注意：LlmService 有静态端点探测缓存（按 baseUrl），每个测试用不同 baseUrl，
// 且 setUp 里调用 LlmService.resetEndpointCache()，避免测试互相串扰。
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:interview_calendar/models/llm_profile.dart';
import 'package:interview_calendar/services/llm_service.dart';

// ============================================================
//  测试辅助
// ============================================================

LlmProfile _profile({
  required String baseUrl,
  String apiKey = 'sk-test-key',
  String model = 'test-model',
  bool thinkingEnabled = false,
}) {
  return LlmProfile(
    id: 'test',
    name: '测试档案',
    baseUrl: baseUrl,
    model: model,
    apiKey: apiKey,
    thinkingEnabled: thinkingEnabled,
  );
}

/// OpenAI 兼容成功响应：choices[0].message.content
http.Response _openAiOk(String content, {int status = 200}) {
  return http.Response(
    jsonEncode({
      'choices': [
        {
          'message': {'content': content},
          'finish_reason': 'stop',
        }
      ],
    }),
    status,
    headers: {'content-type': 'application/json'},
  );
}

/// Anthropic 原生成功响应：content 是块列表
http.Response _anthropicOk(String text) {
  return http.Response(
    jsonEncode({
      'content': [
        {'type': 'text', 'text': text}
      ],
      'stop_reason': 'end_turn',
    }),
    200,
    headers: {'content-type': 'application/json'},
  );
}

/// 一条正常的面试抽取 JSON（模型输出用）
const _interviewJson = '''
{
  "is_interview": true,
  "category": "interview_invite",
  "confidence": 0.92,
  "company": "Acme 科技",
  "role": "Flutter 开发工程师",
  "round": "第一轮",
  "interview_start": "2026-09-25T14:30:00+08:00",
  "deadline": "",
  "duration_minutes": 60,
  "time_is_explicit": true,
  "location": "腾讯会议",
  "meeting_url": "https://meeting.example.com/abc",
  "contact": "张女士",
  "notes": "请提前 10 分钟进入会议",
  "summary": "Acme 科技 Flutter 岗位一面"
}''';

void main() {
  setUp(() {
    // 静态端点探测缓存会串测试 —— 每个测试前清掉
    LlmService.resetEndpointCache();
  });

  // ============================================================
  //  1. OpenAI 兼容 200 正常 JSON
  // ============================================================
  test('OpenAI 200 + 正常 JSON → extractFromText 解析成功', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return _openAiOk(_interviewJson);
    });

    final service = LlmService(
      _profile(baseUrl: 'https://api.openai-ok.test'),
      client: client,
    );
    final result = await service.extractFromText('邀请你参加面试……');

    expect(result.hasError, false, reason: result.error);
    expect(result.isInterview, true);
    expect(result.company, 'Acme 科技');
    expect(result.role, 'Flutter 开发工程师');
    expect(result.round, '一面', reason: 'round「第一轮」应映射成「一面」');
    expect(result.startTime, isNotNull);
    expect(result.startTime!.year, 2026);
    expect(result.timeIsExplicit, true);
    expect(result.confidence, closeTo(0.92, 0.001));
    expect(result.location, '腾讯会议');
    expect(result.meetingUrl, 'https://meeting.example.com/abc');

    // 请求确实发到了 OpenAI 首选地址，且带 Bearer 鉴权
    expect(requests, isNotEmpty);
    expect(requests.first.url.toString(),
        'https://api.openai-ok.test/v1/chat/completions');
    expect(requests.first.headers['Authorization'], 'Bearer sk-test-key');
  });

  // ============================================================
  //  2. OpenAI 200 但内容被 ```json 包裹 → _decodeLenient 仍能解析
  // ============================================================
  test('OpenAI 200 + markdown 包裹的 JSON → _decodeLenient 仍能解析', () async {
    final client = MockClient((request) async {
      return _openAiOk('```json\n$_interviewJson\n```');
    });

    final service = LlmService(
      _profile(baseUrl: 'https://api.openai-md.test'),
      client: client,
    );
    final result = await service.extractFromText('邀请你参加面试……');

    expect(result.hasError, false, reason: result.error);
    expect(result.isInterview, true);
    expect(result.company, 'Acme 科技');
    expect(result.round, '一面');
    expect(result.rawJson, contains('```json'), reason: 'rawJson 保留模型原文');
  });

  // ============================================================
  //  3. 404 探测回退：OpenAI 候选全 404 → 换 Anthropic /v1/messages
  // ============================================================
  test('OpenAI 候选 404 → 回退到 /v1/messages（x-api-key）且解析成功', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      final path = request.url.path;
      if (path.contains('chat/completions')) {
        // OpenAI 两种候选（带 /v1、不带 /v1）都不存在
        return http.Response(
          jsonEncode({
            'error': {'message': 'Not Found'}
          }),
          404,
          headers: {'content-type': 'application/json'},
        );
      }
      // Anthropic 候选：返回 Anthropic 结构
      return _anthropicOk(_interviewJson);
    });

    final service = LlmService(
      // 注意：域名不能含 anthropic/openai 等关键字，否则 formatHint 会改变候选顺序
      _profile(baseUrl: 'https://api.probe-fallback.test'),
      client: client,
    );
    final result = await service.extractFromText('邀请你参加面试……');

    expect(result.hasError, false, reason: result.error);
    expect(result.isInterview, true);
    expect(result.company, 'Acme 科技');

    // 候选顺序：openAi 带 /v1 → openAi 不带 /v1 → anthropic 带 /v1 → …
    expect(requests.length, 3, reason: '前两个 OpenAI 候选 404，第三次命中 Anthropic');
    expect(requests[0].url.path, endsWith('/v1/chat/completions'));
    expect(requests[1].url.path, endsWith('/chat/completions'));
    expect(requests[2].url.path, endsWith('/v1/messages'),
        reason: '回退后的请求发到了 /v1/messages');
    expect(requests[2].headers['x-api-key'], 'sk-test-key',
        reason: 'Anthropic 格式必须带 x-api-key 头');
    // 成功探测到的地址会被缓存，后续请求直接用（这里只发了一次，无第 4 次请求）
    expect(requests.length, 3);
  });

  // ============================================================
  //  4. 不带 /v1 的回退
  // ============================================================
  test('首选 …/v1/chat/completions 404 → 备选 …/chat/completions 200 成功', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      if (request.url.path.endsWith('/v1/chat/completions')) {
        return http.Response('Not Found', 404);
      }
      if (request.url.path.endsWith('/chat/completions')) {
        return _openAiOk(_interviewJson);
      }
      return http.Response('unexpected', 500);
    });

    final service = LlmService(
      _profile(baseUrl: 'https://api.nov1-fallback.test'),
      client: client,
    );
    final result = await service.extractFromText('邀请你参加面试……');

    expect(result.hasError, false, reason: result.error);
    expect(result.isInterview, true);
    expect(requests.length, 2, reason: '第一次 404，第二次备选地址成功');
    expect(requests[0].url.path, endsWith('/v1/chat/completions'));
    expect(requests[1].url.path, endsWith('/chat/completions'));
    expect(requests[1].url.path, isNot(contains('/v1/')));
  });

  // ============================================================
  //  5. 401 → config，信息含「401」和服务端 JSON error.message
  // ============================================================
  test('401 → errorKind=config，信息含「401」和服务端 error.message', () async {
    final client = MockClient((request) async {
      return http.Response(
        jsonEncode({
          'error': {
            'type': 'invalid_request_error',
            'message': 'Invalid API key provided: sk-test-key',
          }
        }),
        401,
        headers: {'content-type': 'application/json'},
      );
    });

    final service = LlmService(
      _profile(baseUrl: 'https://api.err401.test'),
      client: client,
    );
    final result = await service.extractFromText('随便一段文本');

    expect(result.hasError, true);
    expect(result.errorKind, LlmErrorKind.config);
    expect(result.error, contains('401'));
    expect(result.error, contains('Invalid API key provided: sk-test-key'),
        reason: '应抠出服务端 JSON 里的 error.message');
  });

  // ============================================================
  //  6. 429 → quota 且可重试；401 → 不可重试
  // ============================================================
  test('429 → errorKind=quota 且 isRetryable==true', () async {
    final client = MockClient((request) async {
      return http.Response(
        jsonEncode({
          'error': {'message': 'Rate limit exceeded, retry later'}
        }),
        429,
        headers: {'content-type': 'application/json'},
      );
    });

    final service = LlmService(
      _profile(baseUrl: 'https://api.err429.test'),
      client: client,
    );
    final result = await service.extractFromText('随便一段文本');

    expect(result.hasError, true);
    expect(result.errorKind, LlmErrorKind.quota);
    expect(result.errorKind.isRetryable, isTrue,
        reason: '限流类错误值得降级逐封重试');
    expect(result.error, contains('429'));
  });

  test('401 → errorKind=config 且 isRetryable==false', () async {
    final client = MockClient((request) async {
      return http.Response(
        jsonEncode({
          'error': {'message': 'Unauthorized'}
        }),
        401,
        headers: {'content-type': 'application/json'},
      );
    });

    final service = LlmService(
      _profile(baseUrl: 'https://api.err401-retry.test'),
      client: client,
    );
    final result = await service.extractFromText('随便一段文本');

    expect(result.errorKind, LlmErrorKind.config);
    expect(result.errorKind.isRetryable, isFalse,
        reason: '配置类错误重试没有意义');
  });

  // ============================================================
  //  7. 200 但响应体是 HTML → protocol
  // ============================================================
  test('200 + HTML 响应体 → errorKind=protocol，信息含「不是有效 JSON」', () async {
    final client = MockClient((request) async {
      return http.Response(
        '<!DOCTYPE html><html><body><h1>404 Not Found</h1></body></html>',
        200,
        headers: {'content-type': 'text/html'},
      );
    });

    final service = LlmService(
      _profile(baseUrl: 'https://api.html-body.test'),
      client: client,
    );
    final result = await service.extractFromText('随便一段文本');

    expect(result.hasError, true);
    expect(result.errorKind, LlmErrorKind.protocol);
    expect(result.error, contains('不是有效 JSON'));
  });

  // ============================================================
  //  8. 200 但 content 为空字符串 → output
  // ============================================================
  test('200 + content 空字符串 → errorKind=output，信息含「空内容」', () async {
    final client = MockClient((request) async {
      return _openAiOk('');
    });

    final service = LlmService(
      _profile(baseUrl: 'https://api.empty-content.test'),
      client: client,
    );
    final result = await service.extractFromText('随便一段文本');

    expect(result.hasError, true);
    expect(result.errorKind, LlmErrorKind.output);
    expect(result.error, contains('空内容'));
  });

  // ============================================================
  //  9. extractBatch：数组比输入短 / 条目不是对象
  // ============================================================
  test('extractBatch：模型少返回 → 「模型未返回」；字符串条目 → 该位置有 error', () async {
    final client = MockClient((request) async {
      // 输入 3 封，模型只返回 2 项，且第 2 项是字符串而不是对象
      final batch = jsonEncode([
        jsonDecode(_interviewJson),
        '对不起我只输出了一个字符串',
      ]);
      return _openAiOk(batch);
    });

    final service = LlmService(
      _profile(baseUrl: 'https://api.batch-short.test'),
      client: client,
    );
    final results = await service.extractBatch([
      '邮件一：邀请你参加面试',
      '邮件二：这是拒信',
      '邮件三：简历已收到',
    ]);

    expect(results.length, 3, reason: '返回长度必须与输入一一对应');
    // 位置 0：正常对象
    expect(results[0].hasError, false, reason: results[0].error);
    expect(results[0].isInterview, true);
    // 位置 1：在数组里但不是对象 → 无法识别的条目
    expect(results[1].hasError, true);
    expect(results[1].error, contains('无法识别'));
    expect(results[1].errorKind, LlmErrorKind.output);
    // 位置 2：模型根本没返回 → 模型未返回
    expect(results[2].hasError, true);
    expect(results[2].error, contains('模型未返回'));
    expect(results[2].errorKind, LlmErrorKind.output);
  });

  // ============================================================
  //  10. handler 抛 TimeoutException → timeout
  // ============================================================
  test('请求抛 TimeoutException → errorKind=timeout，信息含「超时」', () async {
    final client = MockClient((request) async {
      throw TimeoutException('模拟网络卡死');
    });

    final service = LlmService(
      _profile(baseUrl: 'https://api.timeout.test'),
      client: client,
    );
    final result = await service.extractFromText('随便一段文本');

    expect(result.hasError, true);
    expect(result.errorKind, LlmErrorKind.timeout);
    expect(result.error, contains('超时'));
    expect(result.errorKind.isRetryable, isTrue,
        reason: '超时属于可重试类别');
  });

  // ============================================================
  //  12. profile 未配置（apiKey 空）→ config 错误，且根本不发请求
  // ============================================================
  test('apiKey 为空 → extractFromText 直接返回 config 错误（不发请求）', () async {
    var called = false;
    final client = MockClient((request) async {
      called = true;
      return http.Response('{}', 200);
    });

    final service = LlmService(
      _profile(baseUrl: 'https://api.nokey.test', apiKey: ''),
      client: client,
    );
    final result = await service.extractFromText('随便一段文本');

    expect(result.hasError, true);
    expect(result.errorKind, LlmErrorKind.config);
    expect(result.error, contains('请先在设置中选择或配置一个 AI 档案'));
    expect(called, isFalse, reason: '未配置时不应发出任何网络请求');
    expect(result.errorKind.isRetryable, isFalse);
  });

  test('apiKey 为空 → extractBatch 每个位置都是 config 错误', () async {
    var called = false;
    final client = MockClient((request) async {
      called = true;
      return http.Response('{}', 200);
    });

    final service = LlmService(
      _profile(baseUrl: 'https://api.nokey-batch.test', apiKey: ''),
      client: client,
    );
    final results = await service.extractBatch(['邮件一', '邮件二']);

    expect(results.length, 2);
    for (final r in results) {
      expect(r.errorKind, LlmErrorKind.config);
      expect(r.error, contains('请先在设置中选择或配置一个 AI 档案'));
    }
    expect(called, isFalse);
  });

  // ============================================================
  //  13. 网关风格 403 回错误路径 → 也换候选，最终命中 Anthropic
  //  （AWS API Gateway 对未匹配路由固定回 403，只认 404 会整条链路失效）
  // ============================================================
  test('OpenAI 候选回 403（网关）→ 继续探测，回退 /v1/messages 成功', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      if (request.url.path.contains('chat/completions')) {
        // API Gateway 风格：未匹配路由 403 {"message":"Missing Authentication Token"}
        return http.Response(
          jsonEncode({'message': 'Missing Authentication Token'}),
          403,
          headers: {'content-type': 'application/json'},
        );
      }
      return _anthropicOk(_interviewJson);
    });

    final service = LlmService(
      _profile(baseUrl: 'https://api.gateway403.test'),
      client: client,
    );
    final result = await service.extractFromText('邀请你参加面试……');

    expect(result.hasError, false, reason: result.error);
    expect(result.isInterview, true);
    expect(requests[2].url.path, endsWith('/v1/messages'),
        reason: '403 不能终止探测，要继续试 Anthropic 候选');
  });

  // ============================================================
  //  14. 失败响应绝不进端点缓存（否则一次 403 锁死整个会话）
  // ============================================================
  test('探测全部失败后不写缓存 → 修复服务端后下次能自动命中', () async {
    var mode = 'broken'; // broken：openai 路径 403、anthropic 404；fixed：anthropic 200
    final client = MockClient((request) async {
      if (request.url.path.contains('chat/completions')) {
        return http.Response(jsonEncode({'message': 'Missing Authentication Token'}),
            403, headers: {'content-type': 'application/json'});
      }
      if (mode == 'broken') {
        return http.Response('Not Found', 404);
      }
      return _anthropicOk(_interviewJson);
    });

    final service = LlmService(
      _profile(baseUrl: 'https://api.cache-regress.test'),
      client: client,
    );

    // 第一轮：全部候选失败 → 报 403（语义优先于 404），且不能缓存任何端点
    final bad = await service.extractFromText('随便');
    expect(bad.hasError, true);
    expect(bad.error, contains('403'),
        reason: '403 比 404 语义更接近真实原因，应优先报出');

    // 服务端修好了（anthropic 路径可用）→ 第二轮必须能重新探测到它
    mode = 'fixed';
    final good = await service.extractFromText('邀请你参加面试……');
    expect(good.hasError, false, reason: good.error);
    expect(good.isInterview, true);
  });

  // ============================================================
  //  15. 全败后错误优先级：401 要压过 404 报出来
  // ============================================================
  test('候选间混有 401 和 404 → 报 401（语义优先）而不是「地址不存在」', () async {
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/v1/chat/completions')) {
        return http.Response(
          jsonEncode({
            'error': {'message': 'Invalid API key'}
          }),
          401,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('Not Found', 404);
    });

    final service = LlmService(
      _profile(baseUrl: 'https://api.rank401.test'),
      client: client,
    );
    final result = await service.extractFromText('随便');

    expect(result.hasError, true);
    expect(result.error, contains('401'), reason: '401 比 404 更接近真实原因');
    expect(result.error, contains('Invalid API key'));
    expect(result.error, isNot(contains('已依次尝试')),
        reason: '存在 401 就不该报「地址不存在」的拼接文案');
    expect(result.errorKind, LlmErrorKind.config);
  });

  // ============================================================
  //  16. 已确认（200 验证过）的端点再报非 200 → 立即返回，不换候选
  // ============================================================
  test('缓存端点返回 401 → 立即报错，不再探测其它候选', () async {
    var mode = 'ok';
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      if (mode == 'ok') return _openAiOk(_interviewJson);
      return http.Response(
        jsonEncode({
          'error': {'message': 'Key revoked'}
        }),
        401,
        headers: {'content-type': 'application/json'},
      );
    });

    final service = LlmService(
      _profile(baseUrl: 'https://api.cached401.test'),
      client: client,
    );

    final first = await service.extractFromText('邀请你参加面试……');
    expect(first.hasError, false, reason: first.error);
    expect(requests.length, 1);

    // 端点已被 200 确认；之后同样地址回 401（Key 被吊销）→ 应直接报错
    mode = 'broken';
    final second = await service.extractFromText('随便');
    expect(second.hasError, true);
    expect(second.error, contains('401'));
    expect(requests.length, 2,
        reason: '已确认的端点不该再换候选地址重试（每轮探测是浪费）');
  });
}
