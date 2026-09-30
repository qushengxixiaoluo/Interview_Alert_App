import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/event.dart';
import '../services/database.dart';
import '../services/ics_export.dart';
import '../theme/app_theme.dart';
import 'event_form_screen.dart';

/// 事件详情页
class EventDetailScreen extends StatefulWidget {
  final InterviewEvent event;

  const EventDetailScreen({super.key, required this.event});

  @override
  State<EventDetailScreen> createState() => _EventDetailScreenState();
}

class _EventDetailScreenState extends State<EventDetailScreen> {
  late InterviewEvent _event;
  final _db = DatabaseService.instance;
  bool _sharing = false;
  bool _busy = false;
  bool _changed = false;

  /// 面试还没开始时，用它定时检查「开始时间到了没」，到了就自动解锁按钮。
  /// 只在未开始时才跑，避免无意义的定时刷新。
  Timer? _unlockTicker;

  @override
  void initState() {
    super.initState();
    _event = widget.event;
    _ensureUnlockTicker();
  }

  @override
  void dispose() {
    _unlockTicker?.cancel();
    super.dispose();
  }

  void _ensureUnlockTicker() {
    if (_event.isCompleted || _event.hasStarted || _unlockTicker != null) return;
    _unlockTicker = Timer.periodic(const Duration(seconds: 30), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_event.hasStarted) {
        timer.cancel();
        _unlockTicker = null;
        setState(() {}); // 时间到了，重新渲染让按钮变为可点
      }
    });
  }

  /// 复制文本到剪贴板
  Future<void> _copyText(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    _toast('已复制到剪贴板');
  }

  /// 标记完成 / 取消完成
  Future<void> _toggleCompleted() async {
    if (_busy) return;

    final wasCompleted = _event.isCompleted;

    // 硬性拦截：事件没开始不让标记完成。
    // 提前标记会让「哪些事情还没做」这个信息失真。
    if (!wasCompleted && !_event.hasStarted) {
      _toast('事件开始后才能标记完成', isError: true);
      return;
    }

    setState(() => _busy = true);
    try {
      final updated = _event.copyWith(
        completedAt: wasCompleted ? null : DateTime.now(),
        clearCompleted: wasCompleted,
      );
      await _db.updateEvent(updated);
      if (mounted) {
        setState(() {
          _event = updated;
          _changed = true;
          _busy = false;
        });
        _toast(wasCompleted ? '已取消完成标记' : '已标记为完成');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        _toast('操作失败：$e', isError: true);
      }
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

  Future<void> _edit() async {
    final result = await Navigator.push<DateTime>(
      context,
      MaterialPageRoute(
        builder: (_) => EventFormScreen(
          initialDate: _event.startTime,
          existingEvent: _event,
        ),
      ),
    );
    if (result != null && mounted) {
      // 重新加载事件
      final events = await _db.getAllEvents();
      if (!mounted) return;
      final updated = events.where((e) => e.id == _event.id).firstOrNull;
      if (updated != null) {
        setState(() {
          _event = updated;
          _changed = true;
        });
        _ensureUnlockTicker();
      }
    }
  }

  Future<void> _delete() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
        ),
        title: const Text('删除事件'),
        content: const Text('确定要删除这个事件吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: AppTheme.badge)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      if (!mounted) return;
      await _db.deleteEvent(_event.id!);
      if (mounted) Navigator.pop(context, true);
    }
  }

  /// 返回时把「有没有改动过」带给上一个页面
  void _goBack() => Navigator.pop(context, _changed);

  Future<void> _shareIcs() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    try {
      final message = await IcsExport.shareEvent(_event);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message), backgroundColor: AppTheme.success),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('导出失败：$e'),
            backgroundColor: AppTheme.badge,
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _openMeetingUrl() async {
    if (_event.meetingUrl == null) return;
    final uri = Uri.parse(_event.meetingUrl!);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _event.color.color;

    return PopScope(
      // 系统返回手势也要把「是否改动过」带回去，否则上一个页面不会刷新
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goBack();
      },
      child: Scaffold(
      body: CustomScrollView(
        slivers: [
          // 顶部颜色背景
          SliverAppBar(
            expandedHeight: 160,
            pinned: true,
            backgroundColor: color,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_ios_rounded, color: Colors.white),
              onPressed: _goBack,
            ),
            actions: [
              // 分享 ICS
              IconButton(
                icon: const Icon(Icons.share_rounded, color: Colors.white),
                onPressed: _shareIcs,
                tooltip: '分享 ICS 文件',
              ),
              // 编辑
              IconButton(
                icon: const Icon(Icons.edit_rounded, color: Colors.white),
                onPressed: _edit,
              ),
              // 删除
              IconButton(
                icon: const Icon(Icons.delete_outline_rounded, color: Colors.white),
                onPressed: _delete,
              ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      color,
                      color.withValues(alpha: 0.7),
                    ],
                  ),
                ),
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(height: 40),
                      // 颜色圆点
                      Container(
                        width: 16,
                        height: 16,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          border: Border.all(color: AppTheme.outline, width: AppTheme.outlineWidth),
                          shape: BoxShape.circle,
                          boxShadow: AppTheme.hardShadow,
                        ),
                      ),
                      const SizedBox(height: 12),
                      // 标题
                      Text(
                        _event.title,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // 详情内容
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 完成状态 / 标记完成
                  _buildCompleteSection(),

                  const SizedBox(height: 16),

                  // 时间信息卡片
                  _buildInfoCard(
                    icon: Icons.access_time_rounded,
                    title: '时间',
                    children: [
                      _buildInfoRow(
                        '开始',
                        DateFormat('yyyy年M月d日 HH:mm').format(_event.startTime),
                      ),
                      if (_event.endTime != null)
                        _buildInfoRow(
                          '结束',
                          DateFormat('yyyy年M月d日 HH:mm').format(_event.endTime!),
                        ),
                    ],
                  ),

                  const SizedBox(height: 12),

                  // 公司信息卡片
                  if (_event.company != null || _event.role != null || _event.round != null)
                    _buildInfoCard(
                      icon: Icons.business_center_outlined,
                      title: '面试信息',
                      children: [
                        if (_event.company != null)
                          _buildInfoRow('公司', _event.company!),
                        if (_event.role != null)
                          _buildInfoRow('岗位', _event.role!),
                        if (_event.round != null)
                          _buildInfoRow('轮次', _event.round!.label),
                      ],
                    ),

                  if (_event.company != null || _event.role != null || _event.round != null)
                    const SizedBox(height: 12),

                  // 地点卡片：文字可长按选中复制，也可以点右侧按钮一键复制
                  if (_event.location != null && _event.location!.isNotEmpty)
                    _buildInfoCard(
                      icon: Icons.location_on_outlined,
                      title: '地点',
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: SelectableText(
                                _event.location!,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w500,
                                  color: AppTheme.textPrimary,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              onPressed: () => _copyText(_event.location!),
                              icon: const Icon(Icons.copy_rounded, size: 18),
                              color: AppTheme.primary,
                              tooltip: '复制地点',
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                            ),
                          ],
                        ),
                      ],
                    ),

                  if (_event.location != null && _event.location!.isNotEmpty)
                    const SizedBox(height: 12),

                  // 会议链接卡片
                  if (_event.meetingUrl != null && _event.meetingUrl!.isNotEmpty)
                    _buildInfoCard(
                      icon: Icons.link,
                      title: '会议链接',
                      children: [
                        GestureDetector(
                          onTap: _openMeetingUrl,
                          child: Text(
                            _event.meetingUrl!,
                            style: const TextStyle(
                              fontSize: 14,
                              color: AppTheme.accent,
                              decoration: TextDecoration.underline,
                            ),
                          ),
                        ),
                      ],
                    ),

                  if (_event.meetingUrl != null && _event.meetingUrl!.isNotEmpty)
                    const SizedBox(height: 12),

                  // 备注卡片
                  if (_event.notes != null && _event.notes!.isNotEmpty)
                    _buildInfoCard(
                      icon: Icons.notes_rounded,
                      title: '备注',
                      children: [
                        Text(
                          _event.notes!,
                          style: const TextStyle(
                            fontSize: 14,
                            color: AppTheme.textPrimary,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),

                  const SizedBox(height: 24),

                  // 分享按钮
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _shareIcs,
                      icon: const Icon(Icons.share_rounded),
                      label: const Text('分享 ICS 文件'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.primary,
                        side: BorderSide(color: AppTheme.buttonOutline, width: AppTheme.outlineWidth),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        ],
      ),
      ),
    );
  }

  /// 完成状态区：未开始 → 灰色不可点并说明还要等多久；
  /// 已开始 → 绿色按钮可标记；已完成 → 显示完成时刻并允许撤销。
  Widget _buildCompleteSection() {
    final completed = _event.isCompleted;

    if (completed) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.success.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
          border: Border.all(color: AppTheme.success.withValues(alpha: 0.4)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.check_circle_rounded, color: AppTheme.success, size: 22),
                const SizedBox(width: 8),
                const Text(
                  '已完成',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.success),
                ),
                const Spacer(),
                Text(
                  DateFormat('M月d日 HH:mm').format(_event.completedAt!),
                  style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _toggleCompleted,
                icon: const Icon(Icons.undo_rounded, size: 18),
                label: const Text('取消完成标记'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.textSecondary,
                  side: BorderSide(color: AppTheme.buttonOutline, width: AppTheme.outlineWidth),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (!_event.hasStarted) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.textSecondary.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
          border: Border.all(color: AppTheme.textSecondary.withValues(alpha: 0.2)),
        ),
        child: Row(
          children: [
            Icon(Icons.lock_clock_rounded, size: 22, color: AppTheme.textSecondary.withValues(alpha: 0.7)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '事件开始后才能标记完成',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textSecondary.withValues(alpha: 0.9),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '还有 ${_formatRemaining(_event.timeUntilCompletable!)}',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppTheme.textSecondary.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: _busy ? null : _toggleCompleted,
        icon: _busy
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : const Icon(Icons.check_rounded, size: 20),
        label: const Text('标记为已完成', style: TextStyle(fontSize: 16)),
        style: ElevatedButton.styleFrom(
          backgroundColor: AppTheme.success,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppTheme.radiusMedium)),
        ),
      ),
    );
  }

  String _formatRemaining(Duration d) {
    if (d.isNegative) return '不到 1 分钟';
    if (d.inDays > 0) {
      final hours = d.inHours % 24;
      return hours > 0 ? '${d.inDays} 天 $hours 小时' : '${d.inDays} 天';
    }
    if (d.inHours > 0) {
      final minutes = d.inMinutes % 60;
      return minutes > 0 ? '${d.inHours} 小时 $minutes 分钟' : '${d.inHours} 小时';
    }
    return '${d.inMinutes} 分钟';
  }

  Widget _buildInfoCard({
    required IconData icon,
    required String title,
    required List<Widget> children,
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
              Icon(icon, size: 18, color: AppTheme.primary),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          if (label.isNotEmpty) ...[
            Text(
              '$label：',
              style: const TextStyle(
                fontSize: 14,
                color: AppTheme.textSecondary,
              ),
            ),
          ],
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: AppTheme.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
