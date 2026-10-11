// LlmProfile 地址归一化与格式提示的纯逻辑测试（无网络、无 WidgetTester）。
//
// 覆盖 lib/models/llm_profile.dart：
//   - urlsFor()：用户随便填（带不带 /v1、带不带接口路径、带尾斜杠）都要产出正确候选
//   - formatHint：按域名猜首选格式
//   - isConfigured：Key / 地址非空才算配置完成
import 'package:flutter_test/flutter_test.dart';
import 'package:interview_calendar/models/llm_profile.dart';

LlmProfile _profile({
  String baseUrl = '',
  String apiKey = 'sk-test',
}) {
  return LlmProfile(
    id: 'test',
    name: '测试档案',
    baseUrl: baseUrl,
    apiKey: apiKey,
  );
}

void main() {
  group('urlsFor(openAi) — OpenAI 兼容地址归一化', () {
    test('base=https://api.openai.com → 首选带 /v1，备选不带', () {
      final urls = _profile(baseUrl: 'https://api.openai.com')
          .urlsFor(ApiFormat.openAi);
      expect(urls, [
        'https://api.openai.com/v1/chat/completions',
        'https://api.openai.com/chat/completions',
      ]);
    });

    test('base=https://api.openai.com/v1 → 首选带 /v1，备选去掉 /v1', () {
      final urls =
          _profile(baseUrl: 'https://api.openai.com/v1').urlsFor(ApiFormat.openAi);
      expect(urls, [
        'https://api.openai.com/v1/chat/completions',
        'https://api.openai.com/chat/completions',
      ]);
    });

    test('base 带尾斜杠 https://x.com/v1/ → 正确去斜杠', () {
      final urls =
          _profile(baseUrl: 'https://x.com/v1/').urlsFor(ApiFormat.openAi);
      expect(urls, [
        'https://x.com/v1/chat/completions',
        'https://x.com/chat/completions',
      ]);
    });

    test('粘贴完整路径 /v1/chat/completions → 归一后仍产出正确候选', () {
      final urls = _profile(baseUrl: 'https://x.com/v1/chat/completions')
          .urlsFor(ApiFormat.openAi);
      expect(urls, [
        'https://x.com/v1/chat/completions',
        'https://x.com/chat/completions',
      ]);
    });

    test('粘贴不带 v1 的完整路径 /chat/completions → 归一后仍产出正确候选', () {
      final urls = _profile(baseUrl: 'https://x.com/chat/completions')
          .urlsFor(ApiFormat.openAi);
      expect(urls, [
        'https://x.com/v1/chat/completions',
        'https://x.com/chat/completions',
      ]);
    });
  });

  group('urlsFor(anthropic) — Anthropic 原生地址归一化', () {
    test('base=https://api.anthropic.com → 首选带 /v1/messages，备选不带', () {
      final urls = _profile(baseUrl: 'https://api.anthropic.com')
          .urlsFor(ApiFormat.anthropic);
      expect(urls, [
        'https://api.anthropic.com/v1/messages',
        'https://api.anthropic.com/messages',
      ]);
    });

    test('粘贴完整路径 /v1/messages → 首选即该地址', () {
      final urls = _profile(baseUrl: 'https://api.anthropic.com/v1/messages')
          .urlsFor(ApiFormat.anthropic);
      expect(urls.first, 'https://api.anthropic.com/v1/messages');
      expect(urls, [
        'https://api.anthropic.com/v1/messages',
        'https://api.anthropic.com/messages',
      ]);
    });
  });

  group('formatHint — 按域名猜首选格式', () {
    test('含 anthropic → ApiFormat.anthropic', () {
      expect(
        _profile(baseUrl: 'https://api.anthropic.com').formatHint,
        ApiFormat.anthropic,
      );
    });

    test('含 openai → ApiFormat.openAi', () {
      expect(
        _profile(baseUrl: 'https://api.openai.com').formatHint,
        ApiFormat.openAi,
      );
    });

    test('含 deepseek → ApiFormat.openAi', () {
      expect(
        _profile(baseUrl: 'https://api.deepseek.com').formatHint,
        ApiFormat.openAi,
      );
    });

    test('含 xiaomimimo → ApiFormat.openAi', () {
      expect(
        _profile(baseUrl: 'https://api.xiaomimimo.com').formatHint,
        ApiFormat.openAi,
      );
    });

    test('未知域名（如自建代理）→ null', () {
      expect(
        _profile(baseUrl: 'https://my-proxy.example.com').formatHint,
        isNull,
      );
    });
  });

  group('isConfigured — 配置完成判断', () {
    test('空 key → false', () {
      expect(
        _profile(baseUrl: 'https://api.openai.com', apiKey: '').isConfigured,
        isFalse,
      );
    });

    test('只有空格的 key → false', () {
      expect(
        _profile(baseUrl: 'https://api.openai.com', apiKey: '   ').isConfigured,
        isFalse,
      );
    });

    test('正常 key（且地址非空）→ true', () {
      expect(_profile(baseUrl: 'https://api.openai.com', apiKey: 'sk-abc123').isConfigured, isTrue);
    });
  });
}
