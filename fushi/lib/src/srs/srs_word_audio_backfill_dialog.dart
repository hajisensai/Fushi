/// 复习（SRS）牌组菜单「补全单词音频」的对话框与 app 侧装配（逻辑见
/// srs_word_audio_backfill.dart）。
///
/// 取音频复用制卡的同一条路径：
/// 1. [resolveLookupAudioUrl]：用户配置的音频来源，按配置顺序（本地音频库按启用序号、互联
///    配对设备、远程 URL 模板，带远端失败冷却）——查词 ♪ / 制卡弹窗填 `audio` 用的就是它；
/// 2. [SrsMiner.storeWordAudio]：把解析出的引用落成文件、按内容哈希存进 SRS 媒体（制卡
///    `_render` 同一个方法），字段写 `[sound:<存储名>]`。
///
/// 不用 TTS 兜底（`ttsFallback: false`）：读音为空时系统语音只能按词形念，等于机器推断读音
/// （自动注音在全仓功能黑名单里）；补全只收真实录音。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_anki/fushi_anki_core.dart' show AudioFetchOutcome;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_mining.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/srs/srs_word_audio_backfill.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/lookup_audio_playback.dart'
    show resolveLookupAudioUrl;
import 'package:fushi/utils.dart';

/// 制卡同一条取音频路径（见文件头）装成 [SrsWordAudioFetcher]。
SrsWordAudioFetcher srsMiningWordAudioFetcher(AppModel app, SrsMiner miner) =>
    (String term, String reading) async {
      final String? ref = await resolveLookupAudioUrl(
        app,
        term,
        reading,
        ttsFallback: false,
      );
      if (ref == null || ref.isEmpty) return const SrsWordAudioNotFound();
      final AudioFetchOutcome stored = await miner.storeWordAudio(ref);
      final String? name = stored.ref;
      if (name != null) return SrsWordAudioStored(name);
      final String? failure = stored.failureReason;
      return failure != null
          ? SrsWordAudioFetchFailed(failure)
          : const SrsWordAudioNotFound();
    };

/// 对话框阶段。
enum SrsWordAudioBackfillPhase { scanning, running, done, failed }

/// 一次补全的状态机：扫描 → 逐张处理 → 汇总。[cancel] 后处理完当前这张就停。
class SrsWordAudioBackfillController extends ChangeNotifier {
  SrsWordAudioBackfillController({
    required this.scan,
    required this.deps,
    this.onWritten,
  });

  /// 扫出待补的卡。
  final Future<List<SrsWordAudioBackfillItem>> Function() scan;
  final SrsWordAudioBackfillDeps deps;

  /// 跑完（含取消）且写过卡时调用：让列表 / 复习页重读。
  final VoidCallback? onWritten;

  SrsWordAudioBackfillPhase _phase = SrsWordAudioBackfillPhase.scanning;
  SrsWordAudioBackfillPhase get phase => _phase;

  int _processed = 0;
  int get processed => _processed;

  int _total = 0;
  int get total => _total;

  bool _cancelRequested = false;
  bool get cancelRequested => _cancelRequested;

  SrsWordAudioBackfillResult? _result;
  SrsWordAudioBackfillResult? get result => _result;

  Object? _error;
  Object? get error => _error;

  bool _disposed = false;

  bool get finished =>
      _phase == SrsWordAudioBackfillPhase.done ||
      _phase == SrsWordAudioBackfillPhase.failed;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// 请求取消：不再开始下一张，已写入的保留。
  void cancel() {
    if (finished || _cancelRequested) return;
    _cancelRequested = true;
    _notify();
  }

  Future<void> start() async {
    final List<SrsWordAudioBackfillItem> items;
    try {
      items = await scan();
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsWordAudioBackfill.scan', e, stack);
      _error = e;
      _phase = SrsWordAudioBackfillPhase.failed;
      _notify();
      return;
    }
    _total = items.length;
    _phase = SrsWordAudioBackfillPhase.running;
    _notify();
    final SrsWordAudioBackfillResult result = await runSrsWordAudioBackfill(
      items,
      deps,
      onProgress: (int processed, int total) {
        _processed = processed;
        _notify();
      },
      isCancelled: () => _cancelRequested,
    );
    if (result.failures.isNotEmpty) {
      ErrorLogService.instance.log(
        'SrsWordAudioBackfill: ${result.failed} card(s) failed',
        result.failures.join('\n'),
      );
    }
    _result = result;
    _phase = SrsWordAudioBackfillPhase.done;
    if (result.filled > 0) onWritten?.call();
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// 牌组菜单入口：打开对话框、立即开始。复习模块关着 / store 打不开时什么都不做。
Future<void> openSrsWordAudioBackfill(
  BuildContext context,
  WidgetRef ref, {
  required String deckId,
}) async {
  final AppModel app = ref.read(appProvider);
  final SrsDbStore? store = await readSrsStore(ref);
  final SrsMediaStore? media = await ref.read(srsMediaStoreProvider.future);
  if (store == null || media == null || !context.mounted) return;
  final SrsMiner miner = SrsMiner(store: store, media: media);
  final SrsWordAudioBackfillFields fields =
      SrsWordAudioBackfillFields.forProfile(store.profileUid);
  final SrsWordAudioBackfillController controller =
      SrsWordAudioBackfillController(
        scan: () => loadSrsWordAudioBackfillItems(store, deckId),
        deps: SrsWordAudioBackfillDeps(
          fetch: srsMiningWordAudioFetcher(app, miner),
          write: (String noteId, String value) => store.updateNote(
            noteId,
            fieldsById: <String, String>{fields.audioFieldId: value},
          ),
        ),
        onWritten: () {
          if (context.mounted) bumpSrsRevision(ref);
        },
      );
  final Future<void> run = controller.start();
  try {
    await showAppDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) =>
          SrsWordAudioBackfillDialog(controller: controller),
    );
    // 对话框被外力关掉（换 profile、路由清栈）也不丢已写入的：等这一张写完再收。
    controller.cancel();
    await run;
  } finally {
    controller.dispose();
  }
}

/// 进度 / 结果对话框。运行中只有「停止」，返回键 / Esc 也当停止；跑完才能关。
class SrsWordAudioBackfillDialog extends StatelessWidget {
  const SrsWordAudioBackfillDialog({required this.controller, super.key});

  final SrsWordAudioBackfillController controller;

  /// 对话框正文宽度。
  static const double contentWidth = 420;

  Widget _body(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsWordAudioBackfillController c = controller;
    int step = 0;
    Widget stagger(Widget child) =>
        FushiStaggeredEntrance(index: step++, child: child);
    final List<Widget> children = switch (c.phase) {
      SrsWordAudioBackfillPhase.scanning => <Widget>[
        stagger(Text(t.srs_word_audio_backfill_hint)),
        SizedBox(height: tokens.spacing.gap),
        stagger(
          FushiLinearProgressIndicator(
            semanticsLabel: t.srs_word_audio_backfill_scanning,
          ),
        ),
        SizedBox(height: tokens.spacing.gap / 2),
        stagger(Text(t.srs_word_audio_backfill_scanning)),
      ],
      SrsWordAudioBackfillPhase.running => <Widget>[
        stagger(Text(t.srs_word_audio_backfill_hint)),
        SizedBox(height: tokens.spacing.gap),
        stagger(
          FushiLinearProgressIndicator(
            key: const ValueKey<String>('srs-word-audio-backfill-progress'),
            value: c.total == 0 ? null : c.processed / c.total,
            semanticsLabel: t.srs_word_audio_backfill_title,
          ),
        ),
        SizedBox(height: tokens.spacing.gap / 2),
        stagger(
          Text(
            t.srs_word_audio_backfill_progress(
              done: c.processed,
              total: c.total,
            ),
            style: context.fushiType.bodySmall.tabular,
          ),
        ),
      ],
      SrsWordAudioBackfillPhase.done => <Widget>[
        if (c.result case final SrsWordAudioBackfillResult r) ...<Widget>[
          if (r.total == 0)
            stagger(Text(t.srs_word_audio_backfill_empty))
          else
            stagger(
              Text(
                t.srs_word_audio_backfill_summary(
                  filled: r.filled,
                  skipped: r.skipped,
                  failed: r.failed,
                ),
                key: const ValueKey<String>('srs-word-audio-backfill-summary'),
              ),
            ),
          if (r.cancelled) ...<Widget>[
            SizedBox(height: tokens.spacing.gap),
            stagger(
              FushiInlineNotice(
                message: t.srs_word_audio_backfill_cancelled,
                severity: FushiNoticeSeverity.warning,
              ),
            ),
          ],
        ],
      ],
      SrsWordAudioBackfillPhase.failed => <Widget>[
        stagger(
          FushiInlineNotice(
            message: t.srs_word_audio_backfill_scan_failed(
              error: '${c.error ?? ''}',
            ),
            severity: FushiNoticeSeverity.error,
          ),
        ),
      ],
    };
    return FushiEntranceScope(
      replayKey: c.phase,
      child: Column(
        key: ValueKey<SrsWordAudioBackfillPhase>(c.phase),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Size screen = MediaQuery.sizeOf(context);
    final double insetX = (screen.width * 0.05).clamp(16.0, 40.0);
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) {
        final SrsWordAudioBackfillController c = controller;
        return PopScope<void>(
          canPop: c.finished,
          onPopInvokedWithResult: (bool didPop, void _) {
            if (!didPop) c.cancel();
          },
          child: FushiAlertDialog(
            insetPadding: EdgeInsets.symmetric(
              horizontal: insetX,
              vertical: 24,
            ),
            icon: const FushiDialogHeroIcon(icon: FushiIcons.audio),
            title: Text(t.srs_word_audio_backfill_title),
            content: SizedBox(
              width: contentWidth,
              child: SingleChildScrollView(
                child: FushiAnimatedSize(
                  duration: fushiMotionDuration(context, FushiMotion.short),
                  curve: FushiMotion.standard,
                  alignment: Alignment.topCenter,
                  child: _body(context),
                ),
              ),
            ),
            actions: <Widget>[
              if (c.finished)
                FushiDialogAction(
                  key: const ValueKey<String>('srs-word-audio-backfill-close'),
                  label: t.dialog_close,
                  kind: FushiDialogActionKind.primary,
                  autofocus: true,
                  onPressed: () => Navigator.of(context).pop(),
                )
              else
                FushiDialogAction(
                  key: const ValueKey<String>('srs-word-audio-backfill-stop'),
                  label: t.dialog_stop,
                  autofocus: true,
                  onPressed: c.cancelRequested ? null : c.cancel,
                ),
            ],
          ),
        );
      },
    );
  }
}
