import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/database.dart';
import '../theme/app_theme.dart';

/// 数据管理：查看存储位置、导出/导入备份
class DataScreen extends StatefulWidget {
  const DataScreen({super.key});

  @override
  State<DataScreen> createState() => _DataScreenState();
}

class _DataScreenState extends State<DataScreen> {
  final _db = DatabaseService.instance;
  final _importCtrl = TextEditingController();
  int? _eventCount;
  bool _busy = false;

  /// 存储路径默认收起：长路径直接怼在卡片里很劝退，点一下再展开
  bool _locationExpanded = false;

  @override
  void initState() {
    super.initState();
    _refreshCount();
  }

  @override
  void dispose() {
    _importCtrl.dispose();
    super.dispose();
  }

  Future<void> _refreshCount() async {
    try {
      final events = await _db.getAllEvents();
      if (mounted) setState(() => _eventCount = events.length);
    } catch (e) {
      if (mounted) _toast('读取失败：$e', isError: true);
    }
  }

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final json = await _db.exportJson();
      await Clipboard.setData(ClipboardData(text: json));
      if (mounted) {
        _toast('已复制到剪贴板（${json.length} 字符）。粘贴到记事本存起来即可。');
      }
    } catch (e) {
      if (mounted) _toast('导出失败：$e', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    final text = _importCtrl.text.trim();
    if (text.isEmpty) {
      _toast('请先粘贴备份内容', isError: true);
      return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppTheme.radiusMedium), side: BorderSide(color: AppTheme.outline, width: AppTheme.outlineWidth)),
        title: const Text('导入备份'),
        content: const Text('导入会把备份里的事件追加到现有数据中（不会覆盖或删除已有的）。确定继续吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('导入')),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _busy = true);
    try {
      final count = await _db.importJson(text);
      _importCtrl.clear();
      await _refreshCount();
      if (mounted) _toast('已导入 $count 条');
    } catch (e) {
      if (mounted) _toast('导入失败：$e', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String msg, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? AppTheme.badge : AppTheme.success,
        duration: Duration(seconds: isError ? 5 : 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('数据与备份')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // 存储状态
          _card(
            icon: _db.isPersistent ? Icons.check_circle_outline : Icons.warning_amber_rounded,
            iconColor: _db.isPersistent ? AppTheme.success : AppTheme.warning,
            title: _db.isPersistent ? '数据已持久化保存' : '数据仅存在内存中',
            body: _db.isPersistent
                ? '关掉 App、更新代码、重新编译都不会丢。'
                : '当前环境无法写入存储，关掉 App 后数据会丢失。',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 10),
                Text(
                  '共 ${_eventCount ?? '…'} 条记录',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                // 存储位置：默认收起，点开才展示路径
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _locationExpanded = !_locationExpanded),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        const Icon(Icons.folder_outlined, size: 15, color: AppTheme.textSecondary),
                        const SizedBox(width: 6),
                        const Text(
                          '存储位置',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          _locationExpanded ? '收起' : '查看',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppTheme.primary.withValues(alpha: 0.9),
                          ),
                        ),
                        const SizedBox(width: 2),
                        AnimatedRotation(
                          turns: _locationExpanded ? 0.5 : 0,
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOut,
                          child: const Icon(
                            Icons.expand_more,
                            size: 20,
                            color: AppTheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // 展开/收起的平滑高度动画
                AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                  alignment: Alignment.topCenter,
                  child: _locationExpanded
                      ? Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: AppTheme.primaryLight.withValues(alpha: 0.14),
                            border: Border.all(color: AppTheme.outline, width: AppTheme.outlineWidth),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: SelectableText(
                            _db.storageLocation,
                            style: const TextStyle(
                              fontSize: 12,
                              fontFamily: 'monospace',
                              height: 1.5,
                            ),
                          ),
                        )
                      : const SizedBox(width: double.infinity),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // 导出
          _card(
            icon: Icons.upload_outlined,
            iconColor: AppTheme.primary,
            title: '导出备份',
            body: '把所有事件复制成一段文本。粘贴到记事本或微信收藏里存着，换设备或出问题时能恢复。',
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: ElevatedButton.icon(
                onPressed: _busy ? null : _export,
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: const Text('复制备份到剪贴板'),
              ),
            ),
          ),

          const SizedBox(height: 16),

          // 导入
          _card(
            icon: Icons.download_outlined,
            iconColor: AppTheme.accent,
            title: '从备份恢复',
            body: '把之前导出的内容粘贴到下面。导入是「追加」，不会删掉现有数据。',
            child: Column(
              children: [
                const SizedBox(height: 12),
                TextField(
                  controller: _importCtrl,
                  maxLines: 4,
                  decoration: InputDecoration(
                    hintText: '粘贴备份内容...',
                    hintStyle: TextStyle(color: AppTheme.textSecondary.withValues(alpha: 0.5)),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _import,
                    icon: const Icon(Icons.restore_rounded, size: 18),
                    label: const Text('导入'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.accent,
                      side: const BorderSide(color: AppTheme.accent),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // 数据库升级说明
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppTheme.primaryLight.withValues(alpha: 0.12),
              border: Border.all(color: AppTheme.outline, width: AppTheme.outlineWidth),
              borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 18, color: AppTheme.primary),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '数据库表结构带版本号，升级时只做「加字段」而不会重建表，'
                    '并且每次升级前会自动把旧数据导出一份备份文件放在数据库同目录下。',
                    style: TextStyle(fontSize: 12, color: AppTheme.textSecondary, height: 1.5),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _card({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String body,
    Widget? child,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: AppTheme.outline, width: AppTheme.outlineWidth),
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        boxShadow: AppTheme.hardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: iconColor),
              const SizedBox(width: 8),
              Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 8),
          Text(body, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary, height: 1.5)),
          if (child != null) child,
        ],
      ),
    );
  }
}
