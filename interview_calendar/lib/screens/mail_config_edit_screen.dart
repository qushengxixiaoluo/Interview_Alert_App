import 'package:flutter/material.dart';
import '../services/mail_config_store.dart';
import '../theme/app_theme.dart';

/// 新建 / 编辑一份邮箱配置。保存时把值装回 [MailConfig] 返回给调用方。
class MailConfigEditScreen extends StatefulWidget {
  /// 为 null 表示新建
  final MailConfig? config;

  const MailConfigEditScreen({super.key, this.config});

  @override
  State<MailConfigEditScreen> createState() => _MailConfigEditScreenState();
}

class _MailConfigEditScreenState extends State<MailConfigEditScreen> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _emailCtrl;
  late final TextEditingController _authCtrl;
  bool _obscureAuth = true;
  bool _saving = false;

  bool get _isNew => widget.config == null;

  @override
  void initState() {
    super.initState();
    final c = widget.config;
    _nameCtrl = TextEditingController(text: c?.name ?? '');
    _emailCtrl = TextEditingController(text: c?.email ?? '');
    _authCtrl = TextEditingController(text: c?.authCode ?? '');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _authCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final email = _emailCtrl.text.trim();
    if (email.isEmpty) {
      _show('请填写 QQ 邮箱地址', isError: true);
      return;
    }
    if (_saving) return;
    setState(() => _saving = true);

    final config = MailConfig(
      id: widget.config?.id ?? MailConfigStore.newId(),
      name: _nameCtrl.text.trim(),
      email: email,
      authCode: _authCtrl.text.trim(),
    );
    await MailConfigStore.upsert(config);
    if (!mounted) return;
    setState(() => _saving = false);

    if (!MailConfigStore.isPersistent) {
      _show('保存失败（未能写入本机）：${MailConfigStore.lastError}', isError: true);
      return;
    }
    Navigator.pop(context, config);
  }

  void _show(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? AppTheme.badge : AppTheme.success,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? '新增邮箱配置' : '编辑邮箱配置'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.primary),
                    )
                  : const Text(
                      '保存',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.primary,
                      ),
                    ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _field('名称（可选）', TextField(
            controller: _nameCtrl,
            decoration: _dec('如：QQ 主号'),
          )),
          const SizedBox(height: 16),
          _field('QQ 邮箱地址', TextField(
            controller: _emailCtrl,
            keyboardType: TextInputType.emailAddress,
            decoration: _dec('如 123456789@qq.com'),
          )),
          const SizedBox(height: 16),
          _field('授权码（不是 QQ 密码）', TextField(
            controller: _authCtrl,
            obscureText: _obscureAuth,
            decoration: _dec('QQ 邮箱 → 设置 → 账号 → 开启 IMAP/SMTP 服务').copyWith(
              suffixIcon: IconButton(
                icon: Icon(
                  _obscureAuth ? Icons.visibility_off : Icons.visibility,
                  size: 18,
                ),
                onPressed: () => setState(() => _obscureAuth = !_obscureAuth),
              ),
            ),
          )),
          const SizedBox(height: 10),
          Text(
            '没有授权码？QQ 邮箱 → 设置 → 账号 → 开启 IMAP/SMTP 服务，短信验证后生成。'
            '授权码保存在本机，和 AI 档案的 API Key 一样不会发往任何服务器。',
            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary.withValues(alpha: 0.8), height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _field(String label, Widget child) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 6),
        child,
      ],
    );
  }

  InputDecoration _dec(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: AppTheme.textSecondary.withValues(alpha: 0.5), fontSize: 13),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        borderSide: BorderSide(color: AppTheme.inputBorder, width: AppTheme.inputBorderWidth),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        borderSide: BorderSide(color: AppTheme.inputBorder, width: AppTheme.inputBorderWidth),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        borderSide: const BorderSide(color: AppTheme.primary, width: 2.5),
      ),
    );
  }
}
