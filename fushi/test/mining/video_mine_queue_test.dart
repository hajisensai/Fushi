import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/video_mine_queue.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_core/fushi_core.dart';

/// 「看完再制卡」暂存队列：暂存 → 列表 → 全部写入（成功记账删暂存 / 失败留着）→ 删除。
class _Repo implements BaseAnkiRepository {
  _Repo(this.outcomes);

  final List<MineOutcome> outcomes;
  final List<AnkiMiningContext> contexts = <AnkiMiningContext>[];
  final List<String> payloads = <String>[];

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    contexts.add(context);
    payloads.add(rawPayloadJson);
    // 写入时媒体必须还在暂存目录里。
    if (context.sentenceAudioPath != null) {
      expect(File(context.sentenceAudioPath!).existsSync(), isTrue);
    }
    return outcomes.removeAt(0);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  late FushiDatabase db;
  late Directory tmp;
  late VideoMineQueue queue;

  setUp(() async {
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    tmp = await Directory.systemTemp.createTemp('video_mine_queue');
    queue = VideoMineQueue(
      db: db,
      root: Directory('${tmp.path}/${VideoMineQueue.dirName}'),
    );
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  /// 模拟引擎的固定临时文件名：暂存必须拷走，下一张会覆盖它们。
  Future<int> stageOne(String word, {String book = 'remote/emby/1'}) async {
    final File cover = File('${tmp.path}/immersion_clip.avif')
      ..writeAsStringSync('cover-$word');
    final File audio = File('${tmp.path}/immersion_audio.aac')
      ..writeAsStringSync('audio-$word');
    return queue.stage(
      bookUid: book,
      videoKey: '$book#0',
      fields: <String, String>{'expression': word},
      context: AnkiMiningContext(
        sentence: '$wordの文。',
        cueSentence: '$wordの文。',
        coverPath: cover.path,
        sentenceAudioPath: audio.path,
        source: AnkiMiningSource.video,
        clipStartMs: 1000,
        clipEndMs: 2500,
      ),
      meta: const VideoMineStagedMeta(
        documentTitle: '作品 - 第1話',
        bookTitleTag: '第1話',
        statBookKey: 'remote/emby/1',
        statTitle: '第1話',
        historyDateKey: '2026-09-26',
        historyBookKey: 'remote/emby/1',
        historyCueStartMs: 1000,
        historyCueLengthMs: 1500,
      ),
    );
  }

  test('暂存把媒体拷进独立目录，引擎的临时文件被覆盖也不影响', () async {
    final int a = await stageOne('走る');
    final int b = await stageOne('跳ぶ');
    expect((await queue.pending('remote/emby/1')).map((r) => r.id), <int>[
      a,
      b,
    ]);
    expect(
      File('${queue.bundleDir(a).path}/audio.aac').readAsStringSync(),
      'audio-走る',
    );
    expect(
      File('${queue.bundleDir(b).path}/cover.avif').readAsStringSync(),
      'cover-跳ぶ',
    );
    // 别的视频看不到。
    expect(await queue.pending('remote/emby/2'), isEmpty);
  });

  test('全部写入：按点击顺序落卡，成功的记统计与历史并删暂存，重复的留作失败', () async {
    final int a = await stageOne('走る');
    final int b = await stageOne('跳ぶ');
    final _Repo repo = _Repo(<MineOutcome>[
      const MineOutcome.success(noteId: 11),
      const MineOutcome(MineResult.duplicate),
    ]);
    final VideoMineCommitSummary summary = await queue.commitAll(
      bookUid: 'remote/emby/1',
      repo: repo,
      now: () => DateTime(2026, 9, 26, 12),
    );
    expect(summary.succeeded, 1);
    expect(summary.failed, 1);
    expect(repo.payloads.first, contains('走る'));
    final AnkiMiningContext first = repo.contexts.first;
    expect(first.sentence, '走るの文。');
    expect(first.documentTitle, '作品 - 第1話');
    expect(first.bookTitleTag, '第1話');
    expect(first.source, AnkiMiningSource.video);
    expect(first.clipStartMs, 1000);
    expect(first.clipEndMs, 2500);

    expect(queue.bundleDir(a).existsSync(), isFalse);
    expect(queue.bundleDir(b).existsSync(), isTrue);
    final List<WebMineQueueRow> failed = await queue.failed('remote/emby/1');
    expect(failed.single.id, b);
    expect(failed.single.error, 'duplicate');
    expect(await queue.pending('remote/emby/1'), isEmpty);

    final List<MinedSentenceRow> history = await db
        .select(db.minedSentences)
        .get();
    expect(history.single.expression, '走る');
    expect(history.single.noteId, 11);
    expect(history.single.bookKey, 'remote/emby/1');
    expect(history.single.normCharOffset, 1000);
  });

  test('失败的卡下次写入会重试', () async {
    await stageOne('走る');
    await queue.commitAll(
      bookUid: 'remote/emby/1',
      repo: _Repo(<MineOutcome>[const MineOutcome(MineResult.duplicate)]),
    );
    final VideoMineCommitSummary retry = await queue.commitAll(
      bookUid: 'remote/emby/1',
      repo: _Repo(<MineOutcome>[const MineOutcome.success()]),
    );
    expect(retry.succeeded, 1);
    expect(await queue.failed('remote/emby/1'), isEmpty);
  });

  test('暂存媒体丢了：不建空壳卡，标失败', () async {
    final int a = await stageOne('走る');
    await queue.bundleDir(a).delete(recursive: true);
    final _Repo repo = _Repo(<MineOutcome>[]);
    final VideoMineCommitSummary summary = await queue.commitAll(
      bookUid: 'remote/emby/1',
      repo: repo,
    );
    expect(summary.failed, 1);
    expect(repo.contexts, isEmpty);
  });

  test('删除一张：行与媒体一起没', () async {
    final int a = await stageOne('走る');
    await queue.discard(a);
    expect(await queue.pending('remote/emby/1'), isEmpty);
    expect(queue.bundleDir(a).existsSync(), isFalse);
  });
}
