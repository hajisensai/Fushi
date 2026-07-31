// BUG-1263 的 UI 层守卫：940 副本的真删是分钟级长任务，
// runAnkiMediaDedupWithProgress 必须
//   1. 立刻弹出模态进度对话框（此前真删阶段零反馈，用户只见「假死」）；
//   2. 进度回调驱动「done / total + 当前文件 + 已释放空间」实时更新；
//   3. 取消按钮把 shouldCancel 置真、按钮进入「正在取消…」态；
//   4. 任务结束后弹窗必然关闭——包括瞬间结束（后端不支持 → null）的场景，
//      绝不留下关不掉的模态遮罩。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/anki/anki_media_dedup_dialogs.dart';
import 'package:hibiki/src/anki/anki_media_dedup_runner.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

class _NullRepo extends BaseAnkiRepository {
  @override
  Future<AnkiFetchResult> fetchConfiguration() async =>
      const AnkiFetchResult.error('unused');

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async =>
      MineOutcome.failure('unused');

  @override
  Future<bool> isDuplicate(String expression, String reading) async => false;

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => true;

  @override
  Future<bool> createDeck(String name) async => true;
}

/// 可手动推进的假 runner：把 onProgress / shouldCancel 暴露给测试驱动。
class _StubRunner extends AnkiMediaDedupRunner {
  _StubRunner() : super(_NullRepo());

  AnkiMediaDedupOnProgress? onProgress;
  bool Function()? shouldCancel;
  final Completer<AnkiMediaDedupReport?> _completer =
      Completer<AnkiMediaDedupReport?>();

  @override
  Future<AnkiMediaDedupReport?> runNow({
    required bool dryRun,
    AnkiMediaDedupOnProgress? onProgress,
    bool Function()? shouldCancel,
  }) {
    this.onProgress = onProgress;
    this.shouldCancel = shouldCancel;
    return _completer.future;
  }

  void complete(AnkiMediaDedupReport? report) => _completer.complete(report);
}

Future<BuildContext> _pumpHost(WidgetTester tester) async {
  late BuildContext host;
  await tester.pumpWidget(MaterialApp(
    home: Builder(builder: (BuildContext c) {
      host = c;
      return const SizedBox.shrink();
    }),
  ));
  return host;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  LocaleSettings.setLocale(AppLocale.en);

  testWidgets('BUG-1263：真删期间弹进度对话框，进度实时更新，结束后关闭',
      (WidgetTester tester) async {
    final _StubRunner runner = _StubRunner();
    final BuildContext host = await _pumpHost(tester);

    final Future<AnkiMediaDedupReport?> pending =
        runAnkiMediaDedupWithProgress(host, runner, dryRun: false);
    await tester.pump();

    // 弹窗立现，初始为扫描态。
    expect(find.text(t.anki_dedup_progress_title), findsOneWidget);

    // 进度回调驱动 UI：done/total + 当前文件 + 已释放空间。
    runner.onProgress!(const AnkiMediaDedupProgress(
      stage: AnkiMediaDedupStage.resolving,
      done: 3,
      total: 10,
      currentFile: 'dupe-abc123.mp3',
      bytesFreed: 2048,
    ));
    await tester.pump();
    expect(find.text(t.anki_dedup_progress_resolving(done: '3', total: '10')),
        findsOneWidget);
    expect(find.text('dupe-abc123.mp3'), findsOneWidget);
    expect(find.text(t.anki_dedup_progress_freed(size: '2.0 KB')),
        findsOneWidget);

    // 结束后弹窗关闭，结果原样返回。
    runner.complete(const AnkiMediaDedupReport(
      dryRun: false,
      groupCount: 1,
      deletions: <MediaDedupDeletion>[],
      notesRewritten: 0,
      modelsRewritten: 0,
      skipped: 0,
    ));
    await tester.pumpAndSettle();
    expect(find.text(t.anki_dedup_progress_title), findsNothing);
    expect(await pending, isNotNull);
  });

  testWidgets('BUG-1263：取消按钮置真 shouldCancel 并进入「正在取消…」态',
      (WidgetTester tester) async {
    final _StubRunner runner = _StubRunner();
    final BuildContext host = await _pumpHost(tester);

    final Future<AnkiMediaDedupReport?> pending =
        runAnkiMediaDedupWithProgress(host, runner, dryRun: true);
    await tester.pump();

    expect(runner.shouldCancel!(), isFalse);
    await tester.tap(find.text(t.dialog_cancel));
    await tester.pump();
    // 取消请求已传导到仓库层判据；按钮反馈「正在取消…」且不可再点。
    expect(runner.shouldCancel!(), isTrue);
    expect(find.text(t.anki_dedup_cancelling), findsOneWidget);

    runner.complete(const AnkiMediaDedupReport(
      dryRun: true,
      groupCount: 0,
      deletions: <MediaDedupDeletion>[],
      notesRewritten: 0,
      modelsRewritten: 0,
      skipped: 0,
      cancelled: true,
    ));
    await tester.pumpAndSettle();
    expect(find.text(t.anki_dedup_progress_title), findsNothing);
    final AnkiMediaDedupReport? report = await pending;
    expect(report!.cancelled, isTrue);
  });

  testWidgets('BUG-1263：任务瞬间结束（后端不支持）也不留下关不掉的遮罩',
      (WidgetTester tester) async {
    final _StubRunner runner = _StubRunner();
    final BuildContext host = await _pumpHost(tester);

    // 在弹窗 builder 跑起来之前就完成任务：finally 必须等到首帧后仍把它关掉。
    runner.complete(null);
    final Future<AnkiMediaDedupReport?> pending =
        runAnkiMediaDedupWithProgress(host, runner, dryRun: true);
    await tester.pumpAndSettle();

    expect(await pending, isNull);
    expect(find.text(t.anki_dedup_progress_title), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
  });
}
