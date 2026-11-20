import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/video_mine_queue_dialog.dart';
import 'package:fushi/src/mining/video_mine_queue.dart';
import 'package:fushi/src/mining/web_mine_queue_store.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
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

/// 每次写入都先让出事件循环（模拟 AnkiConnect 往返），恒成功；记下写入了哪些词。
class _SlowRepo implements BaseAnkiRepository {
  final List<String> expressions = <String>[];

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final Object? fields = jsonDecode(rawPayloadJson);
    expressions.add((fields! as Map<String, Object?>)['expression']! as String);
    return MineOutcome.success(noteId: expressions.length);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// 视频来源的制卡统计总数（`mining_statistics`）。
Future<int> videoMineCount(FushiDatabase db) async {
  final QueryRow row = await db
      .customSelect(
        'SELECT COALESCE(SUM(count), 0) AS n FROM mining_statistics '
        'WHERE source_type = ?',
        variables: <Variable<Object>>[Variable<String>(kStatSourceVideo)],
      )
      .getSingle();
  return row.read<int>('n');
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

  /// 模拟引擎的临时媒体：暂存必须拷走——引擎在暂存返回后就删掉本张卡的私有目录；这里
  /// 让下一张写同名文件覆盖它，效果一样。
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
        seriesTitle: '作品',
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
      retryFailed: true,
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
    // 出处「系列 → 集」（反馈 MCJLSBR5Wg）：暂存的系列名随卡落地（meta.json 往返）。
    expect(first.seriesTitle, '作品');
    expect(first.source, AnkiMiningSource.video);
    expect(first.clipStartMs, 1000);
    expect(first.clipEndMs, 2500);

    expect(queue.bundleDir(a).existsSync(), isFalse);
    expect(queue.bundleDir(b).existsSync(), isTrue);
    // BUG-4813：写完的行直接出表，表里只剩那张失败的。
    expect(
      (await db.select(db.webMineQueue).get()).map((WebMineQueueRow r) => r.id),
      <int>[b],
    );
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
    expect(history.single.positionMs, 1000);
    expect(history.single.normCharOffset, isNull);
  });

  test('列表里的「全部写入」（retryFailed）会重试失败的卡', () async {
    await stageOne('走る');
    await queue.commitAll(
      bookUid: 'remote/emby/1',
      retryFailed: true,
      repo: _Repo(<MineOutcome>[const MineOutcome(MineResult.duplicate)]),
    );
    final VideoMineCommitSummary retry = await queue.commitAll(
      bookUid: 'remote/emby/1',
      retryFailed: true,
      repo: _Repo(<MineOutcome>[const MineOutcome.success()]),
    );
    expect(retry.succeeded, 1);
    expect(await queue.failed('remote/emby/1'), isEmpty);
  });

  test('BUG-4813：退出播放页的自动写入只写待写入的，不重跑写入失败的', () async {
    final int dup = await stageOne('走る');
    // 第一次退出：重复卡写入失败，留在列表里。
    final VideoMineCommitSummary? first = await commitPendingVideoMines(
      queue: Future<VideoMineQueue>.value(queue),
      bookUid: 'remote/emby/1',
      repo: _Repo(<MineOutcome>[const MineOutcome(MineResult.duplicate)]),
      inFlight: const <Future<void>>[],
    );
    expect(first!.failed, 1);

    // 第二次退出：只剩失败行 → 什么都不做（不调 Anki、不再报一次失败）。
    final _Repo untouched = _Repo(<MineOutcome>[]);
    expect(
      await commitPendingVideoMines(
        queue: Future<VideoMineQueue>.value(queue),
        bookUid: 'remote/emby/1',
        repo: untouched,
        inFlight: const <Future<void>>[],
      ),
      isNull,
    );
    expect(untouched.contexts, isEmpty);

    // 第三次退出：又暂存了一张 → 只写新的那张，失败的那张不跟着重跑。
    final int fresh = await stageOne('跳ぶ');
    final _Repo repo = _Repo(<MineOutcome>[const MineOutcome.success()]);
    final VideoMineCommitSummary? third = await commitPendingVideoMines(
      queue: Future<VideoMineQueue>.value(queue),
      bookUid: 'remote/emby/1',
      repo: repo,
      inFlight: const <Future<void>>[],
    );
    expect(third!.succeeded, 1);
    expect(third.failed, 0);
    expect(repo.payloads.single, contains('跳ぶ'));
    expect(queue.bundleDir(fresh).existsSync(), isFalse);

    // 失败的那张原样留着（原因、暂存媒体都在），角标照旧数得到它。
    final WebMineQueueRow kept = (await queue.failed('remote/emby/1')).single;
    expect(kept.id, dup);
    expect(kept.error, 'duplicate');
    expect(queue.bundleDir(dup).existsSync(), isTrue);
    expect(await queue.openCount('remote/emby/1'), 1);
  });

  test('退出写入排在另一次写入后面、轮到时已无事可做：返回 null，不报「成功 0、失败 0」', () async {
    await stageOne('走る');
    final _SlowRepo repo = _SlowRepo();
    // 列表里的「全部写入」还在写，用户就退出了播放页：退出那一刻这张卡仍是待写入。
    final Future<VideoMineCommitSummary> manual = queue.commitAll(
      bookUid: 'remote/emby/1',
      repo: repo,
      retryFailed: true,
    );
    final Future<VideoMineCommitSummary?> onExit = commitPendingVideoMines(
      queue: Future<VideoMineQueue>.value(queue),
      bookUid: 'remote/emby/1',
      repo: repo,
      inFlight: const <Future<void>>[],
    );
    expect((await manual).succeeded, 1);
    expect(await onExit, isNull);
    expect(repo.expressions, <String>['走る']);
  });

  test('问角标只计数、不删旧版本留下的 done 行；首页首帧的 sweepLegacyDone 才收掉', () async {
    final int legacy = await stageOne('走る');
    final int open = await stageOne('跳ぶ');
    await (db.update(
      db.webMineQueue,
    )..where(($WebMineQueueTable t) => t.id.equals(legacy))).write(
      const WebMineQueueCompanion(
        status: Value<String>(WebMineQueueStatus.done),
      ),
    );

    // 读方法没有删除副作用（#3722 L4）：done 行不计入角标，但仍留在表里。
    expect(await queue.openCount('remote/emby/1'), 1);
    final List<WebMineQueueRow> before = await db.select(db.webMineQueue).get();
    expect(before.map((WebMineQueueRow r) => r.id), <int>[legacy, open]);

    await WebMineQueueStore(db).sweepLegacyDone();
    final List<WebMineQueueRow> left = await db.select(db.webMineQueue).get();
    expect(left.map((WebMineQueueRow r) => r.id), <int>[open]);
    expect(await queue.openCount('remote/emby/1'), 1);
  });

  test('退出写入先等在途的暂存任务收尾，再读待写入的行', () async {
    final _Repo repo = _Repo(<MineOutcome>[const MineOutcome.success()]);
    final VideoMineCommitSummary? summary = await commitPendingVideoMines(
      queue: Future<VideoMineQueue>.value(queue),
      bookUid: 'remote/emby/1',
      repo: repo,
      // 退出那一刻这张卡还在准备媒体，没进表。
      inFlight: <Future<void>>[stageOne('走る')],
    );
    expect(summary!.succeeded, 1);
  });

  test('音画同步片段（封面与句子音频是同一个文件）只拷一份，写入时两条路径仍相同', () async {
    final File clip = File('${tmp.path}/immersion_clip.mp4')
      ..writeAsStringSync('clip');
    final int id = await queue.stage(
      bookUid: 'remote/emby/1',
      videoKey: 'remote/emby/1#0',
      fields: <String, String>{'expression': '走る'},
      context: AnkiMiningContext(
        sentence: '走るの文。',
        coverPath: clip.path,
        sentenceAudioPath: clip.path,
        synchronizedVideo: true,
        source: AnkiMiningSource.video,
        clipStartMs: 1000,
        clipEndMs: 2500,
      ),
      meta: const VideoMineStagedMeta(recordHistory: false),
    );
    expect(
      queue
          .bundleDir(id)
          .listSync()
          .map((FileSystemEntity e) => e.uri.pathSegments.last)
          .toList()
        ..sort(),
      <String>['cover.mp4', 'meta.json'],
    );

    final _Repo repo = _Repo(<MineOutcome>[const MineOutcome.success()]);
    final VideoMineCommitSummary summary = await queue.commitAll(
      bookUid: 'remote/emby/1',
      retryFailed: true,
      repo: repo,
    );
    expect(summary.succeeded, 1);
    final AnkiMiningContext context = repo.contexts.single;
    expect(context.synchronizedVideo, isTrue);
    expect(context.coverPath, isNotNull);
    expect(context.sentenceAudioPath, context.coverPath);
    expect(queue.bundleDir(id).existsSync(), isFalse);
  });

  test('落卡记账 helper：统计与制卡历史各一笔，库坏了也不抛', () async {
    await recordVideoMineStat(
      db,
      bookKey: 'remote/emby/1',
      title: '第1話',
      at: DateTime(2026, 9, 26, 12),
    );
    await recordVideoMinedSentence(
      db,
      dateKey: '2026-09-26',
      expression: '走る',
      reading: 'はしる',
      glossary: 'to run',
      sentence: '走るの文。',
      documentTitle: '作品 - 第1話',
      bookKey: 'remote/emby/1',
      sectionIndex: 0,
      positionMs: 1000,
      durationMs: 1500,
      noteId: 11,
    );
    final MinedSentenceRow row =
        (await db.select(db.minedSentences).get()).single;
    expect(row.source, kStatSourceVideo);
    expect(row.expression, '走る');
    expect(row.bookKey, 'remote/emby/1');
    expect(row.noteId, 11);
    expect(await videoMineCount(db), 1);

    // 卡已经进了 Anki：记账失败只留日志，不能反过来把制卡报成失败。
    final FushiDatabase closed = FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    await closed.close();
    await recordVideoMineStat(
      closed,
      bookKey: 'remote/emby/1',
      title: '',
      at: DateTime(2026, 9, 26, 12),
    );
    await recordVideoMinedSentence(
      closed,
      dateKey: '2026-09-26',
      expression: '',
      reading: '',
      glossary: '',
      sentence: '',
      documentTitle: null,
      bookKey: null,
      sectionIndex: null,
      positionMs: null,
      durationMs: null,
      noteId: null,
    );
  });

  test('同一作品并发两次全部写入：串行执行，每张卡只写一次', () async {
    await stageOne('走る');
    await stageOne('跳ぶ');
    // 每次写入都让出事件循环：没有互斥时，两次 commitAll 会各自读到同一批 pending
    // 行，把每张卡写两遍。
    final _SlowRepo repo = _SlowRepo();
    final List<VideoMineCommitSummary>
    summaries = await Future.wait(<Future<VideoMineCommitSummary>>[
      queue.commitAll(bookUid: 'remote/emby/1', retryFailed: true, repo: repo),
      // 调用方每次都新建 VideoMineQueue（弹窗写入 vs 退出写入），锁必须跨实例。
      VideoMineQueue(
        db: db,
        root: Directory('${tmp.path}/${VideoMineQueue.dirName}'),
      ).commitAll(bookUid: 'remote/emby/1', retryFailed: true, repo: repo),
    ]);
    expect(repo.expressions, <String>['走る', '跳ぶ']);
    expect(summaries[0].succeeded, 2);
    expect(summaries[0].failed, 0);
    // 第二次排在第一次之后，读到的 pending 已经空了：既不重写，也不把成功行标失败。
    expect(summaries[1].succeeded, 0);
    expect(summaries[1].failed, 0);
    expect(await queue.pending('remote/emby/1'), isEmpty);
    expect(await queue.failed('remote/emby/1'), isEmpty);
    expect(await db.select(db.minedSentences).get(), hasLength(2));
  });

  test('前一次写入抛错不拖垮排在后面的写入', () async {
    await stageOne('走る');
    final Future<VideoMineCommitSummary> first = queue.commitAll(
      bookUid: 'remote/emby/1',
      retryFailed: true,
      repo: _SlowRepo(),
      now: () => throw StateError('boom'),
    );
    final Future<VideoMineCommitSummary> second = queue.commitAll(
      bookUid: 'remote/emby/1',
      retryFailed: true,
      repo: _SlowRepo(),
    );
    await expectLater(first, throwsStateError);
    final VideoMineCommitSummary summary = await second;
    // 第一次在记账前抛出：行没标 done，第二次照常把它写掉。
    expect(summary.succeeded, 1);
  });

  test('暂存媒体丢了：不建空壳卡，标失败', () async {
    final int a = await stageOne('走る');
    await queue.bundleDir(a).delete(recursive: true);
    final _Repo repo = _Repo(<MineOutcome>[]);
    final VideoMineCommitSummary summary = await queue.commitAll(
      bookUid: 'remote/emby/1',
      retryFailed: true,
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

  test('BUG-4287：写入的卡带回的提示（「保存到」被退回主机默认）进汇总与汇总提示', () async {
    await stageOne('走る');
    await stageOne('泳ぐ');
    final VideoMineCommitSummary summary = await queue.commitAll(
      bookUid: 'remote/emby/1',
      retryFailed: true,
      repo: _Repo(<MineOutcome>[
        const MineOutcome.success(notice: 'Save to was reset.'),
        const MineOutcome.success(),
      ]),
    );
    expect(summary.succeeded, 2);
    expect(summary.notice, 'Save to was reset.');
    expect(
      videoMineCommitMessage(summary),
      '${t.video_mine_queue_committed(ok: 2, failed: 0)}\nSave to was reset.',
    );
    // 关掉「制卡成功提示」也要让用户知道落点变了。
    expect(videoMineCommitSeverity(summary), ToastSeverity.warning);

    await stageOne('飛ぶ');
    final VideoMineCommitSummary plain = await queue.commitAll(
      bookUid: 'remote/emby/1',
      retryFailed: true,
      repo: _Repo(<MineOutcome>[const MineOutcome.success()]),
    );
    expect(plain.notice, isNull);
    expect(
      videoMineCommitMessage(plain),
      t.video_mine_queue_committed(ok: 1, failed: 0),
    );
    expect(videoMineCommitSeverity(plain), ToastSeverity.success);
  });

  test('交给仓库后进了待发制卡队列（queued）：算交接完成，出本暂存队列，不当失败', () async {
    final int id = await stageOne('走る');
    final VideoMineCommitSummary summary = await queue.commitAll(
      bookUid: 'remote/emby/1',
      retryFailed: true,
      repo: _Repo(<MineOutcome>[const MineOutcome.queued()]),
    );
    expect(summary.succeeded, 1);
    expect(summary.failed, 0);
    expect(await queue.failed('remote/emby/1'), isEmpty);
    expect(await queue.pending('remote/emby/1'), isEmpty);
    expect(queue.bundleDir(id).existsSync(), isFalse);
  });
}
