import 'package:flutter/material.dart';
import '../services/mail_config_store.dart';
import '../theme/app_theme.dart';
import 'mail_config_edit_screen.dart';

/// 邮箱配置管理页：多份配置，随时切换（同步时用「使用中」的那份）。
/// 结构和 AI 配置页保持一致，降低学习成本。
class MailConfigScreen extends StatefulWidget {
  const MailConfigScreen({super.key});

  @override
  State<MailConfigScreen> createState() => _MailConfigScreenState();
}

class _MailConfigScreenState extends State<MailConfigScreen> {
  List<MailConfig> _configs = [];
  String? _activeId;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final configs = await MailConfigStore.loadAll();
      MailConfig? active;
      if (configs.isNotEmpty) {
        active = await MailConfigStore.loadActive();
      }
      if (mounted) {
        setState(() {
          _configs = configs;
          _activeId = active?.id;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        _toast('加载配置失败：$e', isError: true);
      }
    }
  }

  Future<void> _setActive(MailConfig c) async {
    await MailConfigStore.setActiveId(c.id);
    if (!mounted) return;
    setState(() => _activeId = c.id);
    _toast('同步时将使用「${c.displayName}」');
  }

  Future<void> _add() async {
    final created = await Navigator.push<MailConfig>(
      context,
      MaterialPageRoute(builder: (_) => const MailConfigEditScreen()),
    );
    if (created != null && mounted) await _load();
  }

  Future<void> _edit(MailConfig c) async {
    final updated = await Navigator.push<MailConfig>(
      context,
      MaterialPageRoute(builder: (_) => MailConfigEditScreen(config: c)),
    );
    if (updated != null && mounted) await _load();
  }

  Future<void> _delete(MailConfig c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppTheme.radiusMedium), side: BorderSide(color: AppTheme.outline, width: AppTheme.outlineWidth)),
        title: const Text('删除配置'),
        content: Text('确定删除「${c.displayName}」吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: AppTheme.badge)),
          ),
        ],
      ),
    );
    if (ok != true) return;

    await MailConfigStore.delete(c.id);
    if (mounted) await _load();
  }

  void _toast(String msg, {bool isError = false}) {
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
        title: const Text('邮箱配置'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_rounded),
            tooltip: '新增配置',
            onPressed: _add,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppTheme.primary))
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                // 说明
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryLight.withValues(alpha: 0.15),
                    border: Border.all(color: AppTheme.outline, width: AppTheme.outlineWidth),
                    borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.lightbulb_outline, color: AppTheme.accent, size: 20),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '可以保存多个邮箱。点一下卡片把它设为同步时使用的账号，带「使用中」标记的就是当前账号。',
                          style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                        ),
                      ),
                    ],
                  ),
                ),

                if (!MailConfigStore.isPersistent &&
                    (MailConfigStore.lastError ?? '').isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.badge.withValues(alpha: 0.08),
                      border: Border.all(color: AppTheme.outline, width: AppTheme.outlineWidth),
                      borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.warning_amber_rounded, size: 16, color: AppTheme.badge),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '配置未能保存到本机，重启后可能丢失：${MailConfigStore.lastError}',
                            style: const TextStyle(fontSize: 12, color: AppTheme.badge, height: 1.4),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 20),

                if (_configs.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
                      // 经典=原版浅蓝细边、无阴影，lowpoly=黑描边+硬阴影
                      border: AppTheme.isLowpoly
                          ? Border.all(
                              color: AppTheme.outline,
                              width: AppTheme.outlineWidth,
                            )
                          : Border.all(
                              color: AppTheme.primaryLight.withValues(alpha: 0.5),
                            ),
                      boxShadow:
                          AppTheme.isLowpoly ? AppTheme.hardShadow : null,
                    ),
                    child: const Column(
                      children: [
                        Icon(Icons.mail_outline, size: 36, color: AppTheme.textSecondary),
                        SizedBox(height: 10),
                        Text(
                          '还没有邮箱配置\n点下面的按钮新增一个 QQ 邮箱账号',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 13, color: AppTheme.textSecondary, height: 1.5),
                        ),
                      ],
                    ),
                  )
                else
                  ..._configs.map(_buildConfigCard),

                const SizedBox(height: 12),

                // 新增按钮
                OutlinedButton.icon(
                  onPressed: _add,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('新增配置'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.primary,
                    side: BorderSide(color: AppTheme.buttonOutline, width: AppTheme.outlineWidth),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildConfigCard(MailConfig c) {
    final isActive = c.id == _activeId;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        border: Border.all(
          color: isActive ? AppTheme.primary : AppTheme.outline,
          width: isActive ? 2.5 : 2,
        ),
        boxShadow: AppTheme.hardShadow,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        onTap: () => _setActive(c),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // 选中标记
                  Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isActive ? AppTheme.primary : Colors.transparent,
                      border: Border.all(
                        color: isActive
                            ? AppTheme.primary
                            : AppTheme.textSecondary.withValues(alpha: 0.4),
                        width: 2,
                      ),
                    ),
                    child: isActive
                        ? const Icon(Icons.check, size: 13, color: Colors.white)
                        : null,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      c.displayName,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: (c.isConfigured ? AppTheme.success : AppTheme.textSecondary)
                          .withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      c.isConfigured ? '✓ 可用' : '未配置',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: c.isConfigured ? AppTheme.success : AppTheme.textSecondary,
                      ),
                    ),
                  ),
                  if (isActive) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppTheme.primary.withValues(alpha: 0.12),
                        border: Border.all(color: AppTheme.outline, width: AppTheme.outlineWidth),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text(
                        '使用中',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppTheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              _metaRow('邮箱', c.email.isEmpty ? '未填' : c.email),
              _metaRow(
                '授权码',
                c.authCode.isEmpty
                    ? '未填'
                    : '${c.authCode.substring(0, c.authCode.length.clamp(0, 4))}••••',
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _edit(c),
                      icon: const Icon(Icons.edit_outlined, size: 16),
                      label: const Text('编辑'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.primary,
                        side: BorderSide(color: AppTheme.buttonOutline, width: AppTheme.outlineWidth),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        textStyle: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: () => _delete(c),
                    icon: const Icon(Icons.delete_outline, size: 20),
                    color: AppTheme.badge.withValues(alpha: 0.7),
                    tooltip: '删除',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _metaRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        children: [
          SizedBox(
            width: 44,
            child: Text(label, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 13),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
