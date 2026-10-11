/// 服务端接口格式。用户不需要关心这个 —— 由 [LlmService] 自动探测。
enum ApiFormat {
  /// OpenAI 兼容：POST {base}/v1/chat/completions，Bearer 鉴权
  openAi,

  /// Anthropic 原生：POST {base}/v1/messages，x-api-key 鉴权
  anthropic,
}

/// AI 配置档案：一套 API 配置，可保存多份随时切换
class LlmProfile {
  final String id;
  String name;
  String baseUrl;
  String model;
  String apiKey;

  /// 「思考模式」：推理模型（MiMo、DeepSeek-R 等）回答前先生成思考内容再作答。
  ///
  /// 开启后识别更准，尤其「下周三下午两点」这类需要推算的相对时间；
  /// 代价是更慢更费 token（实测抽取一封邮件：开 → 33-38 秒，关 → 2-6 秒）。
  /// 默认开启。赶时间可以在 AI 档案编辑页关掉。
  bool thinkingEnabled;

  LlmProfile({
    required this.id,
    required this.name,
    this.baseUrl = 'https://api.xiaomimimo.com',
    this.model = 'mimo-v2.6-pro',
    this.apiKey = '',
    this.thinkingEnabled = true,
  });

  bool get isConfigured => apiKey.trim().isNotEmpty && baseUrl.trim().isNotEmpty;

  // ============================================================
  //  地址归一化：用户随便填（带不带 /v1、带不带接口路径、带尾斜杠）
  //  都要能用 —— 真正的路径由 LlmService 按「404 就换下一个候选」探测。
  // ============================================================

  static String _trimSlashes(String s) {
    var b = s;
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    return b;
  }

  /// 去掉用户可能直接粘贴的完整接口路径（/chat/completions、/messages），只留站点根。
  /// 例：`https://api.anthropic.com/v1/messages` → `https://api.anthropic.com/v1`
  String get _bareBase {
    var b = _trimSlashes(baseUrl.trim());
    if (b.endsWith('/chat/completions')) {
      b = _trimSlashes(b.substring(0, b.length - '/chat/completions'.length));
    } else if (b.endsWith('/messages')) {
      b = _trimSlashes(b.substring(0, b.length - '/messages'.length));
    }
    return b;
  }

  static final RegExp _versionRe = RegExp(r'/v\d+$');

  /// 同一格式的候选地址：带 /v1 和不带 /v1 各一个（按顺序探测，去重）。
  /// 「少打一个 /v1 就没法用」的问题在这里兜底。
  List<String> urlsFor(ApiFormat format) {
    final bare = _bareBase;
    if (bare.isEmpty) return const [];
    final suffix = format == ApiFormat.openAi ? '/chat/completions' : '/messages';

    // 已经带 /v1（或用户粘贴了完整路径）→ 先按原样拼
    final preferred = _versionRe.hasMatch(bare) ? '$bare$suffix' : '$bare/v1$suffix';
    // 备选：去掉版本段直接拼（有的服务商把接口挂在根路径）
    final altBase = bare.replaceFirst(_versionRe, '');
    final alt = '$altBase$suffix';
    return preferred == alt ? [preferred] : [preferred, alt];
  }

  /// 按域名猜一个首选格式（猜错了也没关系，探测失败会换另一个）
  ApiFormat? get formatHint {
    final host = baseUrl.toLowerCase();
    if (host.contains('anthropic')) return ApiFormat.anthropic;
    if (host.contains('openai') || host.contains('deepseek') || host.contains('xiaomimimo')) {
      return ApiFormat.openAi;
    }
    return null;
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'baseUrl': baseUrl,
    'model': model,
    'apiKey': apiKey,
    'thinkingEnabled': thinkingEnabled,
  };

  factory LlmProfile.fromMap(Map<String, dynamic> m) {
    final storedModel = m['model']?.toString();
    return LlmProfile(
      id: m['id'] ?? DateTime.now().microsecondsSinceEpoch.toString(),
      name: m['name'] ?? '未命名',
      baseUrl: m['baseUrl'] ?? 'https://api.xiaomimimo.com',
      // 旧默认模型 mimo-v2.5（以及一度误写过的 mimo-v2.6）一并升级到
      // mimo-v2.6-pro（默认改用最新旗舰）。API 实际没有「mimo-v2.6」这个名字。
      // 以后想换别的模型，编辑页选一次就会存下来。
      model: (storedModel == null ||
              storedModel == 'mimo-v2.5' ||
              storedModel == 'mimo-v2.6')
          ? 'mimo-v2.6-pro'
          : storedModel,
      apiKey: m['apiKey'] ?? '',
      // 旧数据里的 disableThinking 不再读取（历史默认是关），
      // 一律按「思考开启」处理 —— 需要关的人在编辑页关一次就会存下来。
      thinkingEnabled: m['thinkingEnabled'] ?? true,
    );
  }

  LlmProfile copyWith({
    String? name,
    String? baseUrl,
    String? model,
    String? apiKey,
    bool? thinkingEnabled,
  }) {
    return LlmProfile(
      id: id,
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      model: model ?? this.model,
      apiKey: apiKey ?? this.apiKey,
      thinkingEnabled: thinkingEnabled ?? this.thinkingEnabled,
    );
  }

  /// 常用服务商预设
  static List<LlmProfile> presets() => [
    LlmProfile(
      id: 'preset_mimo',
      name: '小米 MiMo',
      baseUrl: 'https://api.xiaomimimo.com',
      model: 'mimo-v2.6-pro',
      // 预设不含 Key（公开仓库前已移除明文 Key）。
      // 使用者在「AI 配置」页把自己的 Key 填进去即可，保存后存本机。
      apiKey: '',
    ),
    LlmProfile(
      id: 'preset_deepseek',
      name: 'DeepSeek',
      baseUrl: 'https://api.deepseek.com',
      model: 'deepseek-flash',
    ),
    LlmProfile(
      id: 'preset_openai',
      name: 'OpenAI',
      baseUrl: 'https://api.openai.com',
      model: 'gpt-4o-mini',
    ),
  ];
}
