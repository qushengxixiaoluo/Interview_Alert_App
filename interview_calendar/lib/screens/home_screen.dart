import 'package:flutter/material.dart';
import '../models/event.dart';
import '../services/database.dart';
import '../widgets/anime_calendar.dart';
import '../widgets/event_card.dart';
import '../theme/app_theme.dart';
import 'event_form_screen.dart';
import 'event_detail_screen.dart';
import 'assistant_screen.dart';
import 'data_screen.dart';
import 'mail_sync_screen.dart';
import 'screenshot_task_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _db = DatabaseService.instance;
  DateTime _selectedDate = DateTime.now();
  DateTime _currentMonth = DateTime.now();
  List<InterviewEvent> _dayEvents = [];
  Map<int, int> _monthEventCounts = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    if (mounted) setState(() => _loading = true);

    try {
      final dayEvents = await _db.getEventsForDay(_selectedDate);
      final monthEvents = await _db.getEventsForMonth(_currentMonth);

      final counts = <int, int>{};
      for (final e in monthEvents) {
        // getEventsForMonth 会带回上月末/下月初的补位事件（用来铺满日历网格），
        // 但它们不属于当前月，不能算进当前月的红点，否则 20 号的事件会串到下个月。
        // 已完成的事件也不再算进红点 —— 标记完成就等于「已处理」，不该再提醒。
        if (!e.isCompleted &&
            e.startTime.year == _currentMonth.year &&
            e.startTime.month == _currentMonth.month) {
          counts[e.startTime.day] = (counts[e.startTime.day] ?? 0) + 1;
        }
      }

      if (mounted) {
        setState(() {
          _dayEvents = dayEvents;
          _monthEventCounts = counts;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('读取数据失败：$e'), backgroundColor: AppTheme.badge),
        );
      }
    }
  }

  void _onDaySelected(DateTime date) {
    setState(() {
      _selectedDate = date;
      // 跟着选中的日期一起切月，保证红点和下方列表对得上
      _currentMonth = DateTime(date.year, date.month);
    });
    _loadData();
  }

  void _onMonthChanged(DateTime month) {
    setState(() => _currentMonth = month);
    _loadData();
  }

  /// 新增/编辑事件后，把日历切到事件所在那天，让用户立刻能看到它。
  /// 传 null 表示没有需要定位的事件，只刷新数据。
  void _focusOn(DateTime? date) {
    if (!mounted) return;
    setState(() {
      if (date != null) {
        _selectedDate = date;
        _currentMonth = DateTime(date.year, date.month);
      }
    });
    _loadData();
  }

  void _goToday() {
    final now = DateTime.now();
    setState(() {
      _selectedDate = now;
      _currentMonth = now;
    });
    _loadData();
  }

  String _formatDateHeader(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(date.year, date.month, date.day);
    final diff = target.difference(today).inDays;

    if (diff == 0) return '今天';
    if (diff == 1) return '明天';
    if (diff == -1) return '昨天';

    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    return '${date.month}月${date.day}日 星期${weekdays[date.weekday - 1]}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        // 整页放在一个滚动视图里：小屏手机上日历占满后，
        // 下面的事件列表还能滑出来，而不是被挤没
        child: RefreshIndicator(
          onRefresh: _loadData,
          color: AppTheme.primary,
          child: ListView(
            padding: EdgeInsets.zero,
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              _buildHeader(),
              AnimeCalendar(
                month: _currentMonth,
                selectedDate: _selectedDate,
                eventCounts: _monthEventCounts,
                onDaySelected: _onDaySelected,
                onMonthChanged: _onMonthChanged,
              ),
              const SizedBox(height: 12),
              _buildEventSection(),
              const SizedBox(height: 80), // 给浮动按钮留出空间
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddMenu,
        backgroundColor: AppTheme.primary,
        // 经典=原版浮起阴影，lowpoly=贴纸式贴平（靠黑描边出立体感）
        elevation: AppTheme.isLowpoly ? 0 : 4,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
          side: BorderSide(color: AppTheme.outline, width: AppTheme.outlineWidth),
        ),
        child: const Icon(Icons.add_rounded, color: Colors.white, size: 28),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Row(
        children: [
          const Icon(Icons.calendar_month_rounded, color: AppTheme.primary, size: 26),
          const SizedBox(width: 8),
          const Text(
            '事件日历',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppTheme.textPrimary),
          ),
          const Spacer(),
          // AI 助手
          _headerChip(
            icon: Icons.auto_awesome,
            label: 'AI 助手',
            color: AppTheme.accent,
            onTap: () async {
              final savedDate = await Navigator.push<DateTime>(
                context,
                MaterialPageRoute(builder: (_) => const AssistantScreen()),
              );
              _focusOn(savedDate);
            },
          ),
          const SizedBox(width: 6),
          // 今天
          _headerChip(
            icon: Icons.today_rounded,
            label: '今天',
            color: AppTheme.primary,
            onTap: _goToday,
          ),
          const SizedBox(width: 4),
          // 邮箱导入（只放图标，避免小屏挤爆）
          IconButton(
            onPressed: () async {
              final savedDate = await Navigator.push<DateTime>(
                context,
                MaterialPageRoute(builder: (_) => const MailSyncScreen()),
              );
              _focusOn(savedDate);
            },
            icon: const Icon(Icons.mail_outline, size: 20),
            color: AppTheme.textSecondary,
            tooltip: '邮箱导入',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
          const SizedBox(width: 4),
          // 数据备份（只放图标，避免小屏挤爆）
          IconButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const DataScreen()),
            ).then((_) => _loadData()),
            icon: const Icon(Icons.folder_outlined, size: 20),
            color: AppTheme.textSecondary,
            tooltip: '数据与备份',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ],
      ),
    );
  }

  Widget _headerChip({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEventSection() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppTheme.radiusLarge)),
        border: Border(top: BorderSide(color: AppTheme.outline, width: AppTheme.outlineWidth)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 日期标题
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
            child: Row(
              children: [
                Text(
                  _formatDateHeader(_selectedDate),
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppTheme.textPrimary),
                ),
                const SizedBox(width: 8),
                if (_dayEvents.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppTheme.primary,
                      border: Border.all(color: AppTheme.outline, width: AppTheme.outlineWidth),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${_dayEvents.length}',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white),
                    ),
                  ),
              ],
            ),
          ),

          // 事件列表
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(child: CircularProgressIndicator(color: AppTheme.primary)),
            )
          else if (_dayEvents.isEmpty)
            _buildEmptyState()
          else
            ..._dayEvents.map(
              (event) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: EventCard(event: event, onTap: () => _openEventDetail(event)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    // 外层列表是 CrossAxisAlignment.start，会把这个 Column 推到左边。
    // 包一层全宽的 SizedBox，Column 默认的居中对齐才能让图标和文字真正居中。
    return SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 48),
        child: Column(
          children: [
            Icon(
              Icons.event_available_rounded,
              size: 56,
              color: AppTheme.primaryLight.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 12),
            Text(
              '这天没有安排',
              style: TextStyle(fontSize: 16, color: AppTheme.textSecondary.withValues(alpha: 0.8)),
            ),
            const SizedBox(height: 4),
            Text(
              '点右下角 + 添加，或用 AI 助手粘贴邮件',
              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary.withValues(alpha: 0.55)),
            ),
          ],
        ),
      ),
    );
  }

  /// 点「+」弹出添加方式选择：手动填写，或从截图识别任务进来
  void _showAddMenu() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppTheme.radiusLarge)),
        side: BorderSide(color: AppTheme.outline, width: AppTheme.outlineWidth),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('添加事件', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              _buildAddOption(
                icon: Icons.edit_calendar_outlined,
                title: '手动添加',
                subtitle: '自己填写时间、地点等信息',
                onTap: () {
                  Navigator.pop(ctx);
                  _createEvent();
                },
              ),
              const SizedBox(height: 8),
              _buildAddOption(
                icon: Icons.image_search_outlined,
                title: '截图识别',
                subtitle: '上传截图，AI 识别文字并总结任务',
                onTap: () {
                  Navigator.pop(ctx);
                  _createFromScreenshot();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAddOption({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          border: Border.all(color: AppTheme.primaryLight.withValues(alpha: 0.5)),
          borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        ),
        child: Row(
          children: [
            Icon(icon, size: 22, color: AppTheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 12, color: AppTheme.textSecondary.withValues(alpha: 0.8)),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, size: 20, color: AppTheme.textSecondary),
          ],
        ),
      ),
    );
  }

  Future<void> _createFromScreenshot() async {
    final savedDate = await Navigator.push<DateTime>(
      context,
      MaterialPageRoute(builder: (_) => const ScreenshotTaskScreen()),
    );
    _focusOn(savedDate);
  }

  Future<void> _createEvent() async {
    final savedDate = await Navigator.push<DateTime>(
      context,
      MaterialPageRoute(builder: (_) => EventFormScreen(initialDate: _selectedDate)),
    );
    // 无条件刷新：子页面可能被系统返回手势关掉，那时返回值是 null。
    // 有返回值时顺带把日历切到新事件那天，否则刚加的记录看不见。
    _focusOn(savedDate);
  }

  Future<void> _openEventDetail(InterviewEvent event) async {
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => EventDetailScreen(event: event)),
    );
    _loadData();
  }
}
