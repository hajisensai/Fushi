import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart'
    show DatabaseSnapshotDeletionResult, deleteDatabaseSnapshotFiles;
import 'package:path/path.dart' as p;

import 'package:fushi/src/pages/implementations/storage_usage_view.dart';
import 'package:fushi/src/storage/storage_usage_service.dart';
import 'package:fushi/utils.dart';

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
    Future<List<StorageBookRef>> Function()? books,
    Future<String?> Function(String bookKey)? deleteBook,
    Future<String?> Function(String uid)? deleteSrtBook,
    Future<DatabaseSnapshotDeletionResult> Function()? deleteDatabaseSnapshots,
    Future<int> Function()? anime4kBytes,
    Future<List<String>> Function()? anime4kDelete,
  }) {
    return StorageUsageView(
      service: service,
      booksProvider: books ?? () async => const <StorageBookRef>[],
      dictionaryNamesProvider: () async => const <String>[],
      deleteBook: deleteBook ?? (String _) async => null,
      deleteSrtBook: deleteSrtBook ?? (String _) async => null,
      deleteDictionary: (String _) async => null,
      deleteDatabaseSnapshots: deleteDatabaseSnapshots ??
          () async => const DatabaseSnapshotDeletionResult(
                deleted: <String>[],
                failures: <String, String>{},
              ),
      anime4kBytesProvider: anime4kBytes ?? () async => 0,
      anime4kDelete: anime4kDelete ?? () async => const <String>[],
    );
  }

  testWidgets('扫描完成后展示类目行与总量', (WidgetTester tester) async {
    writeFile(p.join(docs.path, 'fushi_books', 'keyA', 'ch1.html'), 2048);

    await tester.pumpWidget(wrap(view(
      service: service(),
      books: () async => <StorageBookRef>[
        StorageBookRef(
          id: 'keyA',
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
      books: () async => <StorageBookRef>[
        StorageBookRef(
          id: 'keyA',
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

  testWidgets('BUG-1893：standalone 字幕书条目的删除走 deleteSrtBook，不走 deleteBook',
      (WidgetTester tester) async {
    // 这类书 bookKey 恒空、没有 EpubBooks 行：走 deleteBook 必然找不到行。
    final String audioDir = p.join(docs.path, 'audiobooks', 'srt-uid-1');
    writeFile(p.join(audioDir, 'ch1.mp3'), 4096);
    final List<String> deletedBooks = <String>[];
    final List<String> deletedSrt = <String>[];

    await tester.pumpWidget(wrap(view(
      service: service(),
      books: () async => <StorageBookRef>[
        StorageBookRef(
          id: 'srt-uid-1',
          title: 'ひとりぼっち',
          extractDir: '',
          audioPaths: <String>[audioDir],
          kind: StorageEntryKind.srtBook,
        ),
      ],
      deleteBook: (String bookKey) async {
        deletedBooks.add(bookKey);
        return null;
      },
      deleteSrtBook: (String uid) async {
        deletedSrt.add(uid);
        Directory(audioDir).deleteSync(recursive: true);
        return null;
      },
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text(t.storage_category_books));
    await tester.pumpAndSettle();
    expect(find.text('ひとりぼっち'), findsOneWidget);
    // 音频大小真的显示出来了（旧实现这里是 0 B）。
    expect(find.text('4.0 KB'), findsWidgets);

    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, t.dialog_delete));
    for (int i = 0; i < 20; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      if (deletedSrt.isNotEmpty &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty) {
        break;
      }
    }

    expect(deletedSrt, <String>['srt-uid-1']);
    expect(deletedBooks, isEmpty);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('BUG-1870：数据库快照残留聚成一条带文件数的可删条目，确认后走注入原语并重扫',
      (WidgetTester tester) async {
    writeFile(p.join(support.path, 'fushi.db'), 1000);
    writeFile(p.join(support.path, 'fushi.db.corrupt-bak-1.db'), 7);
    writeFile(p.join(support.path, 'hibiki.db.bak.v16.1780592923530'), 3);
    writeFile(p.join(support.path, 'hibiki.db-wal.bak.v20.1'), 1);
    int deleteCalls = 0;

    await tester.pumpWidget(wrap(view(
      service: service(),
      deleteDatabaseSnapshots: () async {
        deleteCalls++;
        return deleteDatabaseSnapshotFiles(support);
      },
    )));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text(t.storage_category_database));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.storage_category_database));
    await tester.pumpAndSettle();

    // 原始文件名不再逐条铺开，取而代之的是一条带文件数的翻译标题。
    final String title = t.storage_entry_database_snapshots_label(n: 3);
    expect(find.text(title), findsOneWidget);
    expect(find.text('support/fushi.db.corrupt-bak-1.db'), findsNothing);
    expect(find.text('support/hibiki.db.bak.v16.1780592923530'), findsNothing);
    // 活库仍只读单列。
    expect(find.text('support/fushi.db'), findsOneWidget);
    // 整个类目里只有快照条目有删除按钮。
    expect(find.byTooltip(t.dialog_delete), findsOneWidget);

    // 数据库类目在页面底部，展开后的条目行在滚动视口外：先滚进来再点，
    // 否则 tap 落空、确认框不弹（widget 在树上但不在屏上）。
    await tester.ensureVisible(find.byTooltip(t.dialog_delete));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(t.dialog_delete));
    await tester.pumpAndSettle();
    expect(find.text(t.storage_entry_delete_confirm_title(name: title)),
        findsOneWidget);
    expect(find.text(t.storage_entry_delete_database_snapshots_confirm_body),
        findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, t.dialog_delete));
    for (int i = 0; i < 20; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      if (deleteCalls > 0 &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty) {
        break;
      }
    }

    expect(deleteCalls, 1);
    // 真删了快照、活库一字节没动。
    expect(File(p.join(support.path, 'fushi.db.corrupt-bak-1.db')).existsSync(),
        isFalse);
    expect(File(p.join(support.path, 'fushi.db')).lengthSync(), 1000);
    // 重扫后聚合条目消失（已无快照），活库条目仍在。
    expect(find.text(title), findsNothing);
    expect(find.text('support/fushi.db'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('BUG-1870 审查：部分快照删不掉时报出失败原因，但成功的那些照样重扫掉',
      (WidgetTester tester) async {
    writeFile(p.join(support.path, 'fushi.db'), 1000);
    writeFile(p.join(support.path, 'fushi.db.corrupt-bak-1.db'), 7);
    writeFile(p.join(support.path, 'fushi.db.corrupt-bak-2.db'), 3);
    final String stuckPath = p.join(support.path, 'fushi.db.corrupt-bak-2.db');

    await tester.pumpWidget(wrap(view(
      service: service(),
      // 真原语删掉能删的，再手工塞一条失败——模拟 Windows 上被占用的那一个。
      deleteDatabaseSnapshots: () async {
        File(p.join(support.path, 'fushi.db.corrupt-bak-1.db')).deleteSync();
        return DatabaseSnapshotDeletionResult(
          deleted: <String>[p.join(support.path, 'fushi.db.corrupt-bak-1.db')],
          failures: <String, String>{stuckPath: '另一个程序正在使用此文件'},
        );
      },
    )));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text(t.storage_category_database));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.storage_category_database));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byTooltip(t.dialog_delete));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(t.dialog_delete));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, t.dialog_delete));
    for (int i = 0; i < 20; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      if (!File(p.join(support.path, 'fushi.db.corrupt-bak-1.db'))
              .existsSync() &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty) {
        break;
      }
    }

    // 关键：删得掉的真删了，且页面重扫回到「还剩 1 个」——旧实现在失败分支
    // 直接跳过重扫，数字会停在删除前的 2 个。
    expect(File(p.join(support.path, 'fushi.db.corrupt-bak-1.db')).existsSync(),
        isFalse);
    expect(File(stuckPath).existsSync(), isTrue);
    expect(find.text(t.storage_entry_database_snapshots_label(n: 1)),
        findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('非书籍类目也能展开：明细列出磁盘子项，且不给删除按钮', (WidgetTester tester) async {
    writeFile(p.join(docs.path, 'custom_fonts', 'NotoSerif.ttf'), 4096);

    await tester.pumpWidget(wrap(view(service: service())));
    await tester.pumpAndSettle();

    // 展开前明细不在树上。
    expect(find.text('custom_fonts/NotoSerif.ttf'), findsNothing);

    await tester.ensureVisible(find.text(t.storage_category_custom_fonts));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.storage_category_custom_fonts));
    await tester.pumpAndSettle();

    expect(find.text('custom_fonts/NotoSerif.ttf'), findsOneWidget);
    // 通用明细接不上域内删除原语，一律只读——不得出现删除按钮。
    expect(find.byTooltip(t.dialog_delete), findsNothing);
  });

  testWidgets('可选模块区已移除：OCR 模型只剩占用行，没有下载/删除按钮', (WidgetTester tester) async {
    writeFile(
        p.join(support.path, kOcrModelsSupportChild, 'manga', 'a.onnx'), 300);

    await tester.pumpWidget(wrap(view(service: service())));
    await tester.pumpAndSettle();

    // 类目行还在（如实显示占用），但下载/删除入口已回归漫画 OCR 设置区。
    expect(find.text(t.storage_category_ocr_models), findsOneWidget);
    expect(find.byTooltip(t.manga_ocr_delete), findsNothing);
    expect(find.byTooltip(t.manga_ocr_download), findsNothing);
  });

  testWidgets('着色器类目行挂 Anime4K 删除：确认后走注入的删除原语并重扫', (WidgetTester tester) async {
    writeFile(p.join(docs.path, 'mpv_shaders', 'Anime4K_Clamp.glsl'), 512);
    int deleteCalls = 0;

    await tester.pumpWidget(wrap(view(
      service: service(),
      anime4kBytes: () async => deleteCalls == 0 ? 512 : 0,
      anime4kDelete: () async {
        deleteCalls++;
        File(p.join(docs.path, 'mpv_shaders', 'Anime4K_Clamp.glsl'))
            .deleteSync();
        return const <String>['Anime4K_Clamp.glsl'];
      },
    )));
    await tester.pumpAndSettle();

    final Finder deleteButton =
        find.byTooltip(t.storage_shaders_delete_anime4k);
    await tester.ensureVisible(deleteButton);
    await tester.pumpAndSettle();
    await tester.tap(deleteButton);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, t.dialog_delete));
    for (int i = 0; i < 20; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      if (deleteCalls > 0 &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty) {
        break;
      }
    }

    expect(deleteCalls, 1);
    // 删完预设后按钮自行消失（_anime4kBytes 归零）。
    expect(find.byTooltip(t.storage_shaders_delete_anime4k), findsNothing);
  });

  testWidgets('无 Anime4K 预设时着色器行不给删除按钮', (WidgetTester tester) async {
    writeFile(p.join(docs.path, 'mpv_shaders', 'mine.glsl'), 128);

    await tester.pumpWidget(wrap(view(service: service())));
    await tester.pumpAndSettle();

    expect(find.text(t.storage_category_shaders), findsOneWidget);
    expect(find.byTooltip(t.storage_shaders_delete_anime4k), findsNothing);
  });
}
