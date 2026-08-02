/// 漫画 P3：OCR 向导「已配对主机」远程引擎的 widget 测试。
///
/// - 显隐 gating：仅当 probe 探测到具备能力的已配对 host 时显示远程选项；
///   无 host（老 host / 未配对）时不显示，且移动端形态（内置不支持 + 无外部
///   CLI）下引擎区显示「无可用引擎」、Run 禁用。
/// - 远程路径完成落库：上传/远端两阶段进度 → finished → importOverride 收到
///   manga.json 路径（external=false）→ 对话框 pop bookKey。
/// - 运行中取消：取消订阅（触发 host 侧清理）、不落库、回到 configure。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/media/manga/manga_ocr_wizard_dialog.dart';
import 'package:hibiki/src/media/manga/manga_ocr_wizard_engines.dart';
import 'package:hibiki/src/ocr/manga_ocr_service.dart';
import 'package:hibiki/src/sync/interconnect_manga_ocr_client.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;

/// 移动端形态的内置服务：平台不支持（远程是唯一可用引擎）。
class _UnsupportedOcrService implements MangaOcrService {
  @override
  bool get isSupportedPlatform => false;

  @override
  Future<MangaOcrModelStatus> modelStatus() async => const MangaOcrModelStatus(
        detectorReady: false,
        recognizerReady: false,
        downloadedBytes: 0,
        totalBytes: 1,
      );

  @override
  Stream<MangaOcrDownloadEvent> downloadModels() =>
      const Stream<MangaOcrDownloadEvent>.empty();

  @override
  Future<void> deleteModels() async {}

  @override
  Stream<MangaOcrVolumeEvent> ocrFolder({
    required String imageDirPath,
    String? volumeTitle,
  }) =>
      const Stream<MangaOcrVolumeEvent>.empty();
}

class _FakeRemoteRunner implements MangaOcrRemoteRunner {
  _FakeRemoteRunner({this.target});

  final MangaOcrRemoteTarget? target;
  StreamController<MangaOcrRemoteEvent>? controller;
  bool runCancelled = false;
  String? lastImageDir;
  String? lastTitle;

  @override
  Future<MangaOcrRemoteTarget?> probe() async => target;

  @override
  Stream<MangaOcrRemoteEvent> run({
    required MangaOcrRemoteTarget target,
    required String imageDirPath,
    String? volumeTitle,
  }) {
    lastImageDir = imageDirPath;
    lastTitle = volumeTitle;
    final StreamController<MangaOcrRemoteEvent> c =
        StreamController<MangaOcrRemoteEvent>();
    c.onCancel = () => runCancelled = true;
    controller = c;
    return c.stream;
  }
}

const MangaOcrRemoteTarget _capableTarget = MangaOcrRemoteTarget(
  baseUrl: 'http://192.168.1.2:1234',
  capability: MangaOcrRemoteCapability(supported: true, modelsReady: true),
);

void main() {
  late HibikiDatabase db;
  late Directory imageDir;

  setUp(() {
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    imageDir = Directory.systemTemp.createTempSync('manga_ocr_remote_wiz');
    File(p.join(imageDir.path, 'p001.jpg')).writeAsBytesSync(<int>[1, 2, 3]);
  });

  tearDown(() async {
    await db.close();
    if (imageDir.existsSync()) imageDir.deleteSync(recursive: true);
  });

  Future<String? Function()> pumpWizard(
    WidgetTester tester, {
    required _FakeRemoteRunner remote,
    MangaOcrImportRunner? importOverride,
  }) async {
    String? popped;
    final Widget app = ProviderScope(
      child: TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext ctx) => ElevatedButton(
                onPressed: () async {
                  popped = await showDialog<String>(
                    context: ctx,
                    builder: (_) => MangaOcrWizardDialog(
                      engines: MangaOcrWizardEngines(
                        service: _UnsupportedOcrService(),
                        remoteRunner: remote,
                      ),
                      db: db,
                      initialImageDir: imageDir.path,
                      importOverride: importOverride,
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(app);
    return () => popped;
  }

  testWidgets(
      'capable host: remote is default engine, two-phase progress, '
      'import gets manga.json with external=false',
      (WidgetTester tester) async {
    final _FakeRemoteRunner remote = _FakeRemoteRunner(target: _capableTarget);
    String? importedPath;
    bool? importedExternal;
    final String? Function() poppedResult = await pumpWizard(
      tester,
      remote: remote,
      importOverride: ({
        required String path,
        required bool external,
        String? title,
      }) async {
        importedPath = path;
        importedExternal = external;
        return 'remotebook';
      },
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 远程可用 → Run 可点（唯一引擎，无需分段选择器）。
    final Finder runBtn =
        find.widgetWithText(FilledButton, t.manga_ocr_wizard_run);
    expect(tester.widget<FilledButton>(runBtn).onPressed, isNotNull);
    await tester.tap(runBtn);
    await tester.pump();
    expect(remote.lastImageDir, imageDir.path);

    // 上传阶段文案。
    remote.controller!
        .add(const MangaOcrRemoteEvent.uploading(done: 1, total: 3));
    await tester.pump();
    expect(find.text(t.manga_remote_ocr_uploading(done: 1, total: 3)),
        findsOneWidget);

    // 远端识别阶段文案（页进度）。
    remote.controller!
        .add(const MangaOcrRemoteEvent.running(done: 2, total: 3));
    await tester.pump();
    expect(find.text(t.manga_ocr_wizard_page_progress(done: 2, total: 3)),
        findsOneWidget);

    // finished → 落库 → pop。
    final String jsonPath =
        p.join(imageDir.path, 'manga_ocr_out', 'manga.json');
    remote.controller!
        .add(MangaOcrRemoteEvent.finished(mangaJsonPath: jsonPath));
    await tester.pumpAndSettle();
    expect(importedPath, jsonPath);
    expect(importedExternal, isFalse);
    expect(poppedResult(), 'remotebook');
  });

  testWidgets('no capable host: remote hidden, engines-none, Run disabled',
      (WidgetTester tester) async {
    final _FakeRemoteRunner remote = _FakeRemoteRunner(target: null);
    await pumpWizard(tester, remote: remote);
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text(t.manga_remote_ocr_engine), findsNothing);
    expect(find.text(t.manga_ocr_engine_none), findsOneWidget);
    final Finder runBtn =
        find.widgetWithText(FilledButton, t.manga_ocr_wizard_run);
    expect(tester.widget<FilledButton>(runBtn).onPressed, isNull);
  });

  testWidgets(
      'cancel during remote run: cancels stream (host cleanup), '
      'no import, back to configure', (WidgetTester tester) async {
    final _FakeRemoteRunner remote = _FakeRemoteRunner(target: _capableTarget);
    bool importCalled = false;
    await pumpWizard(
      tester,
      remote: remote,
      importOverride: ({
        required String path,
        required bool external,
        String? title,
      }) async {
        importCalled = true;
        return 'x';
      },
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, t.manga_ocr_wizard_run));
    await tester.pump();
    remote.controller!
        .add(const MangaOcrRemoteEvent.uploading(done: 1, total: 3));
    await tester.pump();

    await tester.tap(find.widgetWithText(TextButton, t.dialog_cancel));
    await tester.pumpAndSettle();

    expect(remote.runCancelled, isTrue, reason: '取消订阅须传导到 host 清理');
    expect(importCalled, isFalse);
    expect(find.widgetWithText(FilledButton, t.manga_ocr_wizard_run),
        findsOneWidget);
  });

  testWidgets('remote error maps to readable message and returns to configure',
      (WidgetTester tester) async {
    final _FakeRemoteRunner remote = _FakeRemoteRunner(target: _capableTarget);
    await pumpWizard(
      tester,
      remote: remote,
      importOverride: ({
        required String path,
        required bool external,
        String? title,
      }) async =>
          'unused',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, t.manga_ocr_wizard_run));
    await tester.pump();
    remote.controller!
        .addError(const MangaOcrRemoteException('models_not_ready'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining(t.manga_remote_ocr_not_ready),
      findsOneWidget,
    );
    // 回到 configure：Run 可再点。
    final Finder runBtn =
        find.widgetWithText(FilledButton, t.manga_ocr_wizard_run);
    expect(tester.widget<FilledButton>(runBtn).onPressed, isNotNull);
  });
}
