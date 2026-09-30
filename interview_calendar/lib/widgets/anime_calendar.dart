import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../theme/app_theme.dart';
import 'day_cell.dart';

/// 卡通风格月历组件
///
/// 月份（[month]）由父组件控制，翻页时通过 [onMonthChanged] 回传，
/// 而不是自己偷偷改内部状态 —— 否则父组件的「当前月」永远停在旧月，
/// 事件红点会串到下个月去。
class AnimeCalendar extends StatefulWidget {
  /// 当前显示的月份（由父组件掌控）
  final DateTime month;

  final Map<int, int> eventCounts; // day -> count
  final ValueChanged<DateTime>? onDaySelected;
  final ValueChanged<DateTime>? onMonthChanged;
  final DateTime? selectedDate;

  const AnimeCalendar({
    super.key,
    required this.month,
    this.eventCounts = const {},
    this.onDaySelected,
    this.onMonthChanged,
    this.selectedDate,
  });

  @override
  State<AnimeCalendar> createState() => _AnimeCalendarState();
}

class _AnimeCalendarState extends State<AnimeCalendar> {
  late DateTime _selectedDate;

  @override
  void initState() {
    super.initState();
    _selectedDate = widget.selectedDate ?? DateTime.now();
  }

  @override
  void didUpdateWidget(AnimeCalendar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedDate != null && widget.selectedDate != oldWidget.selectedDate) {
      _selectedDate = widget.selectedDate!;
    }
  }

  void _previousMonth() {
    final m = widget.month;
    widget.onMonthChanged?.call(DateTime(m.year, m.month - 1));
  }

  void _nextMonth() {
    final m = widget.month;
    widget.onMonthChanged?.call(DateTime(m.year, m.month + 1));
  }

  void _goToToday() {
    final now = DateTime.now();
    setState(() => _selectedDate = now);
    widget.onDaySelected?.call(now);
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final year = widget.month.year;
    final month = widget.month.month;

    // 本月第一天是星期几（1=周一，7=周日）
    final firstDay = DateTime(year, month, 1);
    final firstWeekday = firstDay.weekday;

    // 本月有多少天
    final daysInMonth = DateTime(year, month + 1, 0).day;

    // 上个月需要显示的天数
    final prevMonthDays = DateTime(year, month, 0).day;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
        border: Border.all(color: AppTheme.outline, width: AppTheme.outlineWidth),
        boxShadow: AppTheme.hardShadow,
      ),
      child: Column(
        children: [
          // 月份导航栏
          _buildHeader(),

          // 星期标题
          _buildWeekdayHeaders(),

          // 日期网格
          _buildGrid(firstWeekday, daysInMonth, prevMonthDays, now, year, month),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    final monthName = DateFormat('yyyy年M月').format(widget.month);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // 上月按钮
          _NavButton(
            icon: Icons.chevron_left_rounded,
            onTap: _previousMonth,
          ),

          // 月份标题
          GestureDetector(
            onTap: _goToToday,
            child: Text(
              monthName,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: AppTheme.textPrimary,
              ),
            ),
          ),

          // 下月按钮
          _NavButton(
            icon: Icons.chevron_right_rounded,
            onTap: _nextMonth,
          ),
        ],
      ),
    );
  }

  Widget _buildWeekdayHeaders() {
    final weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: weekdays.map((day) {
          final isWeekend = day == '六' || day == '日';
          return Expanded(
            child: Center(
              child: Text(
                day,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: isWeekend
                      ? AppTheme.primary.withValues(alpha: 0.7)
                      : AppTheme.textSecondary,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildGrid(
    int firstWeekday,
    int daysInMonth,
    int prevMonthDays,
    DateTime now,
    int year,
    int month,
  ) {
    final cells = <Widget>[];
    final totalCells = ((firstWeekday - 1 + daysInMonth) / 7).ceil() * 7;

    for (int i = 0; i < totalCells; i++) {
      final dayOffset = i - (firstWeekday - 1);

      if (dayOffset < 0) {
        // 上个月的日期
        final day = prevMonthDays + dayOffset + 1;
        cells.add(DayCell(
          day: day,
          isCurrentMonth: false,
          eventCount: 0,
        ));
      } else if (dayOffset >= daysInMonth) {
        // 下个月的日期
        final day = dayOffset - daysInMonth + 1;
        cells.add(DayCell(
          day: day,
          isCurrentMonth: false,
          eventCount: 0,
        ));
      } else {
        // 本月的日期
        final day = dayOffset + 1;
        final date = DateTime(year, month, day);
        final isToday = date.year == now.year &&
            date.month == now.month &&
            date.day == now.day;
        final isSelected = date.year == _selectedDate.year &&
            date.month == _selectedDate.month &&
            date.day == _selectedDate.day;

        cells.add(DayCell(
          day: day,
          isCurrentMonth: true,
          isToday: isToday,
          isSelected: isSelected,
          eventCount: widget.eventCounts[day] ?? 0,
          onTap: () {
            setState(() => _selectedDate = date);
            widget.onDaySelected?.call(date);
          },
        ));
      }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: GridView.count(
        crossAxisCount: 7,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        childAspectRatio: 1.0,
        children: cells,
      ),
    );
  }
}

/// 导航按钮
class _NavButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _NavButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: AppTheme.primaryLight.withValues(alpha: 0.2),
          // 经典=原版 r12 无描边，lowpoly=r6 黑描边
          borderRadius: BorderRadius.circular(AppTheme.isLowpoly ? AppTheme.radiusSmall : 12),
          border: Border.all(color: AppTheme.outline, width: AppTheme.outlineWidth),
        ),
        child: Icon(icon, size: 20, color: AppTheme.primary),
      ),
    );
  }
}
