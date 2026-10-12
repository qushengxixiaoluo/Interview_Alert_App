import '../models/event.dart';
import '../models/mail_message.dart';
import 'database.dart';
import 'extraction_to_event.dart';
import 'failed_mail_store.dart';
import 'llm_service.dart';
import 'mail_config_store.dart';
import 'mail_cursor_store.dart';
import 'mail_service.dart';
import 'processed_mail_store.dart';
import 'profile_store.dart';

/// 解析任务的生命周期
enum ParseStatus { idle, running, paused, done }

/// 拉取邮箱阶段的失败：带一段能直接照着排查的中文说明。
/// 和「AI 识别失败」分开，两者的排查方向完全不同。
class MailSyncException implements Exception {
  final String message;
  final LlmErrorKind kind;
  const MailSyncException(this.message, this.kind);

  @override
  String toString() => message;
}

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

  /// 本轮识别里 AI 请求失败的邮件数（>0 表示 AI 中途不可用了）
  int failedMailCount = 0;

  /// 本轮失败的邮件 uid。advanceCursor 拿它去 [FailedMailStore] 查
  /// 「还有没有没到放弃次数的」—— 没有才允许推游标（所有推进路径共用这道闸门）。
  final Set<String> _failedThisRun = {};

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
    failedMailCount = 0;
    _failedThisRun.clear();
    status = ParseStatus.running;
    progress = '正在连接邮箱…';
    notify();

    // 手动选了时间段 → 按日期范围拉；否则走游标增量
    _isRangeSync = rangeStart != null && rangeEnd != null;

    try {
      final MailFetchResult res;
      try {
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
      } catch (e) {
        // 拉邮件失败 → 人话提示（授权码错 / 网络不通 / 服务端断开），别把原始异常丢给用户
        throw MailSyncException(_friendlyFetchError(e), LlmErrorKind.network);
      }

      final mails = res.mails;
      _newestUid = res.newestUid;
      _newestMailDate = _maxDate(mails);
      fetchSummary = _buildFetchSummary(mails);
      notify();

      // 只跳过「没有正文可读」的空邮件，其余全部交给 AI 通读全文判断。
      // 不再用关键词粗筛 —— 面试邀约不一定在主题里带关键词，误杀召回。
      final readable = mails.where((m) => m.textBody.trim().isNotEmpty).toList();
      final processed = await ProcessedMailStore.filterUnprocessed(
        readable,
        (m) => m.uid,
      );
      // 已放弃的（反复识别失败达上限）不再拦路，否则游标永远推不动
      final unprocessed = await FailedMailStore.filterAbandoned(
        processed,
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
      String? firstAiError;
      var fatalAiError = false;
      var skippedExisting = 0;

      // 日历现有事件（判重用，尽力加载）：时间范围回扫会把识别过的邮件再跑一遍，
      // 已在日历的不该再进清单让用户重复审核。加载失败就退回旧行为（全部展示），
      // 不能因为判重数据拿不到就让整个同步失败。
      List<InterviewEvent> existingEvents = const [];
      try {
        existingEvents = await DatabaseService.instance.getAllEvents();
      } catch (_) {
        existingEvents = const [];
      }

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

        var results = await service.extractBatch(batch.map(mailText).toList());

        // 整批失败（AI 挂了 / 限流 / 超时）→ 可重试的错误逐封再试一次，
        // 避免一个偶发超时就把整批 8 封全丢掉。配置类错误重试没意义，直接判死刑。
        if (results.isNotEmpty && results.every((r) => r.hasError)) {
          final kind = results.first.errorKind;
          if (kind.isRetryable) {
            progress = '批量识别失败，正在逐封重试…';
            notify();
            final retried = <ExtractionResult>[];
            for (final m in batch) {
              if (_cancelled) break;
              retried.add(await service.extractFromText(mailText(m)));
            }
            // 用户中途点了停止：剩余的按失败记（下轮同步会重新拉到）
            while (retried.length < batch.length) {
              retried.add(const ExtractionResult(
                error: '已手动停止',
                errorKind: LlmErrorKind.unknown,
              ));
            }
            results = retried;
          }
        }

        var batchAllFailed = results.isNotEmpty && results.every((r) => r.hasError);
        for (var i = 0; i < batch.length && i < results.length; i++) {
          final r = results[i];
          if (r.hasError) {
            failedMailCount++;
            firstAiError ??= r.error;
            // 配置错误不会自愈；配额/限流（429、402）继续跑也只会把额度烧光
            if (r.errorKind == LlmErrorKind.config ||
                r.errorKind == LlmErrorKind.quota) {
              fatalAiError = true;
            }
            _failedThisRun.add(batch[i].uid);
            // 只有「这封邮件本身有问题」的失败才累计放弃次数：
            // output/unknown = 模型对这封邮件反复输出坏结果。
            // 环境类失败（配置、网络、超时、限流、服务端）不算在邮件头上 ——
            // 否则三次网络故障就把整窗邮件「放弃」掉，恢复后反而永久跳过（丢信）。
            // 取消占位（已手动停止）同样不计数，只是拦住游标等下轮重拉。
            final mailSpecific = r.errorKind == LlmErrorKind.output ||
                r.errorKind == LlmErrorKind.unknown;
            if (mailSpecific && !_cancelled) {
              await FailedMailStore.recordFailure(batch[i].uid);
            }
            continue;
          }
          // 识别成功 → 清掉历史失败记录（重新做人）
          await FailedMailStore.clearFailure(batch[i].uid);
          if (isActionableExtraction(r)) {
            // 已在日历里的（之前识别过、加入过）→ 不进清单重复审核
            if (matchesExistingEvent(r, existingEvents)) {
              skippedExisting++;
              continue;
            }
            found.add(MailCandidate(batch[i], r));
          }
        }
        done += batch.length;

        // 每批完成就快照：中途退出页面，回来时已识别的部分已经能看
        candidates = List.of(found);
        notify();

        // 配置类错误（Key 错、地址错）不会自愈 —— 后面每批都会一样失败，别再浪费时间
        if (batchAllFailed && fatalAiError && !_cancelled) break;
      }

      // 整轮扫完、没被取消也没识别出候选 → 尝试推进游标。
      // 能不能推进由 advanceCursor 内部的失败闸门决定（没到放弃次数的失败邮件拦着就不动）。
      if (!_cancelled && found.isEmpty) {
        await advanceCursor();
      }

      status = ParseStatus.done;
      progress = '';
      if (skippedExisting > 0) {
        // 让用户看见「跳过」这件事，而不是疑惑怎么少了几封
        fetchSummary = [
          if (fetchSummary != null) fetchSummary,
          '自动跳过 $skippedExisting 封（事件已在日历中）',
        ].join('，');
      }
      if (!_cancelled) {
        if (failedMailCount > 0) {
          final blocking =
              await FailedMailStore.hasBlocking(_failedThisRun);
          error = 'AI 服务不可用，$failedMailCount 封邮件没能识别：\n\n'
              '$firstAiError\n\n'
              '已识别的 ${found.length} 条照常保留。'
              '${blocking
                  ? '失败的邮件不会丢 —— 修好 AI 配置（点「AI 助手 → 设置 → 测试连接」确认）后重新同步即可。'
                  : '其中部分邮件已多次重试仍失败，已跳过以免反复计费；'
                      '需要的话可在「识别范围」里按日期手动回扫。'}';
        } else if (found.isEmpty) {
          error = '这些邮件里没识别出面试或测评邀约（可能是通知、拒信或无关邮件）。';
        }
      }
      notify();
    } on MailSyncException catch (e) {
      status = ParseStatus.done;
      progress = '';
      if (!_cancelled) error = e.message;
      notify();
    } catch (e) {
      status = ParseStatus.done;
      progress = '';
      // 用户主动停止不算错误，不弹提示
      if (!_cancelled) error = '同步失败：$e';
      notify();
    }
  }

  /// 把邮箱底层异常翻译成能照着排查的中文
  static String _friendlyFetchError(Object e) {
    final s = e.toString().toLowerCase();
    if (s.contains('auth') ||
        s.contains('login') ||
        s.contains('credential') ||
        s.contains('密码') ||
        s.contains('授权')) {
      return '邮箱登录失败：授权码错误或已失效。\n\n'
          '到 QQ 邮箱 → 设置 → 账户 → 开启 IMAP 并生成授权码，'
          '在「管理配置」里更新授权码后再试。';
    }
    if (s.contains('timed out') || s.contains('timeout')) {
      return '连接邮箱超时：检查网络后重试。';
    }
    if (s.contains('socket') ||
        s.contains('host lookup') ||
        s.contains('connection') ||
        s.contains('network')) {
      return '连接邮箱服务器失败：检查网络，或稍后重试。\n\n原始错误：$e';
    }
    if (s.contains('closed') || s.contains('abort')) {
      return '邮箱服务器中断了连接：稍后重试，频繁出现就检查授权码。\n\n原始错误：$e';
    }
    return '同步失败：$e';
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

  /// 游标是否正被「未到放弃次数的失败邮件」拦着 —— 界面据此提示用户
  Future<bool> get cursorBlocked async =>
      _failedThisRun.isNotEmpty &&
      await FailedMailStore.hasBlocking(_failedThisRun);

  /// 推进同步游标。**所有推进路径（同步结束、加入所选、忽略所选）都必须走这里** ——
  /// 里面内置了失败闸门：本轮还有没到放弃次数的识别失败邮件时拒绝推进，
  /// 否则失败邮件既不在游标之后也不在已处理名单里，会永久丢信。
  /// 手动选时间段识别不影响自动同步的游标（那是一次性的历史回扫）。
  Future<void> advanceCursor() async {
    if (_isRangeSync) return;
    if (await cursorBlocked) return;
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
