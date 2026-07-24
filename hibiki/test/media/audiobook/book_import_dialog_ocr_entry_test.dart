/// 漫画 P3：导入书对话框「OCR 导入漫画」入口 gating。
///
/// - 桌面：恒显示（内置 OCR / 外部 mokuro CLI 都是桌面工具）。
/// - 移动端（ocrEntryDesktopOverride=false 模拟）：默认隐藏；异步探测到具备漫画
///   OCR 能力的已配对 host（capabilities.mangaOcr.supported）后亮出入口；探测
///   不到（未配对 / 老 host 无字段）保持隐藏——版本 skew 零破坏。
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/media/audiobook/book_import_dialog.dart';
import 'package:hibiki/src/sync/interconnect_manga_ocr_client.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';

class _FakeRemoteRunner implements MangaOcrRemoteRunner {
  _FakeRemoteRunner({this.target});

  final MangaOcrRemoteTarget? target;
  int probeCalls = 0;

  @override
  Future<MangaOcrRemoteTarget?> probe() async {
    probeCalls += 1;
    return target;
  }

  @override
  Stream<MangaOcrRemoteEvent> run({
    required MangaOcrRemoteTarget target,
    required String imageDirPath,
    String? volumeTitle,
  }) =>
      const Stream<MangaOcrRemoteEvent>.empty();
}

const MangaOcrRemoteTarget _capableTarget = MangaOcrRemoteTarget(
  baseUrl: 'http://192.168.1.2:1234',
  capability: MangaOcrRemoteCapability(supported: true, modelsReady: true),
);

void main() {
  late HibikiDatabase db;

  setUp(() {
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> pumpDialog(
    WidgetTester tester, {
    required bool desktop,
    required _FakeRemoteRunner runner,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: BookImportDialog(
                repo: SrtBookRepository(db),
                audiobookRepo: AudiobookRepository(db),
                db: db,
                mangaOcrRemoteRunner: runner,
                ocrEntryDesktopOverride: desktop,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('desktop: OCR entry always visible, no probe needed',
      (WidgetTester tester) async {
    final _FakeRemoteRunner runner = _FakeRemoteRunner(target: null);
    await pumpDialog(tester, desktop: true, runner: runner);
    expect(find.text(t.manga_ocr_wizard_title), findsOneWidget);
    expect(runner.probeCalls, 0, reason: '桌面入口不依赖探测');
  });

  testWidgets('mobile: entry appears once a capable paired host is probed',
      (WidgetTester tester) async {
    final _FakeRemoteRunner runner = _FakeRemoteRunner(target: _capableTarget);
    await pumpDialog(tester, desktop: false, runner: runner);
    expect(runner.probeCalls, 1);
    expect(find.text(t.manga_ocr_wizard_title), findsOneWidget);
  });

  testWidgets('mobile: entry stays hidden without a capable host',
      (WidgetTester tester) async {
    final _FakeRemoteRunner runner = _FakeRemoteRunner(target: null);
    await pumpDialog(tester, desktop: false, runner: runner);
    expect(runner.probeCalls, 1);
    expect(find.text(t.manga_ocr_wizard_title), findsNothing);
  });
}
