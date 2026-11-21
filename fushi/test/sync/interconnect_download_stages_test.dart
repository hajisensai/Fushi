import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/background_tasks_indicator.dart'
    show BackgroundTask;
import 'package:fushi/src/sync/interconnect_download_background_tasks.dart';
import 'package:fushi/src/sync/interconnect_download_manager.dart';

/// 从对端拉书的多阶段任务（正文 → 导入 → 有声书）：阶段、落地书键、后台任务映射。
///
/// 起因：此前整书任务只有一条 0..1（正文前半、有声书后半），EPUB 一落地书架就只剩
/// 不带数字的转圈；落地的本地书与任务的绑定存在书架页 State 上，页面一重建就丢；
/// 首页后台任务环也看不到互联下载。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  LocaleSettings.setLocale(AppLocale.en);

  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('fushi-ic-stages');
  });

  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  const List<InterconnectDownloadStage> bookStages =
      <InterconnectDownloadStage>[
        InterconnectDownloadStage.content,
        InterconnectDownloadStage.importing,
        InterconnectDownloadStage.audiobook,
      ];

  /// 起一条卡在 [gate] 上的三阶段书任务；返回 (任务 future, 任务键, 上报进度)。
  ({Future<void> running, String id, void Function(double) progress})
  startGatedBook(InterconnectDownloadManager manager, Completer<void> gate) {
    void Function(double)? report;
    final Future<void> running = manager.startBookDownload(
      downloadId: 'b1',
      title: 'Frieren 1',
      dest: File('${dir.path}/b.epub'),
      stages: bookStages,
      run: (File target, {void Function(double progress)? onProgress}) {
        report = onProgress;
        return gate.future;
      },
    );
    return (
      running: running,
      id: InterconnectDownloadManager.bookTaskId('b1'),
      progress: (double p) => report!(p),
    );
  }

  group('阶段', () {
    test('多阶段任务从第一个阶段起跑，进度是当前阶段的', () async {
      final InterconnectDownloadManager manager = InterconnectDownloadManager();
      addTearDown(manager.dispose);
      final Completer<void> gate = Completer<void>();
      final ({Future<void> running, String id, void Function(double) progress})
      t0 = startGatedBook(manager, gate);

      InterconnectDownloadTask task = manager.taskFor(t0.id)!;
      expect(task.stages, bookStages);
      expect(task.stage, InterconnectDownloadStage.content);
      expect(task.progress, isNull);

      t0.progress(0.38);
      expect(manager.badgeStateFor(t0.id)!.percent, 38);
      expect(
        manager.badgeStateFor(t0.id)!.stage,
        InterconnectDownloadStage.content,
      );

      manager.reportStage(t0.id, InterconnectDownloadStage.importing);
      task = manager.taskFor(t0.id)!;
      expect(task.stage, InterconnectDownloadStage.importing);
      expect(task.progress, isNull, reason: '新阶段从不定态开始，不沿用上一阶段的 38%');

      manager.reportStage(t0.id, InterconnectDownloadStage.audiobook);
      manager.reportBytes(t0.id, 144, 320);
      task = manager.taskFor(t0.id)!;
      expect(task.stage, InterconnectDownloadStage.audiobook);
      expect(task.receivedBytes, 144);
      expect(task.totalBytes, 320);
      expect(manager.badgeStateFor(t0.id)!.percent, 45);

      gate.complete();
      await t0.running;
    });

    test('阶段切换不经节流、立即通知', () async {
      final InterconnectDownloadManager manager = InterconnectDownloadManager();
      addTearDown(manager.dispose);
      final Completer<void> gate = Completer<void>();
      final ({Future<void> running, String id, void Function(double) progress})
      t0 = startGatedBook(manager, gate);
      int notified = 0;
      manager.addListener(() => notified++);
      manager.reportStage(t0.id, InterconnectDownloadStage.importing);
      expect(notified, 1);
      manager.reportStage(t0.id, InterconnectDownloadStage.importing);
      expect(notified, 1, reason: '已在该阶段：不重复通知');
      gate.complete();
      await t0.running;
    });

    test('不在阶段表里的阶段不认（没有有声书的书不会冒出有声书阶段）', () async {
      final InterconnectDownloadManager manager = InterconnectDownloadManager();
      addTearDown(manager.dispose);
      final Completer<void> gate = Completer<void>();
      final Future<void> running = manager.startBookDownload(
        downloadId: 'm1',
        title: 'Manga',
        dest: File('${dir.path}/m.zip'),
        stages: const <InterconnectDownloadStage>[
          InterconnectDownloadStage.content,
          InterconnectDownloadStage.importing,
        ],
        run: (File target, {void Function(double progress)? onProgress}) =>
            gate.future,
      );
      final String id = InterconnectDownloadManager.bookTaskId('m1');
      manager.reportStage(id, InterconnectDownloadStage.audiobook);
      expect(manager.taskFor(id)!.stage, InterconnectDownloadStage.content);
      gate.complete();
      await running;
    });
  });

  group('落地书键', () {
    test('报落地后按本地书键找得到同一条任务，任务结束后找不到', () async {
      final InterconnectDownloadManager manager = InterconnectDownloadManager();
      addTearDown(manager.dispose);
      final Completer<void> gate = Completer<void>();
      final ({Future<void> running, String id, void Function(double) progress})
      t0 = startGatedBook(manager, gate);

      expect(manager.landedBadgeStateFor('local-key'), isNull);
      expect(manager.landedBookKeysSignature, isEmpty);

      manager.reportLanded(t0.id, 'local-key');
      manager.reportStage(t0.id, InterconnectDownloadStage.audiobook);
      t0.progress(0.45);
      final InterconnectDownloadBadgeState? landed = manager
          .landedBadgeStateFor('local-key');
      expect(landed, isNotNull);
      expect(landed!.stage, InterconnectDownloadStage.audiobook);
      expect(landed.percent, 45);
      expect(manager.landedBookKeysSignature, 'local-key');

      gate.complete();
      await t0.running;
      expect(manager.landedBadgeStateFor('local-key'), isNull);
      expect(manager.landedBookKeysSignature, isEmpty);
    });

    test('只补有声书的任务起跑时就带着落地书键', () async {
      final InterconnectDownloadManager manager = InterconnectDownloadManager();
      addTearDown(manager.dispose);
      final Completer<void> gate = Completer<void>();
      final Future<void> running = manager.startBookDownload(
        downloadId: 'b2',
        title: 'Book 2',
        dest: File('${dir.path}/b2.fushiaudio'),
        landedBookKey: 'local-2',
        stages: const <InterconnectDownloadStage>[
          InterconnectDownloadStage.audiobook,
        ],
        run: (File target, {void Function(double progress)? onProgress}) =>
            gate.future,
      );
      expect(
        manager.landedBadgeStateFor('local-2')!.stage,
        InterconnectDownloadStage.audiobook,
      );
      gate.complete();
      await running;
    });
  });

  group('后台任务映射', () {
    test('只收在跑的任务；行写书名 + 阶段 + 百分比，明细列阶段清单与字节', () async {
      final InterconnectDownloadManager manager = InterconnectDownloadManager();
      addTearDown(manager.dispose);
      final Completer<void> gate = Completer<void>();
      final ({Future<void> running, String id, void Function(double) progress})
      t0 = startGatedBook(manager, gate);
      // 一条已完成的任务不进后台任务。
      await manager.startBookDownload(
        downloadId: 'done',
        title: 'Done',
        dest: File('${dir.path}/d.epub'),
        run:
            (
              File target, {
              void Function(double progress)? onProgress,
            }) async {},
      );

      manager.reportStage(t0.id, InterconnectDownloadStage.importing);
      manager.reportStage(t0.id, InterconnectDownloadStage.audiobook);
      manager.reportBytes(t0.id, 144 * 1024 * 1024, 320 * 1024 * 1024);

      final List<BackgroundTask> tasks = interconnectDownloadBackgroundTasks(
        manager,
      );
      expect(tasks, hasLength(1));
      final BackgroundTask task = tasks.single;
      expect(task.line, 'Frieren 1 · ${t.section_audiobook} 45%');
      expect(task.fraction, closeTo(0.45, 0.001));
      expect(task.detail, contains('${t.download_task_status_downloading} ✓'));
      expect(
        task.detail,
        contains('${t.interconnect_download_stage_importing} ✓'),
      );
      expect(task.detail, contains('${t.section_audiobook} 45%'));
      expect(task.detail, contains('/'), reason: '本阶段字节：已收 / 总量');
      expect(hasRunningInterconnectDownloads(manager), isTrue);

      gate.complete();
      await t0.running;
      expect(interconnectDownloadBackgroundTasks(manager), isEmpty);
      expect(hasRunningInterconnectDownloads(manager), isFalse);
    });

    test('导入阶段不可测：环上不定态，行里不写假百分比', () async {
      final InterconnectDownloadManager manager = InterconnectDownloadManager();
      addTearDown(manager.dispose);
      final Completer<void> gate = Completer<void>();
      final ({Future<void> running, String id, void Function(double) progress})
      t0 = startGatedBook(manager, gate);
      manager.reportStage(t0.id, InterconnectDownloadStage.importing);
      final BackgroundTask task = interconnectDownloadBackgroundTasks(
        manager,
      ).single;
      expect(task.fraction, isNull);
      expect(
        task.line,
        'Frieren 1 · ${t.interconnect_download_stage_importing}',
      );
      gate.complete();
      await t0.running;
    });
  });
}
