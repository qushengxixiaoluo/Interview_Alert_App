import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/event.dart';
import '../services/database.dart';
import '../theme/app_theme.dart';

/// 事件新建/编辑表单
class EventFormScreen extends StatefulWidget {
  final DateTime initialDate;
  final InterviewEvent? existingEvent;

  const EventFormScreen({
    super.key,
    required this.initialDate,
    this.existingEvent,
  });

  @override
  State<EventFormScreen> createState() => _EventFormScreenState();
}

class _EventFormScreenState extends State<EventFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _db = DatabaseService.instance;

  late TextEditingController _titleCtrl;
  late TextEditingController _companyCtrl;
  late TextEditingController _roleCtrl;
  late TextEditingController _locationCtrl;
  late TextEditingController _meetingUrlCtrl;
  late TextEditingController _notesCtrl;

  late DateTime _startTime;
  DateTime? _endTime;
  InterviewRound? _round;
  EventColor _color = EventColor.blue;
  bool _saving = false;

  /// 只有带数据库 id 的才叫「编辑」。
  ///
  /// AI 助手「编辑后保存」传进来的 existingEvent 是预填好、但 id 为 null 的事件，
  /// 如果按编辑处理会走 updateEvent，而 updateEvent 遇到 id 为 null 直接 return 0，
  /// 事件就静默丢失了。所以这里必须看 id，而不是看 existingEvent 是否为 null。
  bool get _isEditing => widget.existingEvent?.id != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existingEvent;

    _titleCtrl = TextEditingController(text: e?.title ?? '');
    _companyCtrl = TextEditingController(text: e?.company ?? '');
    _roleCtrl = TextEditingController(text: e?.role ?? '');
    _locationCtrl = TextEditingController(text: e?.location ?? '');
    _meetingUrlCtrl = TextEditingController(text: e?.meetingUrl ?? '');
    _notesCtrl = TextEditingController(text: e?.notes ?? '');

    _startTime = e?.startTime ?? widget.initialDate;
    _endTime = e?.endTime;
    _round = e?.round;
    _color = e?.color ?? EventColor.blue;
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _companyCtrl.dispose();
    _roleCtrl.dispose();
    _locationCtrl.dispose();
    _meetingUrlCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickStartTime() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _startTime,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
    );
    if (date == null || !mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_startTime),
    );
    if (time == null) return;

    setState(() {
      _startTime = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    });
  }

  Future<void> _pickEndTime() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _endTime ?? _startTime.add(const Duration(hours: 1)),
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
    );
    if (date == null || !mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(
        _endTime ?? _startTime.add(const Duration(hours: 1)),
      ),
    );
    if (time == null) return;

    setState(() {
      _endTime = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _saving = true);

    final now = DateTime.now();
    final event = InterviewEvent(
      id: widget.existingEvent?.id,
      title: _titleCtrl.text.trim(),
      company: _companyCtrl.text.trim().isEmpty ? null : _companyCtrl.text.trim(),
      role: _roleCtrl.text.trim().isEmpty ? null : _roleCtrl.text.trim(),
      round: _round,
      startTime: _startTime,
      endTime: _endTime,
      location: _locationCtrl.text.trim().isEmpty ? null : _locationCtrl.text.trim(),
      meetingUrl: _meetingUrlCtrl.text.trim().isEmpty ? null : _meetingUrlCtrl.text.trim(),
      color: _color,
      notes: _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
      createdAt: widget.existingEvent?.createdAt ?? now,
      updatedAt: now,
    );

    if (_isEditing) {
      await _db.updateEvent(event);
    } else {
      await _db.insertEvent(event);
    }

    if (mounted) Navigator.pop(context, event.startTime);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? '编辑事件' : '新建事件'),
        actions: [
          // 保存按钮
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
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
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            // 标题
            _buildField(
              label: '事件标题 *',
              child: TextFormField(
                controller: _titleCtrl,
                decoration: _inputDecoration('例如：字节跳动一面'),
                validator: (v) => (v == null || v.trim().isEmpty) ? '标题不能为空' : null,
              ),
            ),

            const SizedBox(height: 16),

            // 公司 + 岗位（一行两列）
            Row(
              children: [
                Expanded(
                  child: _buildField(
                    label: '公司',
                    child: _buildTextFiled(_companyCtrl, '公司名'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildField(
                    label: '岗位',
                    child: _buildTextFiled(_roleCtrl, '岗位名称'),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),

            // 面试轮次
            _buildField(
              label: '轮次',
              child: _buildRoundSelector(),
            ),

            const SizedBox(height: 16),

            // 开始时间
            _buildField(
              label: '开始时间 *',
              child: _buildTimeSelector(
                time: _startTime,
                onTap: _pickStartTime,
              ),
            ),

            const SizedBox(height: 12),

            // 结束时间
            _buildField(
              label: '结束时间',
              child: _buildTimeSelector(
                time: _endTime,
                isOptional: true,
                onTap: _pickEndTime,
              ),
            ),

            const SizedBox(height: 16),

            // 地点
            _buildField(
              label: '地点',
              child: _buildTextFiled(_locationCtrl, '线上/线下地址'),
            ),

            const SizedBox(height: 16),

            // 会议链接
            _buildField(
              label: '会议链接',
              child: _buildTextFiled(_meetingUrlCtrl, 'https://...'),
            ),

            const SizedBox(height: 16),

            // 颜色标记
            _buildField(
              label: '颜色标记',
              child: _buildColorSelector(),
            ),

            const SizedBox(height: 16),

            // 备注
            _buildField(
              label: '备注',
              child: _buildTextFiled(_notesCtrl, '其他信息...', maxLines: 3),
            ),

            const SizedBox(height: 32),

            // 保存按钮
            ElevatedButton(
              onPressed: _saving ? null : _save,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  _isEditing ? '更新事件' : '创建事件',
                  style: const TextStyle(fontSize: 16),
                ),
              ),
            ),

            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _buildField({required String label, required Widget child}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: AppTheme.textSecondary,
          ),
        ),
        const SizedBox(height: 6),
        child,
      ],
    );
  }

  Widget _buildTextFiled(TextEditingController ctrl, String hint, {int maxLines = 1}) {
    return TextFormField(
      controller: ctrl,
      maxLines: maxLines,
      decoration: _inputDecoration(hint),
    );
  }

  InputDecoration _inputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: AppTheme.textSecondary.withValues(alpha: 0.5)),
    );
  }

  Widget _buildRoundSelector() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: InterviewRound.values.map((round) {
        final selected = _round == round;
        return GestureDetector(
          onTap: () => setState(() => _round = selected ? null : round),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: selected
                  ? AppTheme.primary
                  : AppTheme.primaryLight.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              round.label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : AppTheme.textPrimary,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildTimeSelector({
    required DateTime? time,
    required VoidCallback onTap,
    bool isOptional = false,
  }) {
    final text = time != null
        ? DateFormat('yyyy年M月d日 HH:mm').format(time)
        : (isOptional ? '未设置' : '请选择');
    final hasValue = time != null;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
          // 经典=原版浅蓝细线，lowpoly=黑描边
          border: AppTheme.isLowpoly
              ? Border.all(color: AppTheme.outline, width: AppTheme.outlineWidth)
              : Border.all(
                  color: hasValue
                      ? AppTheme.primaryLight
                      : AppTheme.primaryLight.withValues(alpha: 0.5),
                ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.access_time_rounded,
              size: 20,
              color: hasValue ? AppTheme.primary : AppTheme.textSecondary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  fontSize: 15,
                  color: hasValue ? AppTheme.textPrimary : AppTheme.textSecondary,
                ),
              ),
            ),
            if (!hasValue)
              Icon(Icons.chevron_right, color: AppTheme.textSecondary.withValues(alpha: 0.5)),
          ],
        ),
      ),
    );
  }

  Widget _buildColorSelector() {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: EventColor.values.map((c) {
        final selected = _color == c;
        return GestureDetector(
          onTap: () => setState(() => _color = c),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: c.color,
              shape: BoxShape.circle,
              // 经典=白描边+色光晕（原版），lowpoly=黑描边+硬阴影
              border: selected
                  ? Border.all(
                      color: AppTheme.isLowpoly ? AppTheme.outline : Colors.white,
                      width: 3,
                    )
                  : null,
              boxShadow: selected
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
                            color: c.color.withValues(alpha: 0.5),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ])
                  : null,
            ),
            child: selected
                ? const Icon(Icons.check, color: Colors.white, size: 18)
                : null,
          ),
        );
      }).toList(),
    );
  }
}
