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

  /// 拼接完整的 chat completions 地址
  /// 兼容用户填 https://api.xiaomimimo.com 或 .../v1 两种写法
  String get chatUrl {
    var base = baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    if (!base.endsWith('/v1')) base = '$base/v1';
    return '$base/chat/completions';
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
