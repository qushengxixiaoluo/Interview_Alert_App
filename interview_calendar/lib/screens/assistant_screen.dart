import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart';
import '../models/event.dart';
import '../models/llm_profile.dart';
import '../services/database.dart';
import '../services/llm_service.dart';
import '../services/profile_store.dart';
import '../services/conflict_detector.dart';
import '../theme/app_theme.dart';
import 'event_form_screen.dart';
import 'settings_screen.dart';

/// AI 助手页面：粘贴文本 → 自动抽取 → 写入日历
class AssistantScreen extends StatefulWidget {
  const AssistantScreen({super.key});

  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen> {
  final _textCtrl = TextEditingController();
  final _db = DatabaseService.instance;
  final _speech = SpeechToText();
  LlmProfile? _profile;
  ExtractionResult? _result;
  ConflictCheck? _conflict;
  bool _loading = false;
  bool _saving = false;
  bool _speechAvailable = false;
  bool _listening = false;
  String? _error;
  String? _storageWarning;
  DateTime? _savedDate;

  /// 听写过程中的实时识别文字。只显示在「正在听」小窗里，
  /// 听写结束后一次性写入输入框 —— 边听边改输入框会把整个页面顶出屏幕。
  String _liveTranscript = '';

  /// 识别结果卡片的定位 key：分析完自动滚过去，防止结果生成在屏幕外看不见
  final _resultKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _loadConfig();
    _initSpeech();
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    _speech.stop();
    super.dispose();
  }

  /// 初始化本机语音识别（安卓调系统 SpeechRecognizer，不走云端）。
  /// 失败不挡界面：麦克风按钮永远可点，点的时候会再试一次（会重新弹录音权限框）。
  Future<bool> _initSpeech() async {
    try {
      final ok = await _speech.initialize(
        onStatus: (status) {
          // 说完停顿 / 服务结束时收尾：把听到的文字一次性写进输入框
          if (status == 'done' || status == 'notListening') _finishListening();
        },
        onError: (_) => _finishListening(),
      );
      if (mounted) setState(() => _speechAvailable = ok);
      return ok;
    } catch (_) {
      if (mounted) setState(() => _speechAvailable = false);
      return false;
    }
  }

  /// 听写结束（说完停顿 / 手动停止 / 出错都走这里）。
  /// 幂等：重复调用不会重复写入。
  void _finishListening() {
    if (!mounted) return;
    final heard = _liveTranscript.trim();
    setState(() {
      _listening = false;
      _liveTranscript = '';
      if (heard.isNotEmpty) {
        final base = _textCtrl.text.trim().isEmpty ? '' : '${_textCtrl.text.trim()}\n';
        _textCtrl.text = '$base$heard';
        _textCtrl.selection = TextSelection.collapsed(offset: _textCtrl.text.length);
      }
    });
  }

  /// 开始/停止听写。
  Future<void> _toggleListening() async {
    if (_listening) {
      await _speech.stop();
      _finishListening();
      return;
    }
    // 不可用就再初始化一次 —— 首次的录音权限框可能被拒或没弹出来，
    // 重试会重新弹权限框，批了就能用。
    var available = _speechAvailable;
    if (!available) {
      available = await _initSpeech();
    }
    if (!available) {
      setState(() {
        _error = '语音输入暂不可用。安卓请在「设置 → 应用 → 事件日历 → 权限」里允许麦克风/录音，'
            '然后回来再点一次麦克风。';
      });
      return;
    }

    setState(() {
      _listening = true;
      _liveTranscript = '';
      _error = null;
    });
    try {
      await _speech.listen(
        onResult: (result) {
          if (!mounted) return;
          // 听写过程中只更新「正在听」小窗，不碰输入框，防止内容被顶出屏幕
          setState(() => _liveTranscript = result.recognizedWords);
        },
        listenOptions: SpeechListenOptions(
          listenFor: const Duration(seconds: 60),
          pauseFor: const Duration(seconds: 3),
          localeId: 'zh_CN',
          partialResults: true,
          listenMode: ListenMode.dictation,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _listening = false;
        _error = '语音识别启动失败：$e';
      });
    }
  }

  Future<void> _loadConfig() async {
    try {
      final profile = await ProfileStore.loadActive();
      if (mounted) {
        setState(() {
          _profile = profile;
          _storageWarning = ProfileStore.isPersistent ? null : ProfileStore.lastError;
        });
      }
    } catch (e) {
      // ProfileStore 内部已经做了兜底，正常不会走到这里；留个提示以便排查
      if (mounted) setState(() => _error = '读取配置出错：$e');
    }
  }

  Future<void> _analyze() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) {
      setState(() => _error = '请输入或粘贴文本');
      return;
    }
    if (_profile == null || !_profile!.isConfigured) {
      setState(() => _error = '请先在右上角设置里选择或配置一个 AI 档案');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
      _result = null;
      _conflict = null;
    });

    final service = LlmService(_profile!);
    final result = await service.extractFromText(text);

    if (result.hasError) {
      setState(() { _loading = false; _error = result.error; });
      return;
    }

    ConflictCheck? conflict;
    if (result.startTime != null) {
      final endTime = result.startTime!.add(Duration(minutes: result.durationMinutes));
      conflict = await ConflictDetector(_db).check(
        newStart: result.startTime!,
        newEnd: endTime,
      );
    }

    setState(() {
      _result = result;
      _conflict = conflict;
      _loading = false;
    });

    // 结果卡片在输入区下方，长输入时会生成在屏幕外 —— 自动滚过去给用户看
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _resultKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _confirmAndSave() async {
    if (_result == null || _result!.startTime == null || _saving) return;
    setState(() => _saving = true);

    try {
      final event = _buildEvent();
      await _db.insertEvent(event);

      if (mounted) {
        _savedDate = event.startTime;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已写入日历：${event.title}'),
            backgroundColor: AppTheme.success,
            duration: const Duration(seconds: 3),
            action: SnackBarAction(
              label: '查看',
              textColor: Colors.white,
              onPressed: () {
                // 先收起这个 SnackBar，再带着事件日期返回首页，
                // 避免残留的 SnackBar 在返回后还带着一个失效的「查看」按钮
                ScaffoldMessenger.of(context).hideCurrentSnackBar();
                Navigator.pop(context, _savedDate);
              },
            ),
          ),
        );
        setState(() {
          _result = null;
          _conflict = null;
          _textCtrl.clear();
          _saving = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() { _error = '保存失败: $e'; _saving = false; });
      }
    }
  }

  Future<void> _editBeforeSave() async {
    if (_result == null || _result!.startTime == null || _saving) return;
    setState(() => _saving = true);

    try {
      final savedDate = await Navigator.push<DateTime>(
        context,
        MaterialPageRoute(
          builder: (_) => EventFormScreen(
            initialDate: _result!.startTime!,
            existingEvent: _buildEvent(),
          ),
        ),
      );
      if (mounted) {
        setState(() => _saving = false);
        if (savedDate != null) {
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
          Navigator.pop(context, savedDate);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() { _error = '跳转失败: $e'; _saving = false; });
      }
    }
  }

  InterviewEvent _buildEvent() {
    return InterviewEvent(
      title: _result!.title.isNotEmpty ? _result!.title : '面试',
      company: _result!.company.isNotEmpty ? _result!.company : null,
      role: _result!.role.isNotEmpty ? _result!.role : null,
      round: _roundFromString(_result!.round),
      startTime: _result!.startTime!,
      endTime: _result!.startTime!.add(Duration(minutes: _result!.durationMinutes)),
      location: _result!.location.isNotEmpty ? _result!.location : null,
      meetingUrl: _result!.meetingUrl.isNotEmpty ? _result!.meetingUrl : null,
      notes: [
        if (_result!.contact.isNotEmpty) '联系人：${_result!.contact}',
        if (_result!.summary.isNotEmpty) _result!.summary,
        if (_result!.needsReview) '⚠ 待核对：${_result!.timeIsExplicit ? '置信度偏低' : '时间是推算的，请核对'}',
      ].join('\n'),
      color: EventColor.blue,
    );
  }

  InterviewRound? _roundFromString(String round) {
    const map = {
      '一面': InterviewRound.first,
      '二面': InterviewRound.second,
      '终面': InterviewRound.finalRound,
      'HR面': InterviewRound.hr,
      '笔试': InterviewRound.written,
      '测评': InterviewRound.assessment,
    };
    return map[round];
  }

  @override
  Widget build(BuildContext context) {
    final noConfig = _profile == null || !_profile!.isConfigured;

    return Scaffold(
      appBar: AppBar(
        title: const Text('AI 助手'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () async {
              final changed = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => const SettingsScreen()));
              if (changed == true) _loadConfig();
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (noConfig) _buildWarningCard('请先在右上角设置里选择或配置一个 AI 档案'),

          // 存储不可用时的提示（配置能用，但关掉 App 后会丢）
          if (_storageWarning != null)
            _buildWarningCard('配置无法保存到本机，关掉 App 后会丢失。原因：$_storageWarning'),

          // 输入区域
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: AppTheme.outline, width: AppTheme.outlineWidth),
              borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
              boxShadow: AppTheme.hardShadow,
            ),
            child: Column(
              children: [
                TextField(
                  controller: _textCtrl,
                  maxLines: 8,
                  minLines: 4,
                  decoration: InputDecoration(
                    hintText: '粘贴邮件内容、面试通知、聊天记录...\n\n支持任何格式的文字，AI 会自动提取面试信息',
                    hintStyle: TextStyle(color: AppTheme.textSecondary.withValues(alpha: 0.5)),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.all(16),
                  ),
                ),
                // 听写中的实时文字小窗：只显示在这里，结束后才写进上面的输入框
                if (_listening)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: AppTheme.badge.withValues(alpha: 0.06),
                      // 经典=原版只有顶部一条浅蓝分隔线，lowpoly=整圈黑描边
                      border: AppTheme.isLowpoly
                          ? Border.all(color: AppTheme.outline, width: AppTheme.outlineWidth)
                          : Border(top: BorderSide(color: AppTheme.primaryLight.withValues(alpha: 0.3))),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.graphic_eq, size: 16, color: AppTheme.badge),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _liveTranscript.isEmpty ? '正在听…请说话' : _liveTranscript,
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.4,
                              color: _liveTranscript.isEmpty
                                  ? AppTheme.textSecondary.withValues(alpha: 0.7)
                                  : AppTheme.textPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: AppTheme.primaryLight.withValues(alpha: 0.3))),
                  ),
                  child: Row(
                    children: [
                      Text(
                        _listening ? '正在听…说完停顿自动结束' : '${_textCtrl.text.length} 字',
                        style: TextStyle(
                          fontSize: 12,
                          color: _listening ? AppTheme.badge : AppTheme.textSecondary.withValues(alpha: 0.5),
                        ),
                      ),
                      const Spacer(),
                      // 语音输入：听写进输入框（本机系统语音识别）。
                      // 永远可点 —— 不可用时点了会自动重试初始化并给出提示，不做死按钮。
                      IconButton(
                        onPressed: _toggleListening,
                        tooltip: _listening ? '停止听写' : '语音输入',
                        icon: Icon(
                          _listening ? Icons.mic : Icons.mic_none,
                          size: 22,
                          color: _listening ? AppTheme.badge : AppTheme.primary,
                        ),
                      ),
                      if (_textCtrl.text.isNotEmpty)
                        TextButton(onPressed: () => setState(() => _textCtrl.clear()), child: const Text('清空', style: TextStyle(fontSize: 13))),
                      ElevatedButton.icon(
                        onPressed: (noConfig || _loading) ? null : _analyze,
                        icon: _loading
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.auto_awesome, size: 18),
                        label: Text(_loading ? '分析中...' : '智能提取'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          if (_error != null) ...[const SizedBox(height: 16), _buildErrorCard(_error!)],
          if (_result != null && !_result!.hasError) ...[
            const SizedBox(height: 20),
            KeyedSubtree(key: _resultKey, child: _buildResultCard()),
          ],
          if (_conflict != null && _conflict!.hasConflict) ...[const SizedBox(height: 12), _buildConflictCard()],
        ],
      ),
    );
  }

  Widget _buildResultCard() {
    final r = _result!;
    final categoryLabel = {
      'interview_invite': '📩 面试邀约',
      'reschedule': '🔄 改期通知',
      'cancel': '❌ 取消通知',
      'assessment': '📝 笔试/测评',
      'rejection': '😔 拒信',
      'offer': '🎉 Offer',
      'other': '📄 其他',
    }[r.category] ?? '📄 其他';

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        // 经典=原版按类别着色的细边，lowpoly=统一黑描边
        border: AppTheme.isLowpoly
            ? Border.all(color: AppTheme.outline, width: AppTheme.outlineWidth)
            : Border.all(
                color: r.isInterview ? AppTheme.primary : AppTheme.warning,
                width: 1.5,
              ),
        boxShadow: AppTheme.hardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(categoryLabel, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: (r.confidence >= 0.75 ? AppTheme.success : AppTheme.warning).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${(r.confidence * 100).round()}%',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: r.confidence >= 0.75 ? AppTheme.success : AppTheme.warning),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (r.company.isNotEmpty) _resultRow('公司', r.company),
          if (r.role.isNotEmpty) _resultRow('岗位', r.role),
          if (r.round.isNotEmpty) _resultRow('轮次', r.round),
          if (r.startTime != null) _resultRow('时间', _formatDateTime(r.startTime!)),
          if (!r.timeIsExplicit) _resultRow('⚠ 时间', '推算值，请核对'),
          _resultRow('时长', '${r.durationMinutes} 分钟'),
          if (r.location.isNotEmpty) _resultRow('地点', r.location),
          if (r.meetingUrl.isNotEmpty) _resultRow('链接', r.meetingUrl),
          if (r.contact.isNotEmpty) _resultRow('联系人', r.contact),
          if (r.summary.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(r.summary, style: TextStyle(fontSize: 13, color: AppTheme.textSecondary.withValues(alpha: 0.8))),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _saving ? null : _editBeforeSave,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.primary,
                    side: BorderSide(color: AppTheme.buttonOutline, width: AppTheme.outlineWidth),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppTheme.radiusMedium)),
                  ),
                  child: _saving
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('编辑后保存'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: _saving ? null : _confirmAndSave,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppTheme.radiusMedium)),
                  ),
                  child: _saving
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('直接保存'),
                ),
              ),
            ],
          ),
          if (r.needsReview) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: AppTheme.warning.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, size: 16, color: AppTheme.warning),
                  const SizedBox(width: 6),
                  Expanded(child: Text('建议点「编辑后保存」核对一下', style: TextStyle(fontSize: 12, color: AppTheme.warning.withValues(alpha: 0.9)))),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _resultRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 70, child: Text(label, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500))),
        ],
      ),
    );
  }

  Widget _buildConflictCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.badge.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        // 经典=原版红细边、无阴影，lowpoly=黑描边+硬阴影
        border: AppTheme.isLowpoly
            ? Border.all(color: AppTheme.outline, width: AppTheme.outlineWidth)
            : Border.all(color: AppTheme.badge.withValues(alpha: 0.3)),
        boxShadow: AppTheme.isLowpoly ? AppTheme.hardShadow : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: AppTheme.badge, size: 18),
              SizedBox(width: 6),
              Text('时间冲突', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.badge)),
            ],
          ),
          const SizedBox(height: 6),
          Text(_conflict!.message, style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
          const SizedBox(height: 6),
          Text('仍可保存，但建议调整时间', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary.withValues(alpha: 0.7))),
        ],
      ),
    );
  }

  Widget _buildWarningCard(String text) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: AppTheme.warning.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(AppTheme.radiusMedium)),
      child: Row(
        children: [
          const Icon(Icons.settings_outlined, color: AppTheme.warning, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary))),
        ],
      ),
    );
  }

  Widget _buildErrorCard(String text) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: AppTheme.badge.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(AppTheme.radiusMedium)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, color: AppTheme.badge, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }

  String _formatDateTime(DateTime dt) {
    final weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return '${dt.month}月${dt.day}日 ${weekdays[dt.weekday - 1]} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
