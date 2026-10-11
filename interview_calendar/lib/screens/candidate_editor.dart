import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/llm_service.dart';
import '../theme/app_theme.dart';

/// 候选编辑器：上半屏看原文（邮件正文 / 截图识别文字），下半屏改 AI 抽出来的值。
/// 点保存时把改好的值装回一个 [ExtractionResult] 返回给调用方。
/// 邮箱导入和截图识别共用这一个页面，避免两处各写一遍编辑表单。
class CandidateEditorScreen extends StatefulWidget {
  /// 原文标题：邮件主题 / 「截图识别」
  final String originalTitle;

  /// 标题下一行的来源信息：发件人 · 时间 / 来源说明，空则不显示
  final String originalMeta;

  /// 原文正文：邮件纯文本 / 截图里识别出的文字
  final String originalBody;

  final ExtractionResult initial;

  const CandidateEditorScreen({
    super.key,
    required this.originalTitle,
    this.originalMeta = '',
    required this.originalBody,
    required this.initial,
  });

  @override
  State<CandidateEditorScreen> createState() => _CandidateEditorScreenState();
}

class _CandidateEditorScreenState extends State<CandidateEditorScreen> {
  late final TextEditingController _companyCtrl;
  late final TextEditingController _roleCtrl;
  late final TextEditingController _locationCtrl;
  late final TextEditingController _meetingUrlCtrl;
  late final TextEditingController _durationCtrl;

  late DateTime _startTime;
  late String _round;

  /// 「时间类型」开关：true = 下面那个时间是截止期限（如「10月15日前完成测评」），
  /// 不是面试/笔试的开始时间。
  late bool _deadlineMode;

  /// 非截止模式下的附加期限（有固定场次、另有一个截止点）
  late DateTime? _extraDeadline;

  static const _rounds = ['一面', '二面', '三面', '终面', 'HR面', '笔试', '测评'];

  @override
  void initState() {
    super.initState();
    final r = widget.initial;
    _companyCtrl = TextEditingController(text: r.company);
    _roleCtrl = TextEditingController(text: r.role);
    _locationCtrl = TextEditingController(text: r.location);
    _meetingUrlCtrl = TextEditingController(text: r.meetingUrl);
    _durationCtrl = TextEditingController(text: r.durationMinutes.toString());
    // 纯截止类进来时 startTime 是空的，锚点在 deadline 上
    _deadlineMode = r.isDeadlineOnly;
    _startTime = r.startTime ?? r.deadline ?? DateTime.now();
    _extraDeadline = r.isDeadlineOnly ? null : r.deadline;
    _round = r.round;
  }

  @override
  void dispose() {
    _companyCtrl.dispose();
    _roleCtrl.dispose();
    _locationCtrl.dispose();
    _meetingUrlCtrl.dispose();
    _durationCtrl.dispose();
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

  void _save() {
    final company = _companyCtrl.text.trim();
    final role = _roleCtrl.text.trim();
    final location = _locationCtrl.text.trim();
    final meetingUrl = _meetingUrlCtrl.text.trim();
    final duration =
        int.tryParse(_durationCtrl.text.trim()) ?? widget.initial.durationMinutes;

    final updated = ExtractionResult(
      isInterview: true,
      title: company.isNotEmpty ? company : widget.initial.title,
      company: company,
      role: role,
      round: _round,
      // 截止模式：时间放进 deadline、场次留空 → 下游按「截止事件」处理
      startTime: _deadlineMode ? null : _startTime,
      deadline: _deadlineMode ? _startTime : _extraDeadline,
      durationMinutes: duration,
      timeIsExplicit: widget.initial.timeIsExplicit,
      location: location,
      meetingUrl: meetingUrl,
      contact: widget.initial.contact,
      notes: widget.initial.notes,
      confidence: widget.initial.confidence,
      category: widget.initial.category,
      summary: widget.initial.summary,
      rawJson: widget.initial.rawJson,
    );
    Navigator.pop(context, updated);
  }

  /// 什么情况下展示「这是截止时间」开关：类别是测评、轮次是笔试/测评，
  /// 或者 AI 原本就抽出了截止时间（避免用户把截止改成场次后开关又消失）
  bool get _canToggleDeadlineMode =>
      _deadlineMode ||
      widget.initial.category == 'assessment' ||
      _round == '笔试' ||
      _round == '测评' ||
      widget.initial.deadline != null;

  /// 附加期限选择器：只在「有固定场次」时才有意义
  bool get _showExtraDeadline => !_deadlineMode && _canToggleDeadlineMode;

  Future<void> _pickExtraDeadline() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _extraDeadline ?? _startTime,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_extraDeadline ?? _startTime),
    );
    if (time == null) return;
    setState(() {
      _extraDeadline = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('查看原文 · 修改'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton(
              onPressed: _save,
              child: const Text(
                '保存',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.primary),
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _buildOriginalCard(),
          const SizedBox(height: 20),
          const Text('AI 识别结果（可修改）', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _buildField('公司', _buildTextFiled(_companyCtrl, '公司名')),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildField('岗位', _buildTextFiled(_roleCtrl, '岗位名称')),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildField('轮次', _buildRoundSelector()),
          const SizedBox(height: 16),
          _buildField(_deadlineMode ? '截止时间 *' : '开始时间 *', _buildTimeSelector()),
          const SizedBox(height: 12),
          // 时间类型开关：测评/笔试常见「只有截止」的邮件，别让它伪装成面试场次
          if (_canToggleDeadlineMode) _buildDeadlineModeSwitch(),
          if (_showExtraDeadline) ...[
            const SizedBox(height: 16),
            _buildField('截止期限（可选）', _buildExtraDeadlineSelector()),
          ],
          const SizedBox(height: 16),
          _buildField('时长（分钟）', _buildTextFiled(_durationCtrl, '60', number: true)),
          const SizedBox(height: 16),
          _buildField('地点', _buildTextFiled(_locationCtrl, '线上/线下地址')),
          const SizedBox(height: 16),
          _buildField('会议链接', _buildTextFiled(_meetingUrlCtrl, 'https://...')),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _buildOriginalCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: AppTheme.outline, width: AppTheme.outlineWidth),
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        boxShadow: AppTheme.hardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('原文', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
          const SizedBox(height: 8),
          Text(widget.originalTitle, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          if (widget.originalMeta.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              widget.originalMeta,
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary.withValues(alpha: 0.85)),
            ),
          ],
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 280),
            child: SingleChildScrollView(
              child: SelectableText(
                widget.originalBody.trim().isEmpty ? '（没有可显示的正文）' : widget.originalBody,
                style: const TextStyle(fontSize: 13, height: 1.5),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildField(String label, Widget child) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
        const SizedBox(height: 6),
        child,
      ],
    );
  }

  Widget _buildTextFiled(TextEditingController ctrl, String hint, {bool number = false}) {
    return TextField(
      controller: ctrl,
      keyboardType: number ? TextInputType.number : TextInputType.text,
      decoration: _inputDecoration(hint),
    );
  }

  InputDecoration _inputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: AppTheme.textSecondary.withValues(alpha: 0.5), fontSize: 13),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
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

  Widget _buildRoundSelector() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: _rounds.map((round) {
        final selected = _round == round;
        return GestureDetector(
          onTap: () => setState(() => _round = selected ? '' : round),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: selected ? AppTheme.primary : AppTheme.primaryLight.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              round,
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

  Widget _buildTimeSelector() {
    return GestureDetector(
      onTap: _pickStartTime,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
          // 经典=原版浅蓝细边、无阴影，lowpoly=黑描边+硬阴影
          border: AppTheme.isLowpoly
              ? Border.all(color: AppTheme.outline, width: AppTheme.outlineWidth)
              : Border.all(color: AppTheme.primaryLight),
          boxShadow: AppTheme.isLowpoly ? AppTheme.hardShadow : null,
        ),
        child: Row(
          children: [
            Icon(
              _deadlineMode ? Icons.hourglass_bottom_rounded : Icons.access_time_rounded,
              size: 20,
              color: _deadlineMode ? AppTheme.warning : AppTheme.primary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                DateFormat('yyyy年M月d日 HH:mm').format(_startTime),
                style: const TextStyle(fontSize: 15, color: AppTheme.textPrimary),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeadlineModeSwitch() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: AppTheme.outline, width: AppTheme.outlineWidth),
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
      ),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              '这是截止时间（在此前完成即可，不是面试开始时间）',
              style: TextStyle(fontSize: 13, color: AppTheme.textPrimary),
            ),
          ),
          Switch(
            value: _deadlineMode,
            activeThumbColor: AppTheme.primary,
            onChanged: (v) => setState(() => _deadlineMode = v),
          ),
        ],
      ),
    );
  }

  Widget _buildExtraDeadlineSelector() {
    return Row(
      children: [
        Expanded(
          child: GestureDetector(
            onTap: _pickExtraDeadline,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: AppTheme.outline, width: AppTheme.outlineWidth),
                borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
              ),
              child: Row(
                children: [
                  const Icon(Icons.hourglass_bottom_rounded, size: 20, color: AppTheme.warning),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _extraDeadline == null
                          ? '未设置'
                          : DateFormat('yyyy年M月d日 HH:mm').format(_extraDeadline!),
                      style: TextStyle(
                        fontSize: 15,
                        color: _extraDeadline == null
                            ? AppTheme.textSecondary
                            : AppTheme.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_extraDeadline != null)
          IconButton(
            tooltip: '清除',
            icon: const Icon(Icons.clear_rounded, size: 18, color: AppTheme.textSecondary),
            onPressed: () => setState(() => _extraDeadline = null),
          ),
      ],
    );
  }
}
