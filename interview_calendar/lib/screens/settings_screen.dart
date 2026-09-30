import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/llm_profile.dart';
import '../services/profile_store.dart';
import '../services/llm_service.dart';
import '../theme/app_theme.dart';
import 'profile_edit_screen.dart';

/// 设置页：AI 配置档案管理（多份配置，随时切换）
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  List<LlmProfile> _profiles = [];
  String? _activeId;
  bool _loading = true;
  String? _testingId;
  final Map<String, TestResult> _testResults = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final profiles = await ProfileStore.loadAll();
      final activeId = await ProfileStore.loadActiveId();
      if (mounted) {
        setState(() {
          _profiles = profiles;
          _activeId = activeId ?? (profiles.isNotEmpty ? profiles.first.id : null);
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

  Future<void> _setActive(LlmProfile p) async {
    try {
      await ProfileStore.setActiveId(p.id);
      if (mounted) {
        setState(() => _activeId = p.id);
        _toast('已切换到「${p.name}」');
      }
    } catch (e) {
      if (mounted) _toast('切换失败：$e', isError: true);
    }
  }

  Future<void> _test(LlmProfile p) async {
    setState(() => _testingId = p.id);
    try {
      final result = await LlmService(p).testConnection();
      if (mounted) {
        setState(() {
          _testResults[p.id] = result;
          _testingId = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _testResults[p.id] = TestResult(ok: false, message: '测试出错：$e');
          _testingId = null;
        });
      }
    }
  }

  Future<void> _add() async {
    final created = await Navigator.push<LlmProfile>(
      context,
      MaterialPageRoute(builder: (_) => const ProfileEditScreen()),
    );
    if (created != null && mounted) {
      await ProfileStore.upsert(created);
      await _load();
    }
  }

  Future<void> _edit(LlmProfile p) async {
    final updated = await Navigator.push<LlmProfile>(
      context,
      MaterialPageRoute(builder: (_) => ProfileEditScreen(profile: p)),
    );
    if (updated != null && mounted) {
      await ProfileStore.upsert(updated);
      setState(() => _testResults.remove(p.id));
      await _load();
    }
  }

  Future<void> _delete(LlmProfile p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppTheme.radiusMedium), side: BorderSide(color: AppTheme.outline, width: AppTheme.outlineWidth)),
        title: const Text('删除配置'),
        content: Text('确定删除「${p.name}」吗？'),
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

    try {
      await ProfileStore.delete(p.id);
      if (mounted) {
        setState(() => _testResults.remove(p.id));
        await _load();
      }
    } catch (e) {
      if (mounted) _toast('删除失败：$e', isError: true);
    }
  }

  void _toast(String msg, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? AppTheme.badge : AppTheme.success,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// 切换界面风格并记住（根组件监听 listenable 会整体重建）
  Future<void> _switchStyle(AppStyle s) async {
    if (AppTheme.style == s) return;
    AppTheme.switchStyle(s);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('app_style', s.name);
    } catch (_) {
      // 存不住就只在本次会话生效
    }
    if (mounted) setState(() {});
  }

  Widget _styleChip(String label, AppStyle s) {
    final active = AppTheme.style == s;
    return Expanded(
      child: OutlinedButton(
        onPressed: () => _switchStyle(s),
        style: OutlinedButton.styleFrom(
          backgroundColor: active ? AppTheme.primary : Colors.white,
          foregroundColor: active ? Colors.white : AppTheme.textPrimary,
          side: BorderSide(color: active ? AppTheme.primary : AppTheme.buttonOutline),
          padding: const EdgeInsets.symmetric(vertical: 10),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppTheme.radiusMedium)),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        child: Text(label),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI 配置'),
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
                // 界面风格切换（经典卡通 / Lowpoly 描边），选择会记住
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
                    border: Border.all(color: AppTheme.outline, width: AppTheme.outlineWidth),
                    boxShadow: AppTheme.hardShadow,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.palette_outlined, size: 18, color: AppTheme.accent),
                          SizedBox(width: 8),
                          Text('界面风格', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          _styleChip('经典卡通', AppStyle.classic),
                          const SizedBox(width: 10),
                          _styleChip('描边风格', AppStyle.lowpoly),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '随时切换，选择会记住；描边风格是黑边+硬阴影的贴纸质感。',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppTheme.textSecondary.withValues(alpha: 0.85),
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 20),

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
                          '可以保存多份配置随时切换。点一下切换，长按右边按钮测试连接。',
                          style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 20),

                ..._profiles.map(_buildProfileCard),

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

  Widget _buildProfileCard(LlmProfile p) {
    final isActive = p.id == _activeId;
    final testing = _testingId == p.id;
    final result = _testResults[p.id];

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
        onTap: () => _setActive(p),
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
                        color: isActive ? AppTheme.primary : AppTheme.textSecondary.withValues(alpha: 0.4),
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
                      p.name,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (isActive)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppTheme.primary.withValues(alpha: 0.12),
                        border: Border.all(color: AppTheme.outline, width: AppTheme.outlineWidth),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text('使用中', style: TextStyle(fontSize: 11, color: AppTheme.primary, fontWeight: FontWeight.w600)),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              _metaRow('模型', p.model.isEmpty ? '未填' : p.model),
              _metaRow('地址', p.baseUrl.isEmpty ? '未填' : p.baseUrl),
              _metaRow('Key', p.apiKey.isEmpty ? '未填' : '${p.apiKey.substring(0, p.apiKey.length.clamp(0, 6))}••••'),

              // 测试结果
              if (result != null) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: (result.ok ? AppTheme.success : AppTheme.badge).withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        result.ok ? Icons.check_circle_outline : Icons.error_outline,
                        size: 16,
                        color: result.ok ? AppTheme.success : AppTheme.badge,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          result.ok
                              ? '连接成功（${result.elapsedMs}ms）'
                              : result.message,
                          style: TextStyle(
                            fontSize: 12,
                            color: result.ok ? AppTheme.success : AppTheme.badge,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 10),
              Row(
                children: [
                  // 测试连接
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: testing ? null : () => _test(p),
                      icon: testing
                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.wifi_tethering, size: 16),
                      label: Text(testing ? '测试中' : '测试连接'),
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
                  // 编辑
                  IconButton(
                    onPressed: () => _edit(p),
                    icon: const Icon(Icons.edit_outlined, size: 20),
                    color: AppTheme.textSecondary,
                    tooltip: '编辑',
                  ),
                  // 删除
                  IconButton(
                    onPressed: () => _delete(p),
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
