import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/download/manga_download_service.dart';
import 'package:fushi/src/media/manga/online/mokuro_moe_catalog_dialog.dart';
import 'package:fushi/src/media/manga/online/mokuro_moe_client.dart';
import 'package:fushi/src/media/manga/online/mokuro_moe_volume_downloader.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi_core/fushi_core.dart';

/// fake client：内存数据，零网络（封面留空走占位图标路径）。
class _FakeClient extends MokuroMoeClient {
  _FakeClient(this.library);

  final List<MokuroMoeSeries> library;
  Exception? libraryError;
  int fetchCalls = 0;

  @override
  Future<List<MokuroMoeSeries>> fetchLibrary() async {
    fetchCalls++;
    final Exception? error = libraryError;
    if (error != null) throw error;
    return library;
  }
}

/// 站点**当前**的真实响应形状：`catalog/api/library` 不再内联 `volumes`（只剩
/// `volume_count`），卷清单只住在 `catalog/api/series?name=`。
///
/// BUG-1927：上面那个 [_FakeClient] + [_library] 钉的是服务端早已不产出的旧形状
/// （library 条目自带 volumes），所以「点开系列一片空白」这条从来没被测到 —— 生产
/// 代码里 fetchSeries 一个调用点都没有，详情页直接拿浏览列表那个空 volumes 去画。
class _ServerShapedClient extends MokuroMoeClient {
  _ServerShapedClient(this.detail);

  /// 系列名 → `api/series` 会回的详情。
  final Map<String, MokuroMoeSeries> detail;
  final List<String> seriesCalls = <String>[];
  Exception? seriesError;

  @override
  Future<List<MokuroMoeSeries>> fetchLibrary() async => <MokuroMoeSeries>[
        // 关键：只有名字，没有 volumes。
        for (final String name in detail.keys) MokuroMoeSeries(name: name),
      ];

  @override
  Future<MokuroMoeSeries> fetchSeries(String name) async {
    seriesCalls.add(name);
    final Exception? error = seriesError;
    if (error != null) throw error;
    return detail[name]!;
  }
}

/// 假下载器：`run` 记录 `(系列, 卷)` 并回传测试受控的事件流。
class _FakeDownloader extends MokuroMoeVolumeDownloader {
  _FakeDownloader(this.calls) : super(client: MokuroMoeClient());

  final List<(String, String)> calls;
  final StreamController<MokuroMoeVolumeDownloadEvent> ctrl =
      StreamController<MokuroMoeVolumeDownloadEvent>();

  @override
  Stream<MokuroMoeVolumeDownloadEvent> run({
    required FushiDatabase db,
    required String seriesName,
    required String volumeName,
  }) {
    calls.add((seriesName, volumeName));
    return ctrl.stream;
  }

  @override
  void cancel() {}
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

const MokuroMoeVolumeDownloadEvent _doneEvent = MokuroMoeVolumeDownloadEvent(
  stage: MokuroMoeDownloadStage.done,
  bookKey: 'yotsubato-01',
);

String _jobId(String series, String volume) => mangaDownloadJobId(
      kind: MangaDownloadJobKind.mokuroVolume,
      bookKey: mokuroMoeBookKey(series),
      chapterKey: volume,
    );

void main() {
  late FushiDatabase db;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  /// TranslationProvider 壳（+ ProviderScope，对话框是 StatefulWidget 但内容体
  /// 是 ConsumerStatefulWidget；clientOverride/downloadsOverride 非 null 时不会
  /// 触达 appProvider）。
  Widget wrap(Widget child) {
    return ProviderScope(
      child: TranslationProvider(
        child: MaterialApp(home: Scaffold(body: child)),
      ),
    );
  }

  /// 注入假下载器的真实服务（worker 已 start、退避零等待）：记录 run 调用、
  /// 回传受控事件流。
  Future<
      ({
        MangaDownloadService service,
        List<(String, String)> calls,
        List<_FakeDownloader> downloaders,
      })> makeService() async {
    final List<(String, String)> calls = <(String, String)>[];
    final List<_FakeDownloader> downloaders = <_FakeDownloader>[];
    int tick = 0;
    final MangaDownloadService service = MangaDownloadService(
      database: db,
      serviceFor: (_) => throw UnimplementedError('本测试不跑章节任务'),
      mokuroDownloader: () {
        final _FakeDownloader downloader = _FakeDownloader(calls);
        downloaders.add(downloader);
        return downloader;
      },
      clock: () => DateTime.fromMillisecondsSinceEpoch(++tick),
      wait: (_) async {},
    );
    addTearDown(() {
      // 先停服务（worker 收到 stopped 后不再写库），再关掉还挂着的假流。
      service.dispose();
      for (final _FakeDownloader downloader in downloaders) {
        if (!downloader.ctrl.isClosed) unawaited(downloader.ctrl.close());
      }
    });
    await service.start();
    return (service: service, calls: calls, downloaders: downloaders);
  }

  /// 逐帧 pump 直到条件为真（worker 起跑、事件落库、表变更回到 UI 之间隔着
  /// 若干微任务与重建）。不能用 pumpAndSettle：执行中面板的不定进度条会一直动。
  Future<void> pumpUntil(
    WidgetTester tester,
    FutureOr<bool> Function() condition, {
    String reason = '',
  }) async {
    for (int i = 0; i < 100; i++) {
      if (await condition()) return;
      await tester.pump(const Duration(milliseconds: 10));
    }
    fail('等待超时: $reason');
  }

  testWidgets('browse：目录加载后渲染系列，搜索大小写不敏感过滤', (WidgetTester tester) async {
    final s = await makeService();
    await tester.pumpWidget(wrap(MokuroMoeCatalogDialog(
      db: db,
      clientOverride: _FakeClient(_library),
      downloadsOverride: s.service,
    )));
    await tester.pumpAndSettle();

    expect(find.text('よつばと!'), findsOneWidget);
    expect(find.text('ヨコハマ買い出し紀行'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'よつばと');
    await tester.pumpAndSettle();
    expect(find.text('よつばと!'), findsOneWidget);
    expect(find.text('ヨコハマ買い出し紀行'), findsNothing);
  });

  testWidgets('来源关闭时不请求目录，正文显示开启提示', (WidgetTester tester) async {
    final s = await makeService();
    final _FakeClient client = _FakeClient(_library);
    await tester.pumpWidget(wrap(MokuroMoeCatalogDialog(
      db: db,
      clientOverride: client,
      downloadsOverride: s.service,
      enabledOverride: false,
    )));
    await tester.pumpAndSettle();

    expect(client.fetchCalls, 0);
    expect(find.text(t.manga_online_source_disabled), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('browse：加载失败显示错误 + 重试按钮，重试后恢复', (WidgetTester tester) async {
    final s = await makeService();
    final _FakeClient client = _FakeClient(_library)
      ..libraryError = Exception('boom');
    await tester.pumpWidget(wrap(MokuroMoeCatalogDialog(
      db: db,
      clientOverride: client,
      downloadsOverride: s.service,
    )));
    await tester.pumpAndSettle();

    expect(find.textContaining(t.manga_online_load_failed), findsOneWidget);

    client.libraryError = null;
    await tester.tap(find.text(t.retry));
    await tester.pumpAndSettle();
    expect(find.text('よつばと!'), findsOneWidget);
  });

  testWidgets('BUG-1927：library 不带 volumes 时，点开系列必须去取详情',
      (WidgetTester tester) async {
    final s = await makeService();
    final _ServerShapedClient client =
        _ServerShapedClient(<String, MokuroMoeSeries>{
      'よつばと!': const MokuroMoeSeries(
        name: 'よつばと!',
        volumes: <MokuroMoeVolume>[MokuroMoeVolume(name: 'よつばと! 第01巻')],
      ),
    });
    await tester.pumpWidget(wrap(MokuroMoeCatalogDialog(
      db: db,
      clientOverride: client,
      downloadsOverride: s.service,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('よつばと!'));
    await tester.pumpAndSettle();

    expect(client.seriesCalls, <String>['よつばと!'],
        reason: '不去取详情就只有浏览列表那个空 volumes 可画 —— 于是一片空白。');
    expect(find.text('よつばと! 第01巻'), findsOneWidget);
  });

  testWidgets('BUG-1927：详情取失败要说出来并可重试，而不是留一片空白', (WidgetTester tester) async {
    final s = await makeService();
    final _ServerShapedClient client =
        _ServerShapedClient(<String, MokuroMoeSeries>{
      'よつばと!': const MokuroMoeSeries(
        name: 'よつばと!',
        volumes: <MokuroMoeVolume>[MokuroMoeVolume(name: 'よつばと! 第01巻')],
      ),
    })
          ..seriesError = Exception('boom');
    await tester.pumpWidget(wrap(MokuroMoeCatalogDialog(
      db: db,
      clientOverride: client,
      downloadsOverride: s.service,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('よつばと!'));
    await tester.pumpAndSettle();
    expect(
        find.textContaining(t.manga_online_detail_load_failed), findsOneWidget);

    client.seriesError = null;
    await tester.tap(find.text(t.retry));
    await tester.pumpAndSettle();
    expect(find.text('よつばと! 第01巻'), findsOneWidget);
  });

  testWidgets('BUG-1927：系列真的没有卷时给空态文案，不是空白', (WidgetTester tester) async {
    final s = await makeService();
    final _ServerShapedClient client =
        _ServerShapedClient(<String, MokuroMoeSeries>{
      'からっぽ': const MokuroMoeSeries(name: 'からっぽ'),
    });
    await tester.pumpWidget(wrap(MokuroMoeCatalogDialog(
      db: db,
      clientOverride: client,
      downloadsOverride: s.service,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('からっぽ'));
    await tester.pumpAndSettle();

    expect(find.text(t.manga_online_series_empty), findsOneWidget,
        reason: '「加载中 / 取失败 / 真的没有卷」三种情况以前长得一模一样。');
  });

  testWidgets('series → 选卷 → 入队：worker 起卷、进度渲染、完成标记 ✓',
      (WidgetTester tester) async {
    final s = await makeService();
    await tester.pumpWidget(wrap(MokuroMoeCatalogDialog(
      db: db,
      clientOverride: _FakeClient(_library),
      downloadsOverride: s.service,
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

    // 选第 1 卷 → 入队（下载在持久任务表后台执行，对话框停在 series 阶段可继续选）。
    await tester.tap(find.text('よつばと! 第01巻'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.manga_online_download_selected));
    await pumpUntil(tester, () => s.calls.isNotEmpty, reason: 'worker 起卷');
    expect(s.calls.single, ('よつばと!', 'よつばと! 第01巻'));
    final String jobId = _jobId('よつばと!', 'よつばと! 第01巻');
    expect(
      (await db.getMangaDownloadJob(jobId))!.status,
      MangaDownloadJobStatus.running,
    );

    // CBZ 字节进度 → 任务行 pages_done/pages_total 记字节 → 内联面板进度条 +
    // 「x / y」文案（面板 + 当前卷 subtitle 两处一致）。
    s.downloaders[0].ctrl.add(const MokuroMoeVolumeDownloadEvent(
      stage: MokuroMoeDownloadStage.downloadingCbz,
      receivedBytes: 512 * 1024,
      totalBytes: 1024 * 1024,
    ));
    final String progressText = t.manga_ocr_wizard_page_progress(
      done: 512 * 1024,
      total: 1024 * 1024,
    );
    await pumpUntil(
      tester,
      () => find.textContaining(progressText).evaluate().isNotEmpty,
      reason: '进度文案回到 UI',
    );
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.textContaining(progressText), findsNWidgets(2));
    expect(find.textContaining(t.download_status_queued), findsNothing);

    // 完成 → 该卷标 ✓（不可再选）；面板随任务收尾收起；计数 +1。
    s.downloaders[0].ctrl.add(_doneEvent);
    await s.downloaders[0].ctrl.close();
    await pumpUntil(
      tester,
      () => find.byIcon(Icons.check_circle).evaluate().isNotEmpty,
      reason: '✓ 标记',
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.text(t.manga_online_downloaded), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(
      (await db.getMangaDownloadJob(jobId))!.status,
      MangaDownloadJobStatus.done,
    );
    expect(s.service.mokuroImportedCount.value, 1);
  });

  testWidgets('统一下载中心：关闭对话框不中断下载（任务在后台走完并计数）', (WidgetTester tester) async {
    final s = await makeService();
    await tester.pumpWidget(wrap(MokuroMoeCatalogDialog(
      db: db,
      clientOverride: _FakeClient(_library),
      downloadsOverride: s.service,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('よつばと!'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('よつばと! 第01巻'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.manga_online_download_selected));
    await pumpUntil(tester, () => s.calls.isNotEmpty, reason: 'worker 起卷');
    expect(s.calls, hasLength(1));
    final String jobId = _jobId('よつばと!', 'よつばと! 第01巻');

    // 「关闭对话框」：整树替换（dispose 对话框 State）。任务不被取消。
    await tester.pumpWidget(wrap(const SizedBox.shrink()));
    await tester.pumpAndSettle();
    expect(
      (await db.getMangaDownloadJob(jobId))!.status,
      MangaDownloadJobStatus.running,
    );

    s.downloaders[0].ctrl.add(_doneEvent);
    await s.downloaders[0].ctrl.close();
    await pumpUntil(
      tester,
      () async =>
          (await db.getMangaDownloadJob(jobId))!.status ==
          MangaDownloadJobStatus.done,
      reason: '后台走完',
    );
    expect(s.service.mokuroImportedCount.value, 1);
  });

  testWidgets('reopen does not report historical completed tasks as newly done',
      (WidgetTester tester) async {
    final s = await makeService();
    // 先在服务里跑完一卷：进对话框前它已经是表里的 done 行（历史）。
    await s.service.enqueueMokuroVolume(
      seriesName: _library.first.name,
      volumeName: _library.first.volumes.first.name,
    );
    await pumpUntil(tester, () => s.downloaders.isNotEmpty);
    s.downloaders[0].ctrl.add(const MokuroMoeVolumeDownloadEvent(
      stage: MokuroMoeDownloadStage.done,
      bookKey: 'historical-volume',
    ));
    await s.downloaders[0].ctrl.close();
    final String historicalId =
        _jobId(_library.first.name, _library.first.volumes.first.name);
    await pumpUntil(
      tester,
      () async =>
          (await db.getMangaDownloadJob(historicalId))!.status ==
          MangaDownloadJobStatus.done,
    );

    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    FushiToast.navigatorKey = navKey;
    await tester.pumpWidget(
      ProviderScope(
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navKey,
            home: Scaffold(
              body: MokuroMoeCatalogDialog(
                db: db,
                clientOverride: _FakeClient(_library),
                downloadsOverride: s.service,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 完成 toast 只在 series 阶段监听任务表时才可能发；进系列时表里的 done
    // 行必须先被当历史吞掉。
    await tester.tap(find.text(_library.first.name));
    await tester.pumpAndSettle();
    expect(find.text(t.manga_ocr_wizard_done), findsNothing);

    // 再入队另一卷：表变更触发重扫，历史 done 行不能被当成这次的完成。
    await s.service.enqueueMokuroVolume(
      seriesName: _library.first.name,
      volumeName: _library.first.volumes.last.name,
    );
    await pumpUntil(tester, () => s.downloaders.length == 2, reason: '第二卷起跑');
    await tester.pump(const Duration(milliseconds: 250));
    expect(
      find.text(t.manga_ocr_wizard_done),
      findsNothing,
      reason:
          'Reopening must seed historical done tasks before listening to the shared queue.',
    );

    // 对照：这次真正完成的卷要 toast——证明上面的 findsNothing 不是空壳。
    s.downloaders[1].ctrl.add(const MokuroMoeVolumeDownloadEvent(
      stage: MokuroMoeDownloadStage.done,
      bookKey: 'new-volume',
    ));
    await s.downloaders[1].ctrl.close();
    await pumpUntil(
      tester,
      () => find.text(t.manga_ocr_wizard_done).evaluate().isNotEmpty,
      reason: '新完成的卷要 toast',
    );
    expect(find.text(t.manga_ocr_wizard_done), findsOneWidget);
    // 让 toast 的自动消失定时器走完，别把 pending Timer 留到测试结束。
    await tester.pump(const Duration(seconds: 5));
    expect(find.text(t.manga_ocr_wizard_done), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('「下载全部」把系列里所有未在库的卷全部入队', (WidgetTester tester) async {
    final s = await makeService();
    await tester.pumpWidget(wrap(MokuroMoeCatalogDialog(
      db: db,
      clientOverride: _FakeClient(_library),
      downloadsOverride: s.service,
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('よつばと!'));
    await tester.pumpAndSettle();

    final TextButton downloadAll = tester.widget<TextButton>(
      find.widgetWithText(TextButton, t.manga_online_download_all),
    );
    expect(downloadAll.onPressed, isNotNull, reason: '还有可选的卷就可用');
    await tester.tap(find.text(t.manga_online_download_all));
    await pumpUntil(
      tester,
      () async =>
          (await db.listMangaDownloadJobs()).length ==
          _library.first.volumes.length,
      reason: '每卷一行',
    );
    final List<MangaDownloadJobRow> rows = await db.listMangaDownloadJobs();
    expect(
      rows.map((MangaDownloadJobRow r) => r.chapterKey).toSet(),
      _library.first.volumes.map((MokuroMoeVolume v) => v.name).toSet(),
    );
    expect(
      rows.every(
          (MangaDownloadJobRow r) => r.bookKey == mokuroMoeBookKey('よつばと!')),
      isTrue,
    );
    // 全部都在队里了 → 「下载全部」变禁用。
    await tester.pump();
    expect(
      tester
          .widget<TextButton>(
            find.widgetWithText(TextButton, t.manga_online_download_all),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('全选复选框勾上后「下载所选」可用，再点一次全不选', (WidgetTester tester) async {
    final s = await makeService();
    await tester.pumpWidget(wrap(MokuroMoeCatalogDialog(
      db: db,
      clientOverride: _FakeClient(_library),
      downloadsOverride: s.service,
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('よつばと!'));
    await tester.pumpAndSettle();

    final Finder selectAll =
        find.byKey(const ValueKey<String>('mokuro_moe_select_all'));
    expect(selectAll, findsOneWidget);
    expect(tester.widget<Checkbox>(selectAll).value, isFalse);
    TextButton downloadSelected() => tester.widget<TextButton>(
          find.widgetWithText(TextButton, t.manga_online_download_selected),
        );
    expect(downloadSelected().onPressed, isNull);

    await tester.tap(selectAll);
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(selectAll).value, isTrue);
    expect(downloadSelected().onPressed, isNotNull);

    await tester.tap(selectAll);
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(selectAll).value, isFalse);
    expect(downloadSelected().onPressed, isNull);
  });
}
