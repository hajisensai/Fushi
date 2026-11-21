import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/source_library/source_auto_scan.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:path/path.dart' as p;

/// 来源长扫描的行内进度（拍板台 design-nmv-scan-progress）：扫描器经
/// [SourceScanActivity] 报「列目录 · 已找到 N 个文件 · 当前目录」与「导入 i / n ·
/// 当前条目」，来源页按 [SourceScanActivity.progressListenable] 重画。
void main() {
  group('SourceScanActivity progress', () {
    test(
      'reports outside the lock are ignored; cleared when the scan ends',
      () async {
        final SourceScanActivity activity = SourceScanActivity(
          progressPublishInterval: Duration.zero,
        );
        activity.reportListing(1, '/media/1', 3);
        expect(activity.progressOf(1), isNull);

        SourceScanProgress? during;
        await activity.run(1, () async {
          activity.reportListing(1, '/media/1/sub', 7);
          during = activity.progressOf(1);
        });

        expect(
          during,
          const SourceScanProgress.listing(
            filesFound: 7,
            currentPath: '/media/1/sub',
          ),
        );
        expect(during!.fraction, isNull, reason: 'listing total is unknown');
        expect(activity.progressOf(1), isNull);
      },
    );

    test('import phase counts started items and caps at the total', () async {
      final SourceScanActivity activity = SourceScanActivity(
        progressPublishInterval: Duration.zero,
      );
      await activity.run(1, () async {
        activity.reportListing(1, '/media/1', 2);
        // 还没进导入阶段：逐条报告不改列目录进度。
        activity.reportImportItem(1, '/media/1/early.mkv');
        expect(activity.progressOf(1)!.phase, SourceScanPhase.listing);

        activity.beginImport(1, 2);
        expect(activity.progressOf(1)!.fraction, 0);
        activity.reportImportItem(1, '/media/1/a.mkv');
        expect(
          activity.progressOf(1),
          const SourceScanProgress.importing(
            processed: 1,
            total: 2,
            currentPath: '/media/1/a.mkv',
          ),
        );
        expect(activity.progressOf(1)!.fraction, 0.5);
        activity.reportImportItem(1, '/media/1/b.mkv');
        // 收尾阶段（HLS 展开、合订本回收）多过的条目不让计数超过总数。
        activity.reportImportItem(1, '/media/1/extra.mkv');
        expect(
          activity.progressOf(1),
          const SourceScanProgress.importing(
            processed: 2,
            total: 2,
            currentPath: '/media/1/extra.mkv',
          ),
        );
      });
    });

    // 导入阶段里文件系统的列目录回调（远端导书失败后的连通性探测、非递归来源逐卷
    // 现场列目录）不能把进度冲回列目录阶段，否则之后的逐条报告全被丢弃。
    test('listing callbacks during import do not reset the phase', () async {
      final SourceScanActivity activity = SourceScanActivity(
        progressPublishInterval: Duration.zero,
      );
      await activity.run(1, () async {
        activity.beginImport(1, 3);
        activity.reportImportItem(1, '/media/1/a.epub');
        activity.reportListing(1, '/media/1', 0);
        activity.reportImportItem(1, '/media/1/b.epub');
        expect(
          activity.progressOf(1),
          const SourceScanProgress.importing(
            processed: 2,
            total: 3,
            currentPath: '/media/1/b.epub',
          ),
        );
      });
    });

    test('progress notifications are throttled, separate from occupancy', () {
      fakeAsync((FakeAsync async) {
        final SourceScanActivity activity = SourceScanActivity(
          progressPublishInterval: const Duration(milliseconds: 200),
        );
        int progressNotes = 0;
        int occupancyNotes = 0;
        activity.progressListenable.addListener(() => progressNotes++);
        activity.addListener(() => occupancyNotes++);
        final Completer<void> gate = Completer<void>();
        unawaited(activity.run(1, () => gate.future));
        async.flushMicrotasks();
        expect(occupancyNotes, 1);

        for (int i = 0; i < 50; i++) {
          activity.reportListing(1, '/media/1/d$i', i);
        }
        expect(progressNotes, 1, reason: 'first report publishes at once');
        expect(occupancyNotes, 1, reason: 'progress must not ping occupancy');

        async.elapse(const Duration(milliseconds: 200));
        expect(progressNotes, 2, reason: 'one trailing publish per interval');
        expect(activity.progressOf(1)!.filesFound, 49);

        gate.complete();
        async.flushMicrotasks();
        expect(progressNotes, 3, reason: 'scan end clears and publishes');
        expect(activity.progressOf(1), isNull);
        expect(occupancyNotes, 2);
        async.elapse(const Duration(seconds: 1));
        expect(progressNotes, 3);
      });
    });

    test('scanProgressPathLabel shows the last segment', () {
      expect(scanProgressPathLabel('/media/Show/Season 1'), 'Season 1');
      expect(scanProgressPathLabel(r'D:\video\Show'), 'Show');
      expect(scanProgressPathLabel('https://nas/dav/Show/'), 'Show');
      expect(scanProgressPathLabel('/'), '');
      expect(scanProgressPathLabel('ep01.mkv'), 'ep01.mkv');
    });
  });

  group('SourceLibraryScanner reports progress', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('scan_progress_');
      sourceScanActivity.progressPublishInterval = Duration.zero;
    });
    tearDown(() {
      sourceScanActivity.progressPublishInterval =
          kSourceScanProgressPublishInterval;
      try {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test(
      'local video scan: listing per directory, then importing i/n',
      () async {
        final FushiDatabase db = FushiDatabase.forTesting(
          NativeDatabase.memory(),
        );
        addTearDown(db.close);
        final List<String> videos = <String>[
          p.join(tmp.path, 'Movie', 'movie.mkv'),
          p.join(tmp.path, 'Show', 'ep01.mkv'),
          p.join(tmp.path, 'Show', 'ep02.mkv'),
        ];
        for (final String path in videos) {
          File(path)
            ..createSync(recursive: true)
            ..writeAsBytesSync(<int>[0, 1, 2, 3]);
        }
        final int sid = await db.insertMediaSource(
          MediaSourcesCompanion.insert(
            label: 'Videos',
            mediaKind: 'video',
            rootPath: tmp.path,
            createdAt: 1000,
          ),
        );
        final SourceLibraryRow source = (await db.getMediaSourceById(sid))!;

        final List<SourceScanProgress> seen = <SourceScanProgress>[];
        void onProgress() {
          final SourceScanProgress? progress = sourceScanActivity.progressOf(
            sid,
          );
          if (progress != null) seen.add(progress);
        }

        sourceScanActivity.progressListenable.addListener(onProgress);
        addTearDown(
          () =>
              sourceScanActivity.progressListenable.removeListener(onProgress),
        );

        final SourceScanSummary summary = await SourceLibraryScanner(
          db,
          transcribeAudiobook: null,
        ).scan(source);

        expect(summary.error, isNull);
        final List<SourceScanProgress> listing = <SourceScanProgress>[
          for (final SourceScanProgress s in seen)
            if (s.phase == SourceScanPhase.listing) s,
        ];
        expect(
          listing.map((SourceScanProgress s) => s.currentPath),
          containsAll(<String>[
            tmp.path,
            p.join(tmp.path, 'Movie'),
            p.join(tmp.path, 'Show'),
          ]),
        );
        final List<SourceScanProgress> importing = <SourceScanProgress>[
          for (final SourceScanProgress s in seen)
            if (s.phase == SourceScanPhase.importing) s,
        ];
        expect(importing, isNotEmpty);
        expect(importing.first.processed, 0);
        expect(importing.last.total, 3);
        expect(importing.last.processed, 3);
        expect(
          importing.map((SourceScanProgress s) => s.currentPath).toSet(),
          containsAll(videos),
        );
        // 扫完即清，来源页回到常规状态行。
        expect(sourceScanActivity.progressOf(sid), isNull);
      },
    );
  });
}
