import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/ocr/manga_ocr_service.dart';
import 'package:fushi/src/pages/implementations/storage_usage_view.dart';
import 'package:fushi/src/storage/storage_usage_service.dart';
import 'package:fushi/utils.dart';

/// Fake OCR 服务：状态可编程，删除翻转状态。
class _FakeOcrService implements MangaOcrService {
  _FakeOcrService({this.ready = true});

  bool ready;
  int deleteCalls = 0;

  @override
  bool get isSupportedPlatform => true;

  @override
  Future<MangaOcrModelStatus> modelStatus() async => MangaOcrModelStatus(
        detectorReady: ready,
        recognizerReady: ready,
        downloadedBytes: ready ? 40 * 1024 * 1024 : 0,
        totalBytes: 40 * 1024 * 1024,
      );

  @override
  Stream<MangaOcrDownloadEvent> downloadModels() async* {
    ready = true;
    yield const MangaOcrDownloadEvent(
      fileName: 'detector.onnx',
      receivedBytes: 20,
      totalBytes: 20,
      done: true,
    );
  }

  @override
  Future<void> deleteModels() async {
    deleteCalls++;
    ready = false;
  }

  @override
  Stream<MangaOcrVolumeEvent> ocrFolder({
    required String imageDirPath,
    String? volumeTitle,
  }) =>
      const Stream<MangaOcrVolumeEvent>.empty();
}

void main() {
  late Directory tempRoot;
  late Directory docs;
  late Directory support;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('storage_view_test');
    docs = Directory(p.join(tempRoot.path, 'docs'))..createSync();
    support = Directory(p.join(tempRoot.path, 'support'))..createSync();
  });

  tearDown(() {
    try {
      tempRoot.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 句柄延迟释放：留给系统临时目录清理。
    }
  });

  void writeFile(String path, int bytes) {
    final File f = File(path);
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(List<int>.filled(bytes, 0x61));
  }

  /// FakeAsync 区里真 isolate 永不完成：注同步执行版 runner。
  StorageUsageService service() => StorageUsageService(
        documentsRoot: () async => docs,
        supportRoot: () async => support,
        isolateRunner: <R>(R Function() computation) async => computation(),
      );

  Widget wrap(Widget child) {
    return ProviderScope(
      child: TranslationProvider(
        child: MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: child)),
        ),
      ),
    );
  }

  StorageUsageView view({
    required StorageUsageService service,
    required _FakeOcrService ocr,
    Future<List<StorageBookRef>> Function()? books,
    Future<String?> Function(String bookKey)? deleteBook,
  }) {
    return StorageUsageView(
      service: service,
      ocrService: ocr,
      booksProvider: books ?? () async => const <StorageBookRef>[],
      dictionaryNamesProvider: () async => const <String>[],
      deleteBook: deleteBook ?? (String _) async => null,
      deleteDictionary: (String _) async => null,
      anime4kBytesProvider: () async => 0,
      anime4kDelete: () async => const <String>[],
    );
  }

  testWidgets('扫描完成后展示类目行与总量', (WidgetTester tester) async {
    writeFile(p.join(docs.path, 'fushi_books', 'keyA', 'ch1.html'), 2048);

    await tester.pumpWidget(wrap(view(
      service: service(),
      ocr: _FakeOcrService(),
      books: () async => <StorageBookRef>[
        StorageBookRef(
          bookKey: 'keyA',
          title: '吾輩は猫である',
          extractDir: p.join(docs.path, 'fushi_books', 'keyA'),
        ),
      ],
    )));
    await tester.pumpAndSettle();

    expect(find.text(t.storage_category_books), findsOneWidget);
    expect(find.text(t.storage_category_dictionaries), findsOneWidget);
    expect(find.text(t.storage_overview_total), findsOneWidget);
    // 书籍类目 2 KB（类目行 trailing）。
    expect(find.text('2.0 KB'), findsWidgets);
  });

  testWidgets('展开书籍类目并删除单条：确认后走注入回调并重扫', (WidgetTester tester) async {
    final String bookDir = p.join(docs.path, 'fushi_books', 'keyA');
    writeFile(p.join(bookDir, 'ch1.html'), 1024);
    final List<String> deleted = <String>[];

    await tester.pumpWidget(wrap(view(
      service: service(),
      ocr: _FakeOcrService(),
      books: () async => <StorageBookRef>[
        StorageBookRef(
          bookKey: 'keyA',
          title: '吾輩は猫である',
          extractDir: bookDir,
        ),
      ],
      deleteBook: (String bookKey) async {
        deleted.add(bookKey);
        Directory(bookDir).deleteSync(recursive: true);
        return null;
      },
    )));
    await tester.pumpAndSettle();

    // 展开书籍类目 → 出现书条目。
    await tester.tap(find.text(t.storage_category_books));
    await tester.pumpAndSettle();
    expect(find.text('吾輩は猫である'), findsOneWidget);

    // 点条目删除 → 确认弹窗 → 确认。
    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();
    expect(
      find.text(t.storage_entry_delete_confirm_title(name: '吾輩は猫である')),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, t.dialog_delete));
    // 删除后触发重扫：必须经 runAsync 用真实事件循环驱动——FakeAsync 区里
    // 第二次 listen 的 async* generator 不会启动（插桩实测：listen 已挂上、
    // generator 首行永不执行；同一路径首次扫描正常、runAsync 下完整跑通），
    // 是测试 harness 调度怪癖，产品运行时是真实事件循环不受影响。
    for (int i = 0; i < 20; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      if (deleted.isNotEmpty &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty) {
        break;
      }
    }

    expect(deleted, <String>['keyA']);
    // 重扫必须自然结束（进度圈消失）——转不停就是 _scanning 永挂的产品 bug。
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('OCR 模型行：已安装显示删除，确认后调 service.deleteModels',
      (WidgetTester tester) async {
    final _FakeOcrService ocr = _FakeOcrService(ready: true);
    await tester.pumpWidget(wrap(view(service: service(), ocr: ocr)));
    await tester.pumpAndSettle();

    expect(find.text(t.storage_category_ocr_models), findsWidgets);
    // 模块区在长类目列表下方、默认视口外：先滚到可见再点。
    await tester.ensureVisible(find.byTooltip(t.manga_ocr_delete));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(t.manga_ocr_delete));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, t.dialog_delete));
    for (int i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (ocr.deleteCalls > 0 &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty) {
        break;
      }
    }

    expect(ocr.deleteCalls, 1);
    expect(ocr.ready, isFalse);
  });

  testWidgets('OCR 模型行：未安装显示下载，点击后走下载流并翻绿', (WidgetTester tester) async {
    final _FakeOcrService ocr = _FakeOcrService(ready: false);
    await tester.pumpWidget(wrap(view(service: service(), ocr: ocr)));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byTooltip(t.manga_ocr_download));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(t.manga_ocr_download));
    for (int i = 0; i < 50 && !ocr.ready; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 200));

    expect(ocr.ready, isTrue);
  });
}
