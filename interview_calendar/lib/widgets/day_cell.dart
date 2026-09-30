import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// 日期格子组件
class DayCell extends StatelessWidget {
  final int day;
  final bool isCurrentMonth;
  final bool isToday;
  final bool isSelected;
  final int eventCount;
  final VoidCallback? onTap;

  const DayCell({
    super.key,
    required this.day,
    this.isCurrentMonth = true,
    this.isToday = false,
    this.isSelected = false,
    this.eventCount = 0,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.primary
              : isToday
                  ? AppTheme.primaryLight.withValues(alpha: 0.3)
                  : Colors.transparent,
          borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
          // low-poly：当月格子铺黑网格、今天/选中加粗，非当月不描边；
          // 经典：只有今天有蓝色描边（outline 透明，其余自动隐身）
          border: isCurrentMonth
              ? Border.all(
                  color: isToday ? AppTheme.todayBorder : AppTheme.outline,
                  width: isToday || isSelected ? 2 : 1.5,
                )
              : null,
          boxShadow: isSelected
              ? (AppTheme.isLowpoly
                  ? const [
                      BoxShadow(
                        color: Color(0xFF141414),
                        offset: Offset(2, 2),
                        blurRadius: 0,
                      ),
                    ]
                  : [
                      BoxShadow(
                        color: AppTheme.primary.withValues(alpha: 0.3),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ])
              : null,
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            // 日期数字
            Text(
              '$day',
              style: TextStyle(
                fontSize: 16,
                fontWeight: isToday || isSelected ? FontWeight.w700 : FontWeight.w500,
                color: isSelected
                    ? Colors.white
                    : isCurrentMonth
                        ? AppTheme.textPrimary
                        : AppTheme.textSecondary.withValues(alpha: 0.5),
              ),
            ),

            // 红点徽标
            if (eventCount > 0)
              Positioned(
                top: 2,
                right: 2,
                child: Container(
                  constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    color: AppTheme.badge,
                    borderRadius: BorderRadius.circular(8),
                    border: AppTheme.isLowpoly
                        ? Border.all(color: AppTheme.outline, width: 1.5)
                        : null,
                    boxShadow: AppTheme.isLowpoly
                        ? const [
                            BoxShadow(
                              color: Color(0xFF141414),
                              offset: Offset(1.5, 1.5),
                              blurRadius: 0,
                            ),
                          ]
                        : [
                            BoxShadow(
                              color: AppTheme.badge.withValues(alpha: 0.3),
                              blurRadius: 4,
                              offset: const Offset(0, 1),
                            ),
                          ],
                  ),
                  child: Text(
                    eventCount > 99 ? '99+' : '$eventCount',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
