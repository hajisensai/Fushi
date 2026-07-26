import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/media/manga/online/mokuro_moe_catalog_dialog.dart';
import 'package:hibiki/src/media/manga/online/mokuro_moe_client.dart';
import 'package:hibiki/src/media/manga/online/mokuro_moe_volume_downloader.dart';
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

  /// 照 `manga_import_dialog_test.dart` 的 TranslationProvider 壳（+ ProviderScope，
  /// 对话框是 ConsumerStatefulWidget；clientOverride 非 null 时不会触达 appProvider）。
  Widget wrap(Widget child) {
    return ProviderScope(
      child: TranslationProvider(
        child: MaterialApp(home: Scaffold(body: child)),
      ),
    );
  }

  testWidgets('browse：目录加载后渲染系列，搜索大小写不敏感过滤', (WidgetTester tester) async {
    await tester.pumpWidget(wrap(MokuroMoeCatalogDialog(
      db: db,
      clientOverride: _FakeClient(_library),
    )));
    await tester.pumpAndSettle();

    expect(find.text('よつばと!'), findsOneWidget);
    expect(find.text('ヨコハマ買い出し紀行'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'よつばと');
    await tester.pumpAndSettle();
    expect(find.text('よつばと!'), findsOneWidget);
    expect(find.text('ヨコハマ買い出し紀行'), findsNothing);
  });

  testWidgets('browse：加载失败显示错误 + 重试按钮，重试后恢复', (WidgetTester tester) async {
    final _FakeClient client = _FakeClient(_library)
      ..libraryError = Exception('boom');
    await tester.pumpWidget(wrap(MokuroMoeCatalogDialog(
      db: db,
      clientOverride: client,
    )));
    await tester.pumpAndSettle();

    expect(find.textContaining(t.manga_online_load_failed), findsOneWidget);

    client.libraryError = null;
    await tester.tap(find.text(t.retry));
    await tester.pumpAndSettle();
    expect(find.text('よつばと!'), findsOneWidget);
  });

  testWidgets('series → 选卷 → 下载：进度渲染、完成标记 ✓、关闭回传导入数',
      (WidgetTester tester) async {
    final StreamController<MokuroMoeVolumeDownloadEvent> events =
        StreamController<MokuroMoeVolumeDownloadEvent>();
    final List<(String, String)> runnerCalls = <(String, String)>[];
    int? popResult;

    await tester.pumpWidget(wrap(Builder(
      builder: (BuildContext context) => Center(
        child: ElevatedButton(
          onPressed: () async {
            popResult = await showDialog<int>(
              context: context,
              builder: (_) => MokuroMoeCatalogDialog(
                db: db,
                clientOverride: _FakeClient(_library),
                runnerOverride: (
                    {required String seriesName, required String volumeName}) {
                  runnerCalls.add((seriesName, volumeName));
                  return events.stream;
                },
              ),
            );
          },
          child: const Text('open'),
        ),
      ),
    )));
    await tester.tap(find.text('open'));
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

    // 选第 1 卷 → 下载。
    await tester.tap(find.text('よつばと! 第01巻'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.manga_online_download_selected));
    await tester.pump();
    expect(runnerCalls.single, ('よつばと!', 'よつばと! 第01巻'));

    // CBZ 字节进度 → 进度条 + 阶段文案。
    events.add(const MokuroMoeVolumeDownloadEvent(
      stage: MokuroMoeDownloadStage.downloadingCbz,
      receivedBytes: 512 * 1024,
      totalBytes: 1024 * 1024,
    ));
    await tester.pump();
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    // 阶段文案出现在进度面板 + 当前卷 subtitle（两处一致）。
    expect(find.textContaining(t.manga_online_stage_cbz), findsWidgets);

    // 完成 → 回 series 阶段，该卷标 ✓（不可再选），无复选框残留选中。
    events.add(const MokuroMoeVolumeDownloadEvent(
      stage: MokuroMoeDownloadStage.done,
      bookKey: 'yotsubato-01',
    ));
    await events.close();
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.text(t.manga_online_downloaded), findsOneWidget);

    // 关闭回传本次成功导入卷数。
    await tester.tap(find.text(t.dialog_close));
    await tester.pumpAndSettle();
    expect(popResult, 1);
  });
}
