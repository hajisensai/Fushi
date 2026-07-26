import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/media/manga/online/mokuro_moe_catalog_dialog.dart';
import 'package:hibiki/src/media/manga/online/mokuro_moe_client.dart';
import 'package:hibiki/src/media/manga/online/mokuro_moe_download_queue.dart';
import 'package:hibiki/src/media/manga/online/mokuro_moe_volume_downloader.dart';
import 'package:hibiki/src/utils/misc/hibiki_toast.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// fake client：内存数据，零网络（封面留空走占位图标路径）。
class _FakeClient extends MokuroMoeClient {
  _FakeClient(this.library);

  final List<MokuroMoeSeries> library;
  Exception? libraryError;

  @override
  Future<List<MokuroMoeSeries>> fetchLibrary() async {
    final Exception? error = libraryError;
    if (error != null) throw error;
    return library;
  }
}

const List<MokuroMoeSeries> _library = <MokuroMoeSeries>[
  MokuroMoeSeries(
    name: 'よつばと!',
    volumes: <MokuroMoeVolume>[
      MokuroMoeVolume(name: 'よつばと! 第01巻'),
      MokuroMoeVolume(name: 'よつばと! 第02巻'),
    ],
  ),
  MokuroMoeSeries(
    name: 'ヨコハマ買い出し紀行',
    volumes: <MokuroMoeVolume>[MokuroMoeVolume(name: '第01巻')],
  ),
];

void main() {
  late HibikiDatabase db;

  setUp(() {
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  /// TranslationProvider 壳（+ ProviderScope，对话框是 ConsumerStatefulWidget；
  /// clientOverride/queueOverride 非 null 时不会触达 appProvider）。
  Widget wrap(Widget child) {
    return ProviderScope(
      child: TranslationProvider(
        child: MaterialApp(home: Scaffold(body: child)),
      ),
    );
  }

  /// 注入 runner 的测试队列：记录调用、回传受控事件流。
  ({
    MokuroMoeDownloadQueue queue,
    List<(String, String)> calls,
    List<StreamController<MokuroMoeVolumeDownloadEvent>> ctrls,
  }) makeQueue() {
    final List<(String, String)> calls = <(String, String)>[];
    final List<StreamController<MokuroMoeVolumeDownloadEvent>> ctrls =
        <StreamController<MokuroMoeVolumeDownloadEvent>>[];
    final MokuroMoeDownloadQueue queue = MokuroMoeDownloadQueue(
      db: db,
      clientFactory: () => MokuroMoeClient(),
      runnerOverride: (
          {required String seriesName, required String volumeName}) {
        calls.add((seriesName, volumeName));
        final StreamController<MokuroMoeVolumeDownloadEvent> c =
            StreamController<MokuroMoeVolumeDownloadEvent>();
        ctrls.add(c);
        return c.stream;
      },
    );
    return (queue: queue, calls: calls, ctrls: ctrls);
  }

  testWidgets('browse：目录加载后渲染系列，搜索大小写不敏感过滤', (WidgetTester tester) async {
    final q = makeQueue();
    await tester.pumpWidget(wrap(MokuroMoeCatalogDialog(
      db: db,
      clientOverride: _FakeClient(_library),
      queueOverride: q.queue,
    )));
    await tester.pumpAndSettle();

    expect(find.text('よつばと!'), findsOneWidget);
    expect(find.text('ヨコハマ買い出し紀行'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'よつばと');
    await tester.pumpAndSettle();
    expect(find.text('よつばと!'), findsOneWidget);
    expect(find.text('ヨコハマ買い出し紀行'), findsNothing);
    q.queue.dispose();
  });

  testWidgets('browse：加载失败显示错误 + 重试按钮，重试后恢复', (WidgetTester tester) async {
    final q = makeQueue();
    final _FakeClient client = _FakeClient(_library)
      ..libraryError = Exception('boom');
    await tester.pumpWidget(wrap(MokuroMoeCatalogDialog(
      db: db,
      clientOverride: client,
      queueOverride: q.queue,
    )));
    await tester.pumpAndSettle();

    expect(find.textContaining(t.manga_online_load_failed), findsOneWidget);

    client.libraryError = null;
    await tester.tap(find.text(t.retry));
    await tester.pumpAndSettle();
    expect(find.text('よつばと!'), findsOneWidget);
    q.queue.dispose();
  });

  testWidgets('series → 选卷 → 入队：runner 起卷、进度渲染、完成标记 ✓',
      (WidgetTester tester) async {
    final q = makeQueue();
    await tester.pumpWidget(wrap(MokuroMoeCatalogDialog(
      db: db,
      clientOverride: _FakeClient(_library),
      queueOverride: q.queue,
    )));
    await tester.pumpAndSettle();

    // 进入 series 阶段。
    await tester.tap(find.text('よつばと!'));
    await tester.pumpAndSettle();
    expect(find.text('よつばと! 第01巻'), findsOneWidget);
    expect(find.text('よつばと! 第02巻'), findsOneWidget);

    // 未选卷时「下载所选」禁用。
    final TextButton downloadBtn = tester.widget<TextButton>(
      find.widgetWithText(TextButton, t.manga_online_download_selected),
    );
    expect(downloadBtn.onPressed, isNull);

    // 选第 1 卷 → 入队（下载在共享队列后台执行，对话框停在 series 阶段可继续选）。
    await tester.tap(find.text('よつばと! 第01巻'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.manga_online_download_selected));
    await tester.pump();
    expect(q.calls.single, ('よつばと!', 'よつばと! 第01巻'));

    // CBZ 字节进度 → 内联面板进度条 + 阶段文案（面板 + 当前卷 subtitle 两处一致）。
    q.ctrls[0].add(const MokuroMoeVolumeDownloadEvent(
      stage: MokuroMoeDownloadStage.downloadingCbz,
      receivedBytes: 512 * 1024,
      totalBytes: 1024 * 1024,
    ));
    await tester.pump();
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.textContaining(t.manga_online_stage_cbz), findsWidgets);

    // 完成 → 该卷标 ✓（不可再选），无复选框残留选中；面板随队列清空收起。
    q.ctrls[0].add(const MokuroMoeVolumeDownloadEvent(
      stage: MokuroMoeDownloadStage.done,
      bookKey: 'yotsubato-01',
    ));
    await q.ctrls[0].close();
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.text(t.manga_online_downloaded), findsOneWidget);
    expect(q.queue.importedCount, 1);
    q.queue.dispose();
  });

  testWidgets('统一下载中心：关闭对话框不中断队列下载（任务在后台走完并计数）', (WidgetTester tester) async {
    final q = makeQueue();
    await tester.pumpWidget(wrap(MokuroMoeCatalogDialog(
      db: db,
      clientOverride: _FakeClient(_library),
      queueOverride: q.queue,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('よつばと!'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('よつばと! 第01巻'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.manga_online_download_selected));
    await tester.pump();
    expect(q.calls, hasLength(1));

    // 「关闭对话框」：整树替换（dispose 对话框 State）。队列不被取消。
    await tester.pumpWidget(wrap(const SizedBox.shrink()));
    await tester.pumpAndSettle();
    expect(q.queue.runningTask, isNotNull);

    q.ctrls[0].add(const MokuroMoeVolumeDownloadEvent(
      stage: MokuroMoeDownloadStage.done,
      bookKey: 'yotsubato-01',
    ));
    await q.ctrls[0].close();
    await tester.pumpAndSettle();
    expect(q.queue.tasks.single.status, MokuroMoeTaskStatus.done);
    expect(q.queue.importedCount, 1);
    q.queue.dispose();
  });

  testWidgets('reopen does not report historical completed tasks as newly done',
      (WidgetTester tester) async {
    final q = makeQueue();
    q.queue.enqueue(
      seriesName: _library.first.name,
      volumeNames: <String>[_library.first.volumes.first.name],
    );
    q.ctrls[0].add(const MokuroMoeVolumeDownloadEvent(
      stage: MokuroMoeDownloadStage.done,
      bookKey: 'historical-volume',
    ));
    await q.ctrls[0].close();
    expect(q.queue.tasks.single.status, MokuroMoeTaskStatus.done);

    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    HibikiToast.navigatorKey = navKey;
    await tester.pumpWidget(
      ProviderScope(
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navKey,
            home: Scaffold(
              body: MokuroMoeCatalogDialog(
                db: db,
                clientOverride: _FakeClient(_library),
                queueOverride: q.queue,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    q.queue.enqueue(
      seriesName: _library.first.name,
      volumeNames: <String>[_library.first.volumes.last.name],
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(
      find.text(t.manga_ocr_wizard_done),
      findsNothing,
      reason:
          'Reopening must seed historical done tasks before listening to the shared queue.',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    q.queue.dispose();
  });
}
