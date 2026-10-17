@Tags(<String>['preview'])
library;

// 系列详情页「打开」路径上两段同步重活的测量（只在 `FUSHI_BENCH=1` 时真跑，打印
// 毫秒数，不做断言——机器差异太大，数字写进 PR 说明，不当 CI 门）。
//
//   $env:FUSHI_BENCH='1'
//   flutter test --no-pub test/pages/collection_preview/collection_detail_open_bench_test.dart
//
// ① 来源兜底索引：合集没有规范作品行时，旧 `_reload` 每次打开都对成员所在来源整个
//    跑一遍 `VideoSourceMetadataIndexer.index`（规划全来源作品 + 逐部 stat NFO），
//    而且是在路由转场期间同步 await。这里量「第二次及以后」的成本——那正是每次
//    打开都会重复付的部分。
// ② 集级刮削资料：旧实现逐集 `getVideoScrapeMeta`（N+1），新实现一次
//    `getVideoScrapeMetaForBooks`。

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/video_source_metadata_indexer.dart';
import 'package:path/path.dart' as p;

const int _series = 40;
const int _episodes = 12;

void main() {
  final bool skip = Platform.environment['FUSHI_BENCH'] != '1';

  test('collection detail open: source indexing + scrape meta N+1', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final Directory root = await Directory.systemTemp.createTemp('vlf_bench_');
    addTearDown(() => root.delete(recursive: true));
    final int sourceId = await db.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Anime',
        mediaKind: 'video',
        rootPath: root.path,
        createdAt: 1,
      ),
    );
    final List<String> uids = <String>[];
    for (int s = 0; s < _series; s++) {
      final Directory dir = Directory(p.join(root.path, 'Show $s'))
        ..createSync();
      for (int e = 1; e <= _episodes; e++) {
        final File video = File(p.join(dir.path, 'Show $s - $e.mkv'))
          ..writeAsBytesSync(const <int>[0]);
        final String uid = 'show-$s-$e';
        uids.add(uid);
        await db.upsertVideoBook(
          VideoBooksCompanion(
            bookUid: Value<String>(uid),
            title: Value<String>('Show $s - $e'),
            videoPath: Value<String>(video.path),
            sourceId: Value<int?>(sourceId),
          ),
        );
        await db.upsertVideoScrapeMeta(
          VideoScrapeMetaCompanion.insert(
            bookUid: uid,
            source: 'tmdb',
            subjectId: '$s',
            title: 'Show $s',
            episodeNumber: Value<int?>(e),
            scrapedAt: DateTime(2026),
          ),
        );
      }
    }
    final SourceLibraryRow source = (await db.getMediaSourceById(sourceId))!;
    final VideoSourceMetadataIndexer indexer = VideoSourceMetadataIndexer(db);

    final Stopwatch first = Stopwatch()..start();
    await indexer.index(source);
    first.stop();
    final List<int> repeats = <int>[];
    for (int i = 0; i < 5; i++) {
      final Stopwatch sw = Stopwatch()..start();
      await indexer.index(source);
      repeats.add(sw.elapsedMicroseconds);
    }
    repeats.sort();

    // 一部作品的成员（12 集）与一部长篇（全部 480 行）两种量级。
    Future<(int, int)> scrapeMeta(List<String> members) async {
      final Stopwatch single = Stopwatch()..start();
      for (final String uid in members) {
        await db.getVideoScrapeMeta(uid);
      }
      single.stop();
      final Stopwatch batch = Stopwatch()..start();
      await db.getVideoScrapeMetaForBooks(members);
      batch.stop();
      return (single.elapsedMicroseconds, batch.elapsedMicroseconds);
    }

    final (int, int) small = await scrapeMeta(uids.take(_episodes).toList());
    final (int, int) large = await scrapeMeta(uids);

    // ignore: avoid_print
    print(
      'BENCH source=${_series * _episodes} videos / $_series works\n'
      'BENCH index first run: ${first.elapsedMilliseconds} ms\n'
      'BENCH index repeat (median of 5, paid on every open before the fix): '
      '${(repeats[2] / 1000).toStringAsFixed(1)} ms\n'
      'BENCH scrape meta $_episodes eps: N+1 ${(small.$1 / 1000).toStringAsFixed(1)} ms'
      ' vs batch ${(small.$2 / 1000).toStringAsFixed(1)} ms\n'
      'BENCH scrape meta ${uids.length} eps: N+1 ${(large.$1 / 1000).toStringAsFixed(1)} ms'
      ' vs batch ${(large.$2 / 1000).toStringAsFixed(1)} ms',
    );
  }, skip: skip);
}
