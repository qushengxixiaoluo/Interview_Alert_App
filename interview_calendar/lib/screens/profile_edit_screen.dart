import 'package:flutter/material.dart';
import '../models/llm_profile.dart';
import '../services/profile_store.dart';
import '../services/llm_service.dart';
import '../theme/app_theme.dart';

/// 编辑 / 新建一份 AI 配置
class ProfileEditScreen extends StatefulWidget {
  final LlmProfile? profile;

  const ProfileEditScreen({super.key, this.profile});

  @override
  State<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends State<ProfileEditScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameCtrl;
  late TextEditingController _urlCtrl;
  late TextEditingController _modelCtrl;
  late TextEditingController _keyCtrl;

  bool _obscure = true;
  bool _testing = false;
  bool _saving = false;
  bool _thinkingEnabled = true;
  TestResult? _testResult;

  bool get _isNew => widget.profile == null;

  @override
  void initState() {
    super.initState();
    final p = widget.profile;
    _nameCtrl = TextEditingController(text: p?.name ?? '');
    _urlCtrl = TextEditingController(text: p?.baseUrl ?? 'https://api.xiaomimimo.com');
    _modelCtrl = TextEditingController(text: p?.model ?? 'mimo-v2.6-pro');
    _keyCtrl = TextEditingController(text: p?.apiKey ?? '');
    _thinkingEnabled = p?.thinkingEnabled ?? true;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    _modelCtrl.dispose();
    _keyCtrl.dispose();
    super.dispose();
  }

  LlmProfile _build() => LlmProfile(
    id: widget.profile?.id ?? ProfileStore.newId(),
    name: _nameCtrl.text.trim().isEmpty ? '未命名' : _nameCtrl.text.trim(),
    baseUrl: _urlCtrl.text.trim(),
    model: _modelCtrl.text.trim(),
    apiKey: _keyCtrl.text.trim(),
    thinkingEnabled: _thinkingEnabled,
  );

  Future<void> _test() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _testing = true;
      _testResult = null;
    });

    try {
      final result = await LlmService(_build()).testConnection();
      if (mounted) {
        setState(() {
          _testResult = result;
          _testing = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _testResult = TestResult(ok: false, message: '测试出错：$e');
          _testing = false;
        });
      }
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    try {
      // 这里只做表单校验和回传，落库交给上一个页面，避免两处都写导致状态不一致
      if (mounted) Navigator.pop(context, _build());
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败：$e'), backgroundColor: AppTheme.badge),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? '新增配置' : '编辑配置'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('保存', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.primary)),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            _field('配置名称', TextFormField(
              controller: _nameCtrl,
              decoration: _dec('例如：小米 MiMo'),
              validator: (v) => (v == null || v.trim().isEmpty) ? '给这份配置起个名字' : null,
            )),

            const SizedBox(height: 16),

            _field('API 地址', TextFormField(
              controller: _urlCtrl,
              decoration: _dec('https://api.xiaomimimo.com'),
              keyboardType: TextInputType.url,
              validator: (v) {
                final s = v?.trim() ?? '';
                if (s.isEmpty) return '地址不能为空';
                if (!s.startsWith('http')) return '地址要以 http(s):// 开头';
                return null;
              },
            )),

            const SizedBox(height: 16),

            _field('模型', TextFormField(
              controller: _modelCtrl,
              decoration: _dec('mimo-v2.6-pro'),
              validator: (v) => (v == null || v.trim().isEmpty) ? '模型名不能为空' : null,
            )),

            // 模型快捷填入
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _chip('mimo-v2.6-pro', () => _modelCtrl.text = 'mimo-v2.6-pro'),
                _chip('mimo-v2.6-flash', () => _modelCtrl.text = 'mimo-v2.6-flash'),
                _chip('mimo-v2.6-pro-ultraspeed', () => _modelCtrl.text = 'mimo-v2.6-pro-ultraspeed'),
                _chip('mimo-v2.5', () => _modelCtrl.text = 'mimo-v2.5'),
                _chip('mimo-v2.5-pro', () => _modelCtrl.text = 'mimo-v2.5-pro'),
                _chip('deepseek-flash', () => _modelCtrl.text = 'deepseek-flash'),
                _chip('gpt-4o-mini', () => _modelCtrl.text = 'gpt-4o-mini'),
              ],
            ),

            const SizedBox(height: 16),

            _field('API Key', TextFormField(
              controller: _keyCtrl,
              obscureText: _obscure,
              decoration: _dec('sk-...').copyWith(
                suffixIcon: IconButton(
                  icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility, size: 20),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Key 不能为空' : null,
            )),

            const SizedBox(height: 12),

            // 思考模式开关
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
                border: Border.all(color: AppTheme.primaryLight.withValues(alpha: 0.5)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.bolt_rounded, size: 20, color: AppTheme.accent),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('思考模式', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                        SizedBox(height: 2),
                        Text(
                          '推理模型回答前会先「想」一段再作答。开启识别更准，'
                          '尤其「下周三下午两点」这类相对时间的推算；代价是每封邮件约 35 秒'
                          '（关闭约 2-6 秒）。赶时间可以关掉。',
                          style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, height: 1.4),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: _thinkingEnabled,
                    activeThumbColor: AppTheme.primary,
                    onChanged: (v) => setState(() => _thinkingEnabled = v),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // 测试连接
            OutlinedButton.icon(
              onPressed: _testing ? null : _test,
              icon: _testing
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.wifi_tethering, size: 18),
              label: Text(_testing ? '测试中...' : '测试连接'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.primary,
                side: BorderSide(color: AppTheme.buttonOutline, width: AppTheme.outlineWidth),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppTheme.radiusMedium)),
              ),
            ),

            // 测试结果
            if (_testResult != null) ...[
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: (_testResult!.ok ? AppTheme.success : AppTheme.badge).withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
                  border: Border.all(
                    color: (_testResult!.ok ? AppTheme.success : AppTheme.badge).withValues(alpha: 0.3),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          _testResult!.ok ? Icons.check_circle : Icons.error,
                          size: 18,
                          color: _testResult!.ok ? AppTheme.success : AppTheme.badge,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _testResult!.ok
                              ? '连接成功（${_testResult!.elapsedMs}ms）'
                              : '连接失败',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: _testResult!.ok ? AppTheme.success : AppTheme.badge,
                          ),
                        ),
                      ],
                    ),
                    if (!_testResult!.ok) ...[
                      const SizedBox(height: 8),
                      SelectableText(
                        _testResult!.message,
                        style: const TextStyle(fontSize: 12, height: 1.5),
                      ),
                    ],
                  ],
                ),
              ),
            ],

            const SizedBox(height: 32),

            ElevatedButton(
              onPressed: _saving ? null : _save,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(_isNew ? '创建' : '保存修改', style: const TextStyle(fontSize: 16)),
              ),
            ),

            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _field(String label, Widget child) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
        const SizedBox(height: 6),
        child,
      ],
    );
  }

  InputDecoration _dec(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(color: AppTheme.textSecondary.withValues(alpha: 0.5)),
  );

  Widget _chip(String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: AppTheme.primaryLight.withValues(alpha: 0.15),
          border: Border.all(color: AppTheme.outline, width: AppTheme.outlineWidth),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(label, style: const TextStyle(fontSize: 12, color: AppTheme.primary)),
      ),
    );
  }
}
