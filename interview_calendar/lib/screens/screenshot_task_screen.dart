import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../services/database.dart';
import '../services/llm_service.dart';
import '../services/mail_parse_session.dart' show ParseStatus;
import '../services/screenshot_parse_session.dart';
import '../services/extraction_to_event.dart';
import '../services/event_dedup.dart';
import '../theme/app_theme.dart';
import 'candidate_editor.dart';

/// 截图识别任务：选截图 → AI 识别文字并总结任务 → 待确认清单 → 批量加入日历。
/// 和邮箱导入同一套「识别 → 确认 → 加入」流程，只是来源从邮件换成了截图。
/// 识别跑在 [ScreenshotParseSession] 单例里，退出本页不中断，回来接着看。
class ScreenshotTaskScreen extends StatefulWidget {
  const ScreenshotTaskScreen({super.key});

  @override
  State<ScreenshotTaskScreen> createState() => _ScreenshotTaskScreenState();
}

class _ScreenshotTaskScreenState extends State<ScreenshotTaskScreen> {
  final _db = DatabaseService.instance;
  final _picker = ImagePicker();
  final _session = ScreenshotParseSession.instance;

  bool _saving = false;

  // ScreenshotParseSession 的本地镜像，监听回调里刷新。
  bool _recognizing = false;
  bool _paused = false;
  List<PickedImage> _images = [];
  String _progress = '';
  String? _recognizedText;
  List<TaskCandidate> _tasks = [];
  String? _error;

  static const _maxImages = ScreenshotParseSession.maxImages;

  @override
  void initState() {
    super.initState();
    _session.addListener(_onSessionChanged);
    // 首次直接赋值（initState 里不能 setState）：
    // 把会话现状接过来，比如上一轮的图片/结果还挂在会话里
    _applySession();
  }

  @override
  void dispose() {
    _session.removeListener(_onSessionChanged);
    super.dispose();
  }

  /// 会话状态 → 本地镜像
  void _applySession() {
    _recognizing = _session.isBusy;
    _paused = _session.status == ParseStatus.paused;
    _images = _session.images;
    _progress = _session.progress;
    _recognizedText = _session.recognizedText;
    _tasks = _session.tasks;
    _error = _session.error;
  }

  void _onSessionChanged() {
    if (!mounted) return;
    setState(_applySession);
  }

  /// 从相册选截图（可多选，[append] 为 true 时追加到已有列表）。
  /// maxWidth/imageQuality 在安卓上顺手压一下图，免得原图太大把 base64 撑爆。
  Future<void> _pickImages({bool append = false}) async {
    try {
      final picked = await _picker.pickMultiImage(maxWidth: 1568, imageQuality: 85);
      if (picked.isEmpty || !mounted) return;

      final imgs = <PickedImage>[];
      for (final x in picked) {
        if (_images.length + imgs.length >= _maxImages) break;
        imgs.add(PickedImage(await x.readAsBytes(), _mimeFromPath(x.path, x.mimeType)));
      }
      if (!mounted) return;
      if (imgs.length < picked.length) {
        _show('最多支持 $_maxImages 张截图，多余的已忽略', isError: true);
      }
      // 图变了，旧的识别结果由会话统一作废并通知
      _session.setImages(append ? [..._images, ...imgs] : imgs);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '读取图片失败：$e');
    }
  }

  void _removeImage(int index) => _session.removeImageAt(index);

  String _mimeFromPath(String path, String? mime) {
    if (mime != null && mime.isNotEmpty) return mime;
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    return 'image/jpeg';
  }

  /// 送 AI：识别跑在会话里（每批 3 张并发），退出页面不中断
  Future<void> _recognize() => _session.start();

  /// 打开候选编辑器，用户看识别文字 + 改值后，用返回的新结果覆盖当前候选。
  Future<void> _editTask(TaskCandidate c) async {
    final updated = await Navigator.push<ExtractionResult>(
      context,
      MaterialPageRoute(
        builder: (_) => CandidateEditorScreen(
          originalTitle: '截图识别结果',
          originalBody: c.sourceText,
          initial: c.result,
        ),
      ),
    );
    if (updated == null || !mounted) return;
    setState(() => c.result = updated);
  }

  /// 加入日历。任务必须有时间才能入日历 —— 有缺的先拦下来让用户点开卡片设置。
  Future<void> _addSelected() async {
    final selected = _tasks.where((c) => c.selected).toList();
    if (selected.isEmpty || _saving) return;

    for (final c in selected) {
      if (c.result.startTime == null) {
        _show('「${c.result.title}」还没有时间，点开卡片设置后再加入', isError: true);
        return;
      }
    }

    setState(() => _saving = true);
    try {
      final existing = await _db.getAllEvents();
      DateTime? latestDate;
      var added = 0;
      var overwritten = 0;
      var skipped = 0;
      final handled = <TaskCandidate>[];

      for (final c in selected) {
        final event = eventFromExtraction(c.result, sourceNote: '来源：截图识别');
        final dup = findDuplicateEvent(event, existing);

        if (dup == null) {
          await _db.insertEvent(event);
          existing.add(event);
          added++;
          handled.add(c);
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
          overwriteHint: '新识别的信息',
        );
        if (!mounted) return;
        switch (action) {
          case DupAction.overwrite:
            final idx = existing.indexOf(dup);
            await _db.updateEvent(event.copyWith(id: dup.id));
            if (idx >= 0) existing[idx] = event.copyWith(id: dup.id);
            overwritten++;
            handled.add(c);
            if (latestDate == null || event.startTime.isAfter(latestDate)) {
              latestDate = event.startTime;
            }
            break;
          case DupAction.skip:
            skipped++;
            handled.add(c);
            break;
          case DupAction.cancel:
          case null:
            // 中止整个加入：已处理的照记（从清单移除），剩余的留在清单里
            setState(() {
              _saving = false;
              _tasks.removeWhere(handled.contains);
            });
            _show('已取消，剩余任务未加入', isError: true);
            return;
        }
      }

      if (!mounted) return;
      setState(() {
        _saving = false;
        _tasks.removeWhere((c) => c.selected);
      });

      final parts = <String>[
        if (added > 0) '加入 $added',
        if (overwritten > 0) '覆盖 $overwritten',
        if (skipped > 0) '跳过 $skipped',
      ];
      final msg = parts.isEmpty ? '没有可加入的任务' : '已${parts.join('、')}';
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

  void _ignoreSelected() {
    final count = _tasks.where((c) => c.selected).length;
    if (count == 0) return;
    setState(() => _tasks.removeWhere((c) => c.selected));
    _show('已忽略 $count 条');
  }

  void _toggleAll(bool value) {
    setState(() {
      for (final c in _tasks) {
        c.selected = value;
      }
    });
  }

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
      appBar: AppBar(title: const Text('截图识别任务')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _buildImageCard(),
          if (_recognizing) ...[
            const SizedBox(height: 16),
            _buildProgressCard(),
          ],
          if (_error != null) ...[
            const SizedBox(height: 16),
            _buildErrorCard(),
          ],
          if (_recognizedText != null) ...[
            const SizedBox(height: 16),
            _buildRecognizedCard(),
          ],
          if (_tasks.isNotEmpty) ...[
            const SizedBox(height: 20),
            _buildTaskSection(),
          ],
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildImageCard() {
    final images = _images;
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
              const Icon(Icons.image_search_outlined, size: 18, color: AppTheme.primary),
              const SizedBox(width: 8),
              const Text('截图识别', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              const Spacer(),
              if (images.isNotEmpty)
                Text('${images.length} / $_maxImages 张',
                    style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '上传面试通知、笔试安排、HR 聊天记录等截图（可多选，一次最多 $_maxImages 张），'
            'AI 识别文字并总结成任务，确认后加入日历。',
            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary.withValues(alpha: 0.85), height: 1.5),
          ),
          const SizedBox(height: 12),
          if (images.isEmpty)
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _pickImages(),
                icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
                label: const Text('选择截图（可多选）'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.primary,
                  side: BorderSide(color: AppTheme.buttonOutline, width: AppTheme.outlineWidth),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppTheme.radiusMedium)),
                ),
              ),
            )
          else ...[
            // 缩略图列表，角标可删
            SizedBox(
              height: 88,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: images.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (ctx, i) => Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.memory(images[i].bytes, width: 88, height: 88, fit: BoxFit.cover),
                    ),
                    Positioned(
                      top: 2,
                      right: 2,
                      child: GestureDetector(
                        onTap: _recognizing ? null : () => _removeImage(i),
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: const BoxDecoration(
                            color: Colors.black54,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.close, size: 12, color: Colors.white),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: (_recognizing || images.length >= _maxImages)
                        ? null
                        : () => _pickImages(append: true),
                    icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
                    label: const Text('继续添加'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.textSecondary,
                      side: BorderSide(color: AppTheme.buttonOutline, width: AppTheme.outlineWidth),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppTheme.radiusMedium)),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _recognizing ? null : _recognize,
                    icon: const Icon(Icons.auto_awesome, size: 18),
                    label: const Text('开始识别'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppTheme.radiusMedium)),
                    ),
                  ),
                ),
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
      child: Column(
        children: [
          Row(
            children: [
              const SizedBox(
                  width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.primary)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _progress.isEmpty ? '正在识别文字、总结任务…' : _progress,
                  style: const TextStyle(fontSize: 14),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _paused ? _session.resume : _session.pause,
                  icon: Icon(
                    _paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                    size: 16,
                  ),
                  label: Text(_paused ? '继续识别' : '暂停识别'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.primary,
                    side: BorderSide(
                        color: AppTheme.primary.withValues(alpha: 0.5)),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    textStyle: const TextStyle(fontSize: 13),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _session.cancel,
                  icon: const Icon(Icons.stop_circle_outlined, size: 16),
                  label: const Text('停止'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.badge,
                    side: BorderSide(color: AppTheme.buttonOutline, width: AppTheme.outlineWidth),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    textStyle: const TextStyle(fontSize: 13),
                  ),
                ),
              ),
            ],
          ),
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

  Widget _buildRecognizedCard() {
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
          const Text('识别到的文字', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 180),
            child: SingleChildScrollView(
              child: SelectableText(
                _recognizedText!.trim().isEmpty ? '（没有识别出文字）' : _recognizedText!,
                style: const TextStyle(fontSize: 13, height: 1.5),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTaskSection() {
    final selectedCount = _tasks.where((c) => c.selected).length;
    final allSelected = selectedCount == _tasks.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('总结出的任务', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: AppTheme.primary, borderRadius: BorderRadius.circular(10)),
              child: Text('${_tasks.length}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white)),
            ),
            const Spacer(),
            TextButton(
              onPressed: () => _toggleAll(!allSelected),
              child: Text(allSelected ? '全不选' : '全选', style: const TextStyle(fontSize: 13)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ..._tasks.map(_buildTaskCard),
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

  Widget _buildTaskCard(TaskCandidate c) {
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
        onTap: () => _editTask(c),
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
                    Text(r.title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    if (r.summary.isNotEmpty)
                      Text(r.summary, style: TextStyle(fontSize: 12, color: AppTheme.textSecondary.withValues(alpha: 0.85))),
                    const SizedBox(height: 8),
                    if (r.company.isNotEmpty) _row('公司', r.company),
                    if (r.role.isNotEmpty) _row('岗位', r.role),
                    if (r.round.isNotEmpty) _row('轮次', r.round),
                    if (r.startTime != null) _row('时间', _formatDateTime(r.startTime!)),
                    if (r.startTime == null)
                      _row('⚠ 时间', '未指定，点按设置'),
                    if (r.startTime != null && !r.timeIsExplicit) _row('⚠ 时间', '推算值，请核对'),
                    Row(
                      children: [
                        const Spacer(),
                        Text('点按修改', style: TextStyle(fontSize: 11, color: AppTheme.primary.withValues(alpha: 0.85))),
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
    return '${dt.month}月${dt.day}日 ${weekdays[dt.weekday - 1]} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
