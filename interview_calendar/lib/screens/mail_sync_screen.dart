import 'package:flutter/material.dart';
import '../services/database.dart';
import '../services/mail_config_store.dart';
import '../services/mail_cursor_store.dart';
import '../services/processed_mail_store.dart';
import '../services/llm_service.dart';
import '../services/mail_parse_session.dart';
import '../services/extraction_to_event.dart';
import '../services/event_dedup.dart';
import '../theme/app_theme.dart';
import 'candidate_editor.dart';
import 'mail_config_screen.dart';

/// QQ 邮箱导入：同步并识别 → 待确认清单 → 批量加入日历。
/// 解析跑在 [MailParseSession] 单例里，退出本页不中断，回来接着看。
class MailSyncScreen extends StatefulWidget {
  const MailSyncScreen({super.key});

  @override
  State<MailSyncScreen> createState() => _MailSyncScreenState();
}

class _MailSyncScreenState extends State<MailSyncScreen> {
  final _db = DatabaseService.instance;
  final _session = MailParseSession.instance;

  MailConfig? _config;
  bool _loading = true;
  bool _saving = false;

  // 以下都是 MailParseSession 的本地镜像，监听回调里刷新。
  // 解析本体跑在会话里，退出页面时摘掉监听即可，任务不中断。
  bool _syncing = false;
  bool _paused = false;
  MailCursor? _cursor;
  String? _fetchSummary;
  String _progress = '';
  String? _error;
  List<MailCandidate> _candidates = [];

  // 手动选时间段识别：两者都非空才生效
  DateTime? _rangeStart;
  DateTime? _rangeEnd;

  @override
  void initState() {
    super.initState();
    _session.addListener(_onSessionChanged);
    _load();
  }

  @override
  void dispose() {
    _session.removeListener(_onSessionChanged);
    super.dispose();
  }

  /// 会话状态 → 本地镜像
  void _onSessionChanged() {
    if (!mounted) return;
    setState(() {
      _syncing = _session.isBusy;
      _paused = _session.status == ParseStatus.paused;
      _cursor = _session.cursor;
      _fetchSummary = _session.fetchSummary;
      _progress = _session.progress;
      _error = _session.error;
      _candidates = _session.candidates;
    });
  }

  Future<void> _load() async {
    final config = await MailConfigStore.loadActive();
    await _session.ensureCursorLoaded();
    if (!mounted) return;
    setState(() {
      _config = config;
      _loading = false;
    });
    // 同步一次会话现状（比如上一轮的候选还挂在会话里）
    _onSessionChanged();
  }

  Future<void> _sync() async {
    await _session.start(rangeStart: _rangeStart, rangeEnd: _rangeEnd);
  }

  String _formatTimestamp(DateTime dt) {
    final weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return '${dt.year}年${dt.month}月${dt.day}日 星期${weekdays[dt.weekday - 1]} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _addSelected() async {
    final selected = _candidates.where((c) => c.selected).toList();
    if (selected.isEmpty || _saving) return;
    setState(() => _saving = true);

    try {
      final existing = await _db.getAllEvents();
      DateTime? latestDate;
      var added = 0;
      var overwritten = 0;
      var skipped = 0;
      final handledUids = <String>[];

      for (final c in selected) {
        final event = eventFromExtraction(
          c.result,
          sourceNote: '来源邮件：${c.mail.displaySubject}（${c.mail.displayFrom}）',
        );
        final dup = findDuplicateEvent(event, existing);

        if (dup == null) {
          await _db.insertEvent(event);
          existing.add(event);
          added++;
          handledUids.add(c.mail.uid);
          if (latestDate == null || event.startTime.isAfter(latestDate)) {
            latestDate = event.startTime;
          }
          continue;
        }

        // 命中重复 → 弹窗问用户
        if (!mounted) return;
        final action = await showDuplicateDialog(
          context,
          event: event,
          dup: dup,
          overwriteHint: '新邮件里的信息',
        );
        if (!mounted) return;
        switch (action) {
          case DupAction.overwrite:
            final idx = existing.indexOf(dup);
            await _db.updateEvent(event.copyWith(id: dup.id));
            if (idx >= 0) existing[idx] = event.copyWith(id: dup.id);
            overwritten++;
            handledUids.add(c.mail.uid);
            if (latestDate == null || event.startTime.isAfter(latestDate)) {
              latestDate = event.startTime;
            }
            break;
          case DupAction.skip:
            skipped++;
            handledUids.add(c.mail.uid);
            break;
          case DupAction.cancel:
          case null:
            // 中止整个加入：已处理的照记，未处理的不动
            await ProcessedMailStore.markProcessed(handledUids);
            if (!mounted) return;
            setState(() {
              _saving = false;
              _candidates.removeWhere((x) => handledUids.contains(x.mail.uid));
            });
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('已取消，剩余邮件未处理'), backgroundColor: AppTheme.warning),
            );
            return;
        }
      }

      await ProcessedMailStore.markProcessed(handledUids);
      // 全部候选都已处理完才推进游标；部分勾选时保留未处理的，下次仍会显示
      if (selected.length == _candidates.length) {
        await _session.advanceCursor();
      }
      if (!mounted) return;

      final parts = <String>[
        if (added > 0) '加入 $added',
        if (overwritten > 0) '覆盖 $overwritten',
        if (skipped > 0) '跳过 $skipped',
      ];
      final msg = parts.isEmpty ? '没有可加入的事件' : '已${parts.join('、')}';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: AppTheme.success),
      );
      Navigator.pop(context, latestDate);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '保存失败：$e';
      });
    }
  }

  Future<void> _ignoreSelected() async {
    final selected = _candidates.where((c) => c.selected).toList();
    if (selected.isEmpty || _saving) return;
    setState(() => _saving = true);
    try {
      await ProcessedMailStore.markProcessed(selected.map((c) => c.mail.uid));
      if (!mounted) return;
      setState(() {
        _candidates.removeWhere((c) => selected.contains(c));
        _saving = false;
      });
      // 清单已空 → 游标推进到本次最新
      if (_candidates.isEmpty) {
        await _session.advanceCursor();
      }
      _show('已忽略 ${selected.length} 封，下次不再提示');
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _show('忽略失败：$e', isError: true);
    }
  }

  void _toggleAll(bool value) {
    setState(() {
      for (final c in _candidates) {
        c.selected = value;
      }
    });
  }

  /// 范围卡片用的日期展示
  String _fmtYmd(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  void _show(String msg, {bool isError = false}) {
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
        title: const Text('邮箱导入'),
        actions: [
          if (_syncing) ...[
            // 暂停/继续：当前批次发完后生效，已识别的结果保留
            TextButton.icon(
              onPressed: _paused ? _session.resume : _session.pause,
              icon: Icon(
                _paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                size: 18,
              ),
              label: Text(_paused ? '继续' : '暂停'),
              style: TextButton.styleFrom(foregroundColor: AppTheme.primary),
            ),
            TextButton.icon(
              onPressed: _session.cancel,
              icon: const Icon(Icons.stop_circle_outlined, size: 18),
              label: const Text('停止'),
              style: TextButton.styleFrom(foregroundColor: AppTheme.badge),
            ),
          ] else
            IconButton(
              icon: const Icon(Icons.refresh_rounded),
              tooltip: '重新同步',
              onPressed: _sync,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppTheme.primary))
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                _buildConfigCard(),
                const SizedBox(height: 12),
                _buildRangeCard(),
                const SizedBox(height: 16),
                _buildSyncButton(),
                const SizedBox(height: 12),
                _buildStatusCard(),
                if (_progress.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _buildProgressCard(),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  _buildErrorCard(),
                ],
                if (_candidates.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  _buildCandidateSection(),
                ],
                const SizedBox(height: 32),
              ],
            ),
    );
  }

  /// 当前账号卡片：展示同步会用哪份配置，管理入口跳到专门的配置页
  Widget _buildConfigCard() {
    final config = _config;
    return Container(
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
              const Icon(Icons.mail_outline, size: 18, color: AppTheme.primary),
              const SizedBox(width: 8),
              const Text('QQ 邮箱', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              const Spacer(),
              _buildConfigBadge(),
            ],
          ),
          const SizedBox(height: 10),
          if (config == null)
            Text(
              '还没有邮箱配置。点「管理配置」新增一个 QQ 邮箱账号。',
              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary.withValues(alpha: 0.9), height: 1.5),
            )
          else ...[
            Text(
              config.displayName,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 3),
            Text(
              config.email,
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary.withValues(alpha: 0.85)),
            ),
            // 存储不可用时的常驻警告：不让「保存了却没存住」变成静默失败
            if (!MailConfigStore.isPersistent && (MailConfigStore.lastError ?? '').isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.warning_amber_rounded, size: 15, color: AppTheme.badge),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '配置未能保存到本机，重启后需要重填：${MailConfigStore.lastError}',
                      style: const TextStyle(fontSize: 11, color: AppTheme.badge, height: 1.4),
                    ),
                  ),
                ],
              ),
            ],
          ],
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _openMailConfig,
              icon: const Icon(Icons.settings_outlined, size: 18),
              label: Text(config == null ? '管理配置（新增）' : '管理配置'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.primary,
                side: BorderSide(color: AppTheme.buttonOutline, width: AppTheme.outlineWidth),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppTheme.radiusMedium)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 打开专门的邮箱配置管理页，回来后刷新「使用中」的账号
  Future<void> _openMailConfig() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const MailConfigScreen()),
    );
    if (!mounted) return;
    final config = await MailConfigStore.loadActive();
    if (!mounted) return;
    setState(() => _config = config);
  }

  /// 配置卡右上角的常驻状态：邮箱 + 授权码齐全才算「已配置」，一眼看出可不可以同步
  Widget _buildConfigBadge() {
    final ready = _config != null && _config!.isConfigured;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: (ready ? AppTheme.success : AppTheme.textSecondary).withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        ready ? '✓ 已配置' : '未配置',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: ready ? AppTheme.success : AppTheme.textSecondary,
        ),
      ),
    );
  }

  /// 手动选时间段识别：选了两端就按范围拉，否则按 UID 游标增量。
  Widget _buildRangeCard() {
    final hasRange = _rangeStart != null && _rangeEnd != null;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
              const Icon(Icons.date_range, size: 15, color: AppTheme.textSecondary),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('识别范围（可选，不选则自动增量）',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
              ),
              if (hasRange)
                TextButton(onPressed: _clearRange, child: const Text('清除', style: TextStyle(fontSize: 12))),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _pickRangeStart,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: Text(
                    _rangeStart == null ? '起始日期' : _fmtYmd(_rangeStart!),
                    style: TextStyle(fontSize: 13, color: _rangeStart == null ? AppTheme.textSecondary : AppTheme.textPrimary),
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6),
                child: Text('—', style: TextStyle(color: AppTheme.textSecondary)),
              ),
              Expanded(
                child: OutlinedButton(
                  onPressed: _pickRangeEnd,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: Text(
                    _rangeEnd == null ? '结束日期' : _fmtYmd(_rangeEnd!),
                    style: TextStyle(fontSize: 13, color: _rangeEnd == null ? AppTheme.textSecondary : AppTheme.textPrimary),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _pickRangeStart() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _rangeStart ?? DateTime.now().subtract(const Duration(days: 30)),
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _rangeStart = DateTime(picked.year, picked.month, picked.day);
      if (_rangeEnd != null && _rangeStart!.isAfter(_rangeEnd!)) {
        _rangeEnd = _rangeStart;
      }
    });
  }

  Future<void> _pickRangeEnd() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _rangeEnd ?? _rangeStart ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _rangeEnd = DateTime(picked.year, picked.month, picked.day);
      if (_rangeStart != null && _rangeEnd!.isBefore(_rangeStart!)) {
        _rangeStart = _rangeEnd;
      }
    });
  }

  void _clearRange() {
    setState(() {
      _rangeStart = null;
      _rangeEnd = null;
    });
  }

  /// 打开候选编辑器，用户看邮件原文 + 改值后，用返回的新结果覆盖当前候选。
  Future<void> _editCandidate(MailCandidate c) async {
    final date = c.mail.date;
    final meta = date == null
        ? c.mail.displayFrom
        : '${c.mail.displayFrom} · ${_formatTimestamp(date)}';
    final updated = await Navigator.push<ExtractionResult>(
      context,
      MaterialPageRoute(
        builder: (_) => CandidateEditorScreen(
          originalTitle: c.mail.displaySubject,
          originalMeta: meta,
          originalBody: c.mail.textBody,
          initial: c.result,
        ),
      ),
    );
    if (updated == null || !mounted) return;
    setState(() => c.result = updated);
  }

  Widget _buildSyncButton() {
    // AI 档案的校验在会话里做（缺档案时会给出错误卡片），这里只看邮箱配置
    final ready = _config?.isConfigured == true;
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: (_syncing || _saving) ? null : (ready ? _sync : null),
        icon: _syncing
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : const Icon(Icons.sync_rounded),
        label: Text(_syncing ? '同步中…' : '同步并识别'),
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppTheme.radiusMedium)),
        ),
      ),
    );
  }

  /// 同步进度点的可视化：上次同步到哪、本次拉了多少、覆盖哪个日期范围。
  Widget _buildStatusCard() {
    final cursor = _cursor;
    final summary = _fetchSummary;
    final hasSynced = cursor != null && cursor.hasSynced;

    String statusLine;
    final t = cursor?.displayTime;
    if (hasSynced) {
      statusLine = t != null ? '上次已同步到 ${_formatTimestamp(t)}' : '上次已同步（时间未知）';
    } else {
      statusLine = '尚未同步过：点「同步并识别」开始';
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(hasSynced ? Icons.history : Icons.schedule, size: 15, color: AppTheme.textSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  statusLine,
                  style: TextStyle(fontSize: 13, color: hasSynced ? AppTheme.textPrimary : AppTheme.textSecondary),
                ),
              ),
            ],
          ),
          if (summary != null) ...[
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.mark_email_unread_outlined, size: 15, color: AppTheme.textSecondary),
                const SizedBox(width: 8),
                Expanded(child: Text(summary, style: const TextStyle(fontSize: 13))),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildProgressCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.primaryLight.withValues(alpha: 0.12),
        border: Border.all(color: AppTheme.outline, width: AppTheme.outlineWidth),
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
      ),
      child: Row(
        children: [
          const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.primary)),
          const SizedBox(width: 12),
          Expanded(child: Text(_progress, style: const TextStyle(fontSize: 14))),
        ],
      ),
    );
  }

  Widget _buildErrorCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.badge.withValues(alpha: 0.08),
        border: Border.all(color: AppTheme.outline, width: AppTheme.outlineWidth),
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 18, color: AppTheme.badge),
          const SizedBox(width: 8),
          Expanded(child: Text(_error!, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }

  Widget _buildCandidateSection() {
    final selectedCount = _candidates.where((c) => c.selected).length;
    final allSelected = selectedCount == _candidates.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('识别出面试邮件', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: AppTheme.primary, borderRadius: BorderRadius.circular(10)),
              child: Text('${_candidates.length}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white)),
            ),
            const Spacer(),
            TextButton(
              onPressed: () => _toggleAll(!allSelected),
              child: Text(allSelected ? '全不选' : '全选', style: const TextStyle(fontSize: 13)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ..._candidates.map(_buildCandidateCard),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: (_saving || selectedCount == 0) ? null : _ignoreSelected,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.textSecondary,
                  side: BorderSide(color: AppTheme.buttonOutline, width: AppTheme.outlineWidth),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppTheme.radiusMedium)),
                ),
                child: const Text('忽略所选'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton(
                onPressed: (_saving || selectedCount == 0) ? null : _addSelected,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppTheme.radiusMedium)),
                ),
                child: _saving
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Text('加入所选 ($selectedCount)'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildCandidateCard(MailCandidate c) {
    final r = c.result;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        border: Border.all(
          color: c.selected ? AppTheme.primary : AppTheme.outline,
          width: c.selected ? 2.5 : 1.5,
        ),
        boxShadow: AppTheme.hardShadow,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        onTap: () => _editCandidate(c),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Checkbox(value: c.selected, onChanged: (v) => setState(() => c.selected = v ?? false)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(c.mail.displaySubject, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Text(c.mail.displayFrom, style: TextStyle(fontSize: 12, color: AppTheme.textSecondary.withValues(alpha: 0.8))),
                    const SizedBox(height: 8),
                    if (r.company.isNotEmpty) _row('公司', r.company),
                    if (r.startTime != null) _row('时间', _formatDateTime(r.startTime!)),
                    if (!r.timeIsExplicit) _row('⚠ 时间', '推算值，请核对'),
                    Row(
                      children: [
                        Text('置信度 ${(r.confidence * 100).round()}%',
                            style: TextStyle(fontSize: 11, color: r.confidence >= 0.75 ? AppTheme.success : AppTheme.warning)),
                        if (r.needsReview) ...[
                          const SizedBox(width: 8),
                          const Text('建议核对', style: TextStyle(fontSize: 11, color: AppTheme.warning)),
                        ],
                        const Spacer(),
                        Text('点按查看原文 / 修改',
                            style: TextStyle(fontSize: 11, color: AppTheme.primary.withValues(alpha: 0.85))),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 42, child: Text(label, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500))),
        ],
      ),
    );
  }

  String _formatDateTime(DateTime dt) {
    final weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return '${dt.month}月${dt.day}日 ${weekdays[dt.weekday - 1]} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
