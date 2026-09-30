import 'dart:typed_data';

import 'llm_service.dart';
import 'profile_store.dart';
import 'mail_parse_session.dart' show ParseStatus;

/// 一张待识别的截图
class PickedImage {
  final Uint8List bytes;
  final String mime;

  PickedImage(this.bytes, this.mime);
}

/// 一条从截图总结出来的任务，待用户确认。
/// [result] 可变：用户在编辑页改过之后会替换成新的抽取结果。
/// [sourceText] 是这条任务所在那张截图的识别文字，编辑页「原文」显示它。
class TaskCandidate {
  ExtractionResult result;
  final String sourceText;
  bool selected = true;

  TaskCandidate(this.result, this.sourceText);
}

/// 截图解析会话（单例）。
///
/// 和 [MailParseSession] 同样的设计：识别跑在会话里、不依赖页面存活，
/// 退出截图页识别照常进行，回来重新挂监听即可接着看。
/// 选中的图片、识别文字、任务结果都保存在会话内存中，暂停/切页不丢。
class ScreenshotParseSession {
  ScreenshotParseSession._();
  static final ScreenshotParseSession instance = ScreenshotParseSession._();

  /// 最多一次识别 9 张，再多一次请求里也看不过来
  static const int maxImages = 9;

  ParseStatus status = ParseStatus.idle;
  String progress = '';
  String? error;
  List<PickedImage> images = [];
  String? recognizedText;
  List<TaskCandidate> tasks = [];

  bool _cancelled = false;
  bool _paused = false;

  final List<void Function()> _listeners = [];

  void addListener(void Function() fn) => _listeners.add(fn);

  void removeListener(void Function() fn) => _listeners.remove(fn);

  void notify() {
    for (final fn in List.of(_listeners)) {
      fn();
    }
  }

  bool get isBusy => status == ParseStatus.running || status == ParseStatus.paused;

  /// 替换图片列表（[append] 为 true 时追加），旧的识别结果作废
  void setImages(List<PickedImage> list, {bool append = false}) {
    images = append ? [...images, ...list] : list;
    recognizedText = null;
    tasks = [];
    error = null;
    notify();
  }

  void removeImageAt(int index) {
    if (index < 0 || index >= images.length) return;
    images = List.of(images)..removeAt(index);
    recognizedText = null;
    tasks = [];
    notify();
  }

  /// 开始识别：逐张送 AI，每批 3 张并发（思考模型单张几十秒，并发压总耗时）
  Future<void> start() async {
    if (isBusy) return;
    if (images.isEmpty) {
      error = '请先选择截图';
      status = ParseStatus.done;
      notify();
      return;
    }
    final profile = await ProfileStore.loadActive();
    if (profile == null || !profile.isConfigured) {
      error = '请先在「AI 助手 → 右上角设置」里配置 AI 档案（截图识别依赖 AI）';
      status = ParseStatus.done;
      notify();
      return;
    }

    _cancelled = false;
    _paused = false;
    error = null;
    recognizedText = null;
    tasks = [];
    status = ParseStatus.running;
    progress = '正在识别 0 / ${images.length} 张…';
    notify();

    try {
      final service = LlmService(profile);
      final snapshot = List<PickedImage>.of(images);
      final results = List<ScreenshotTasksResult?>.filled(snapshot.length, null);
      var done = 0;

      const chunk = 3;
      for (var start = 0; start < snapshot.length; start += chunk) {
        // 暂停检查点：当前这批发完后停住
        await _waitWhilePaused();
        if (_cancelled) break;

        final end = (start + chunk < snapshot.length) ? start + chunk : snapshot.length;
        await Future.wait([
          for (var i = start; i < end; i++)
            service
                .extractTasksFromImage(snapshot[i].bytes, mimeType: snapshot[i].mime)
                .then((r) {
              results[i] = r;
              done++;
              progress = '正在识别 $done / ${snapshot.length} 张…';
              notify();
            }),
        ]);
      }
      if (_cancelled) {
        status = ParseStatus.done;
        progress = '';
        notify();
        return;
      }

      final texts = <String>[];
      final found = <TaskCandidate>[];
      final errors = <String>[];
      for (var i = 0; i < snapshot.length; i++) {
        final r = results[i];
        if (r == null || r.hasError) {
          errors.add('图${i + 1}：${r?.error ?? '没有返回结果'}');
          continue;
        }
        texts.add('===== 图${i + 1} =====\n${r.recognizedText}');
        for (final t in r.tasks) {
          found.add(TaskCandidate(t, r.recognizedText));
        }
      }

      status = ParseStatus.done;
      progress = '';
      recognizedText = texts.join('\n\n');
      tasks = found;
      if (errors.isNotEmpty) {
        error = '部分截图识别失败：\n${errors.join('\n')}';
      } else if (found.isEmpty) {
        error = '截图里没总结出任务（可能只有说明性文字）。可以点「开始识别」重试。';
      }
      notify();
    } catch (e) {
      status = ParseStatus.done;
      progress = '';
      if (!_cancelled) error = '识别失败：$e';
      notify();
    }
  }

  Future<void> _waitWhilePaused() async {
    while (_paused && !_cancelled) {
      await Future.delayed(const Duration(milliseconds: 300));
    }
  }

  void pause() {
    if (status != ParseStatus.running) return;
    _paused = true;
    status = ParseStatus.paused;
    progress = '已暂停，点「继续」恢复';
    notify();
  }

  void resume() {
    if (status != ParseStatus.paused) return;
    _paused = false;
    status = ParseStatus.running;
    progress = '正在识别…';
    notify();
  }

  void cancel() {
    if (!isBusy) return;
    _paused = false;
    _cancelled = true;
    notify();
  }
}
