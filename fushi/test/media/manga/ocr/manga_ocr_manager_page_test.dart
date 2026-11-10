import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/manga_ocr_background_job.dart';
import 'package:fushi/src/media/manga/manga_ocr_provider.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_job_registry.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_manager_page.dart';

/// 反馈 iuv4-jWC8S：漫画 OCR 任务管理页——列出运行中 / 排队 / 已暂停的任务，
/// 可逐项或批量暂停、继续。页面不存状态，全部读注册表。
class _FakeSource {
  final StreamController<MangaOcrBackgroundEvent> controller =
      StreamController<MangaOcrBackgroundEvent>();

  MangaOcrBackgroundJob job(String bookKey, String dir, String title) =>
      MangaOcrBackgroundJob(
        bookKey: bookKey,
        managedDirectory: dir,
        engine: MangaOcrEngineId.localOnnx,
        events: controller.stream,
        title: title,
        resume: () => _FakeSource().job(bookKey, dir, title),
      );
}

Widget _wrap(MangaOcrJobRegistry registry) => ProviderScope(
  overrides: [mangaOcrJobRegistryProvider.overrideWithValue(registry)],
  child: TranslationProvider(
    child: MaterialApp(
      home: MangaOcrManagerPage(
        bookTitle: (String bookKey) async => 'Book $bookKey',
        engineLabel: (MangaOcrEngineId engine) => 'engine',
      ),
    ),
  ),
);

void main() {
  testWidgets('没有任务时显示空态', (WidgetTester tester) async {
    final MangaOcrJobRegistry registry = MangaOcrJobRegistry();
    await tester.pumpWidget(_wrap(registry));
    await tester.pumpAndSettle();
    expect(find.text(t.manga_ocr_manager_empty), findsOneWidget);
  });

  testWidgets('逐项暂停排队中的章、再逐项继续；全部暂停 / 全部继续', (WidgetTester tester) async {
    final MangaOcrJobRegistry registry = MangaOcrJobRegistry();
    final _FakeSource first = _FakeSource();
    final _FakeSource second = _FakeSource();
    await registry.enqueue(
      job: first.job('b1', '/m/b1/c1', 'Ch 1'),
      mangaJsonPath: '/m/b1/c1/manga.json',
    );
    unawaited(
      registry.enqueue(
        job: second.job('b1', '/m/b1/c2', 'Ch 2'),
        mangaJsonPath: '/m/b1/c2/manga.json',
      ),
    );
    first.controller.add(
      const MangaOcrBackgroundEvent.progress(pagesDone: 2, pagesTotal: 8),
    );

    await tester.pumpWidget(_wrap(registry));
    await tester.pumpAndSettle();

    expect(find.text('Book b1'), findsOneWidget, reason: '按书分组，组头是书名');
    expect(find.text('Ch 1'), findsOneWidget);
    expect(find.text('Ch 2'), findsOneWidget);
    expect(
      find.text(
        '${t.manga_ocr_manager_status_running(done: 2, total: 8)} · engine',
      ),
      findsOneWidget,
    );
    expect(
      find.text('${t.manga_ocr_manager_status_queued} · engine'),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('manga_ocr_manager_pause_b1|/m/b1/c2')),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('${t.manga_ocr_manager_status_paused} · engine'),
      findsOneWidget,
    );
    expect(registry.queuedDirectories('b1'), isEmpty);

    await tester.tap(
      find.byKey(
        const ValueKey<String>('manga_ocr_manager_resume_b1|/m/b1/c2'),
      ),
    );
    await tester.pumpAndSettle();
    expect(registry.queuedDirectories('b1'), <String>['/m/b1/c2']);

    // 全部暂停：运行中的 c1 与排队的 c2 都停下。
    await tester.tap(
      find.byKey(const ValueKey<String>('manga_ocr_manager_pause_all')),
    );
    await tester.pumpAndSettle();
    expect(
      registry.entries().map((MangaOcrJobEntry e) => e.status),
      everyElement(MangaOcrJobStatus.paused),
    );
    expect(
      find.text(
        '${t.manga_ocr_manager_status_paused_at(done: 2, total: 8)} · engine',
      ),
      findsOneWidget,
      reason: '运行中暂停的保留暂停那一刻的进度',
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('manga_ocr_manager_resume_all')),
    );
    await tester.pumpAndSettle();
    expect(
      registry.entries().where(
        (MangaOcrJobEntry e) => e.status == MangaOcrJobStatus.paused,
      ),
      isEmpty,
    );
    await registry.cancelAll();
    await tester.pumpAndSettle();
  });
}
