import '../models/mail_message.dart';
import 'llm_service.dart';
import 'mail_config_store.dart';
import 'mail_cursor_store.dart';
import 'mail_service.dart';
import 'processed_mail_store.dart';
import 'profile_store.dart';

/// 解析任务的生命周期
enum ParseStatus { idle, running, paused, done }

/// 一条待确认的候选邮件 + AI 抽取结果。
/// [result] 可变：用户在编辑页改过之后会替换成新的抽取结果。
class MailCandidate {
  final MailMessage mail;
  ExtractionResult result;
  bool selected = true;

  MailCandidate(this.mail, this.result);
}

/// 邮件解析会话（单例）。
///
/// 同步/识别跑在这里、而不是页面的 State 里：
/// 退出邮箱导入页解析照常进行，回来重新挂上监听就能继续看进度和结果；
/// 结果保存在会话内存中，暂停、切换页面都不会丢。
/// （进程被系统杀掉才会丢 —— 那种情况游标没推进，下次同步会重新识别。）
class MailParseSession {
  MailParseSession._();
  static final MailParseSession instance = MailParseSession._();

  ParseStatus status = ParseStatus.idle;
  String progress = '';
  String? error;
  String? fetchSummary;
  MailCursor? cursor;
  List<MailCandidate> candidates = [];

  bool _cancelled = false;
  bool _paused = false;
  int? _newestUid;
  DateTime? _newestMailDate;
  bool _isRangeSync = false;

  final List<void Function()> _listeners = [];

  void addListener(void Function() fn) => _listeners.add(fn);

  void removeListener(void Function() fn) => _listeners.remove(fn);

  /// 状态/结果有变化时通知界面刷新
  void notify() {
    for (final fn in List.of(_listeners)) {
      fn();
    }
  }

  bool get isBusy => status == ParseStatus.running || status == ParseStatus.paused;

  /// 展示用：打开页面先确保游标已加载
  Future<void> ensureCursorLoaded() async {
    if (cursor != null) return;
    cursor = await MailCursorStore.load();
    notify();
  }

  /// 开始一次同步识别。配置/档案在会话里自己加载，校验失败直接写 [error]。
  Future<void> start({DateTime? rangeStart, DateTime? rangeEnd}) async {
    if (isBusy) return;

    final config = await MailConfigStore.loadActive();
    final profile = await ProfileStore.loadActive();
    if (config == null || !config.isConfigured) {
      error = '还没有可用的邮箱配置，先点「管理配置」新增一个';
      status = ParseStatus.done;
      notify();
      return;
    }
    if (profile == null || !profile.isConfigured) {
      error = '请先在「AI 助手 → 右上角设置」里配置 AI 档案（邮箱识别依赖 AI 抽取）';
      status = ParseStatus.done;
      notify();
      return;
    }

    _cancelled = false;
    _paused = false;
    _newestUid = null;
    candidates = [];
    error = null;
    fetchSummary = null;
    status = ParseStatus.running;
    progress = '正在连接邮箱…';
    notify();

    // 手动选了时间段 → 按日期范围拉；否则走游标增量
    _isRangeSync = rangeStart != null && rangeEnd != null;

    try {
      final MailFetchResult res;
      if (_isRangeSync) {
        res = await MailService.create().fetchMailsInRange(
          email: config.email,
          authCode: config.authCode,
          start: rangeStart!,
          end: rangeEnd!,
        );
      } else {
        // 增量：只拉上次游标之后的邮件，首次 sinceUid 为 null（拉最近 N 封）
        final c = await MailCursorStore.load();
        cursor = c;
        res = await MailService.create().fetchRecentMails(
          email: config.email,
          authCode: config.authCode,
          sinceUid: c.lastUid,
        );
      }
      final mails = res.mails;
      _newestUid = res.newestUid;
      _newestMailDate = _maxDate(mails);
      fetchSummary = _buildFetchSummary(mails);
      notify();

      // 只跳过「没有正文可读」的空邮件，其余全部交给 AI 通读全文判断。
      // 不再用关键词粗筛 —— 面试邀约不一定在主题里带关键词，误杀召回。
      final readable = mails.where((m) => m.textBody.trim().isNotEmpty).toList();
      final unprocessed = await ProcessedMailStore.filterUnprocessed(
        readable,
        (m) => m.uid,
      );

      if (unprocessed.isEmpty) {
        // 整批都没有待处理的邮件：同样视为「已消费」推进游标，
        // 否则下次会重复拉同一窗口。没拉到新邮件时游标保持不动。
        await advanceCursor();
        status = ParseStatus.done;
        progress = '';
        error = '没有新的邮件（已处理的都已跳过）。';
        notify();
        return;
      }

      final service = LlmService(profile);
      final found = <MailCandidate>[];

      // 批量送 AI：每批 8 封，一次请求通读多封全文，快且不漏
      const batchSize = 8;
      var done = 0;
      while (done < unprocessed.length) {
        if (_cancelled) break;
        // 暂停检查点：当前批次完成后停在这里，点继续恢复
        await _waitWhilePaused();
        if (_cancelled) break;

        final batch = unprocessed.skip(done).take(batchSize).toList();
        progress = '正在识别 ${done + 1}–${done + batch.length} / ${unprocessed.length}…';
        notify();

        final results = await service.extractBatch(batch.map(mailText).toList());
        for (var i = 0; i < batch.length && i < results.length; i++) {
          final r = results[i];
          if (r.isInterview && r.startTime != null) {
            found.add(MailCandidate(batch[i], r));
          }
        }
        done += batch.length;

        // 每批完成就快照：中途退出页面，回来时已识别的部分已经能看
        candidates = List.of(found);
        notify();
      }

      // 整轮扫完、没被取消也没抛错，且没识别出候选 → 游标推进到本次最新
      if (!_cancelled && found.isEmpty) {
        await advanceCursor();
      }

      status = ParseStatus.done;
      progress = '';
      if (!_cancelled && found.isEmpty) {
        error = '这些邮件里没识别出面试邀约（可能是通知、拒信或无关邮件）。';
      }
      notify();
    } catch (e) {
      status = ParseStatus.done;
      progress = '';
      // 用户主动停止不算错误，不弹提示
      if (!_cancelled) error = '同步失败：$e';
      notify();
    }
  }

  Future<void> _waitWhilePaused() async {
    while (_paused && !_cancelled) {
      await Future.delayed(const Duration(milliseconds: 300));
    }
  }

  /// 暂停（当前正在发的那批请求发完后停住）
  void pause() {
    if (status != ParseStatus.running) return;
    _paused = true;
    status = ParseStatus.paused;
    progress = '已暂停，点「继续」恢复';
    notify();
  }

  /// 从暂停处继续
  void resume() {
    if (status != ParseStatus.paused) return;
    _paused = false;
    status = ParseStatus.running;
    progress = '正在识别…';
    notify();
  }

  /// 停止：已识别的候选保留，未识别的不再继续
  void cancel() {
    if (!isBusy) return;
    _paused = false;
    _cancelled = true;
    notify();
  }

  /// 推进同步游标。只在确实拉到了新邮件（_newestUid 非空）时才推进；
  /// 手动选时间段识别不影响自动同步的游标（那是一次性的历史回扫）。
  Future<void> advanceCursor() async {
    if (_isRangeSync) return;
    final uid = _newestUid;
    if (uid == null) return;
    await MailCursorStore.save(uid, newestMailDate: _newestMailDate);
    cursor = MailCursor(
      lastUid: uid,
      newestMailDate: _newestMailDate,
      syncedAt: DateTime.now(),
    );
    notify();
  }

  /// 拼一封邮件的全文给 AI（正文超长则截断，防止单封拖垮整批）
  String mailText(MailMessage m) {
    const maxBody = 2000;
    var body = m.textBody.trim();
    if (body.length > maxBody) {
      body = '${body.substring(0, maxBody)}…（正文过长已截断）';
    }
    return '邮件主题：${m.subject}\n发件人：${m.from}\n\n$body';
  }

  DateTime? _maxDate(List<MailMessage> mails) {
    DateTime? max;
    for (final m in mails) {
      final d = m.date;
      if (d != null && (max == null || d.isAfter(max))) max = d;
    }
    return max;
  }

  /// 「本次拉取 N 封（2026-08-15 ~ 2026-09-19）」这样的人话摘要
  String? _buildFetchSummary(List<MailMessage> mails) {
    if (mails.isEmpty) return null;
    final dates = mails.map((m) => m.date).whereType<DateTime>().toList();
    if (dates.isEmpty) return '本次拉取 ${mails.length} 封';
    dates.sort();
    final oldest = dates.first;
    final newest = dates.last;
    if (oldest == newest) return '本次拉取 ${mails.length} 封（${_fmtYmd(oldest)}）';
    return '本次拉取 ${mails.length} 封（${_fmtYmd(oldest)} ~ ${_fmtYmd(newest)}）';
  }

  String _fmtYmd(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
