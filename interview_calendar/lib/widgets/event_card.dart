import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/event.dart';
import '../theme/app_theme.dart';

/// 事件卡片组件（时间轴样式）
class EventCard extends StatelessWidget {
  final InterviewEvent event;
  final VoidCallback? onTap;

  const EventCard({super.key, required this.event, this.onTap});

  @override
  Widget build(BuildContext context) {
    final timeStr = DateFormat('HH:mm').format(event.startTime);
    // 已完成的事件整体转灰，让「还没参加的」在列表里一眼可辨
    final color = event.isCompleted ? AppTheme.textSecondary : event.color.color;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 左侧时间轴
              SizedBox(
                width: 60,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // 时间轴顶部圆点：lowpoly=黑描边小圆，经典=原版色光晕
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: AppTheme.isLowpoly
                            ? Border.all(color: AppTheme.outline, width: 1.5)
                            : null,
                        boxShadow: AppTheme.isLowpoly
                            ? null
                            : [
                                BoxShadow(
                                  color: color.withValues(alpha: 0.4),
                                  blurRadius: 6,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                      ),
                    ),
                    // 时间轴线
                    Expanded(
                      child: Container(
                        width: 2,
                        color: color.withValues(alpha: 0.3),
                      ),
                    ),
                  ],
                ),
              ),

              // 右侧卡片内容
              Expanded(
                child: Container(
                  margin: const EdgeInsets.only(bottom: 4),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
                    // 经典=原版事件色淡边，lowpoly=统一黑描边
                    border: AppTheme.isLowpoly
                        ? Border.all(color: AppTheme.outline, width: AppTheme.outlineWidth)
                        : Border.all(color: color.withValues(alpha: 0.2), width: 1),
                    boxShadow: AppTheme.hardShadow,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 第一行：时间 + 标题
                      Row(
                        children: [
                          // 时间标签
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: 0.1),
                              // 经典=原版 r6 无描边，lowpoly=r4 黑描边
                              borderRadius:
                                  BorderRadius.circular(AppTheme.isLowpoly ? 4 : 6),
                              border: AppTheme.isLowpoly
                                  ? Border.all(color: AppTheme.outline, width: 1.5)
                                  : null,
                            ),
                            child: Text(
                              timeStr,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: color,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          // 标题
                          Expanded(
                            child: Text(
                              event.title,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: event.isCompleted
                                    ? AppTheme.textSecondary
                                    : AppTheme.textPrimary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          // 已完成标记
                          if (event.isCompleted) ...[
                            const SizedBox(width: 6),
                            const Icon(
                              Icons.check_circle_rounded,
                              size: 18,
                              color: AppTheme.success,
                            ),
                          ],
                        ],
                      ),

                      // 第二行：公司 + 岗位 + 轮次
                      if (_hasSubInfo()) ...[
                        const SizedBox(height: 8),
                        _buildSubInfo(),
                      ],

                      // 第三行：地点 / 链接 / 备注
                      if (event.location != null && event.location!.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        _buildIconText(Icons.location_on_outlined, event.location!),
                      ],
                      if (event.meetingUrl != null && event.meetingUrl!.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        _buildIconText(Icons.link, '有会议链接'),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool _hasSubInfo() {
    return (event.company != null && event.company!.isNotEmpty) ||
        (event.role != null && event.role!.isNotEmpty) ||
        event.round != null;
  }

  Widget _buildSubInfo() {
    final parts = <String>[];
    if (event.company != null && event.company!.isNotEmpty) {
      parts.add(event.company!);
    }
    if (event.role != null && event.role!.isNotEmpty) {
      parts.add(event.role!);
    }
    if (event.round != null) {
      parts.add(event.round!.label);
    }

    return Row(
      children: [
        Icon(Icons.business_outlined, size: 14, color: AppTheme.textSecondary),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            parts.join(' · '),
            style: const TextStyle(
              fontSize: 13,
              color: AppTheme.textSecondary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _buildIconText(IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, size: 14, color: AppTheme.textSecondary),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 12,
              color: AppTheme.textSecondary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
