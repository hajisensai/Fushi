import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/torrent/anime_download_config.dart';
import 'package:fushi/src/media/torrent/anime_download_plan.dart';

AnimeDownloadPlan _fullPlan() {
  return const AnimeDownloadPlan(
    id: 'abc123def456',
    createdAtMs: 1700000000000,
    anilistId: 21,
    seriesTitle: 'One Piece',
    coverUrl: 'https://example.com/cover.jpg',
    torrentTitle: '[Sub] One Piece 01-12 [1080p]',
    magnet: 'magnet:?xt=urn:btih:abc123def456',
    qbCategory: 'hibiki',
    subtitles: <PlanSubtitle>[
      PlanSubtitle(
        episode: 1,
        fileName: 'One Piece 01.ja.srt',
        stagedPath: '/tmp/subs/One Piece 01.ja.srt',
        language: 'ja',
      ),
      PlanSubtitle(fileName: 'extra.ass', stagedPath: '/tmp/subs/extra.ass'),
    ],
    status: AnimeDownloadPlan.statusDownloading,
  );
}

void main() {
  group('QbConnectionConfig codec', () {
    test('roundtrip 保持全部字段', () {
      const QbConnectionConfig config = QbConnectionConfig(
        baseUrl: 'http://127.0.0.1:8080',
        username: 'admin',
        password: 'secret',
        category: 'anime',
      );
      final QbConnectionConfig? decoded = decodeQbConnectionConfig(
        encodeQbConnectionConfig(config),
      );
      expect(decoded, isNotNull);
      expect(decoded!.baseUrl, 'http://127.0.0.1:8080');
      expect(decoded.username, 'admin');
      expect(decoded.password, 'secret');
      expect(decoded.category, 'anime');
      expect(decoded.isConfigured, isTrue);
    });

    test('空串 / 坏 JSON / 非对象返回 null', () {
      expect(decodeQbConnectionConfig(''), isNull);
      expect(decodeQbConnectionConfig('   '), isNull);
      expect(decodeQbConnectionConfig('not json'), isNull);
      expect(decodeQbConnectionConfig('[1,2]'), isNull);
    });

    test('category 缺失/为空回退默认 fushi', () {
      final QbConnectionConfig? decoded = decodeQbConnectionConfig(
        '{"baseUrl":"http://x"}',
      );
      expect(decoded, isNotNull);
      expect(decoded!.category, 'fushi');
      final QbConnectionConfig? decoded2 = decodeQbConnectionConfig(
        '{"baseUrl":"http://x","category":""}',
      );
      expect(decoded2!.category, 'fushi');
    });

    test('默认构造=auto(开箱即用/已配置)；显式 qb 空=未配置；copyWith 逐字段', () {
      // 默认 auto：桌面内置引擎，无需连接参数 → 已配置。
      const QbConnectionConfig config = QbConnectionConfig();
      expect(config.backend, QbConnectionConfig.backendAuto);
      expect(config.isConfigured, isTrue);
      expect(config.category, 'fushi');
      // 显式外接 qb 但没填地址 → 未配置。
      const QbConnectionConfig qbEmpty = QbConnectionConfig(
        backend: QbConnectionConfig.backendQbittorrent,
      );
      expect(qbEmpty.isConfigured, isFalse);
      final QbConnectionConfig edited = qbEmpty.copyWith(baseUrl: 'http://x');
      expect(edited.isConfigured, isTrue);
      expect(edited.category, 'fushi');
      expect(edited.username, '');
    });
  });

  group('AnimeDownloadPlan codec', () {
    test('roundtrip 保持全部字段（含 null 可空字段）', () {
      final AnimeDownloadPlan plan = _fullPlan();
      final AnimeDownloadPlan? decoded = decodeAnimeDownloadPlan(
        encodeAnimeDownloadPlan(plan),
      );
      expect(decoded, isNotNull);
      expect(decoded!.id, plan.id);
      expect(decoded.createdAtMs, plan.createdAtMs);
      expect(decoded.anilistId, 21);
      expect(decoded.seriesTitle, 'One Piece');
      expect(decoded.coverUrl, plan.coverUrl);
      expect(decoded.torrentTitle, plan.torrentTitle);
      expect(decoded.magnet, plan.magnet);
      expect(decoded.qbCategory, 'hibiki');
      expect(decoded.status, AnimeDownloadPlan.statusDownloading);
      expect(decoded.failReason, isNull);
      expect(decoded.collectionId, isNull);
      expect(decoded.importedEarly, isFalse);
      expect(decoded.importInProgress, isFalse);
      expect(decoded.subtitles, hasLength(2));
      expect(decoded.subtitles.first.episode, 1);
      expect(decoded.subtitles.first.language, 'ja');
      expect(decoded.subtitles.last.episode, isNull);
      expect(decoded.subtitles.last.language, isNull);
      expect(decoded.subtitles.last.stagedPath, '/tmp/subs/extra.ass');
    });

    test('roundtrip 保持 imported 状态与 collectionId', () {
      final AnimeDownloadPlan imported = _fullPlan().copyWith(
        status: AnimeDownloadPlan.statusImported,
        collectionId: 42,
      );
      final AnimeDownloadPlan? decoded = decodeAnimeDownloadPlan(
        encodeAnimeDownloadPlan(imported),
      );
      expect(decoded!.status, AnimeDownloadPlan.statusImported);
      expect(decoded.collectionId, 42);
    });

    test('roundtrip 保持边下边播/持久入库 marker；老 JSON 默认 false', () {
      final AnimeDownloadPlan streaming = _fullPlan().copyWith(
        importedEarly: true,
        importInProgress: true,
        collectionId: 42,
      );
      final AnimeDownloadPlan? decoded = decodeAnimeDownloadPlan(
        encodeAnimeDownloadPlan(streaming),
      );
      expect(decoded!.status, AnimeDownloadPlan.statusDownloading);
      expect(decoded.importedEarly, isTrue);
      expect(decoded.importInProgress, isTrue);
      expect(decoded.collectionId, 42);

      final AnimeDownloadPlan? legacy = decodeAnimeDownloadPlan(
        <String, dynamic>{'id': 'legacy'},
      );
      expect(legacy!.importedEarly, isFalse);
      expect(legacy.importInProgress, isFalse);
    });

    test('缺 id 返回 null；空 Map 返回 null', () {
      expect(decodeAnimeDownloadPlan(<String, dynamic>{}), isNull);
      expect(
        decodeAnimeDownloadPlan(<String, dynamic>{'seriesTitle': 'x'}),
        isNull,
      );
      expect(decodeAnimeDownloadPlan(<String, dynamic>{'id': ''}), isNull);
      expect(decodeAnimeDownloadPlan(<String, dynamic>{'id': 123}), isNull);
    });

    test('缺字段用安全默认值；坏字幕条目逐条跳过', () {
      final AnimeDownloadPlan? decoded = decodeAnimeDownloadPlan(
        <String, dynamic>{
          'id': 'hash1',
          'createdAtMs': 'not int',
          'subtitles': <dynamic>[
            'not a map',
            <String, dynamic>{'fileName': 'a.srt'}, // 缺 stagedPath → 跳过
            <String, dynamic>{'fileName': 'b.srt', 'stagedPath': '/tmp/b.srt'},
          ],
        },
      );
      expect(decoded, isNotNull);
      expect(decoded!.createdAtMs, 0);
      expect(decoded.seriesTitle, '');
      expect(decoded.status, AnimeDownloadPlan.statusDownloading);
      expect(decoded.subtitles, hasLength(1));
      expect(decoded.subtitles.single.fileName, 'b.srt');
    });
  });

  group('AnimeDownloadPlanStore', () {
    late Directory tempDir;
    late AnimeDownloadPlanStore store;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('anime_dl_plan_test');
      store = AnimeDownloadPlanStore(
        baseDir: Directory(p.join(tempDir.path, 'anime_downloads')),
      );
    });

    tearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('baseDir 不存在时 loadAll 返回空', () async {
      expect(await store.loadAll(), isEmpty);
    });

    test('save 后 loadAll 读回；不留 .tmp 残骸', () async {
      final AnimeDownloadPlan plan = _fullPlan();
      await store.save(plan);
      final File file = File(
        p.join(store.baseDir.path, 'plans', '${plan.id}.json'),
      );
      expect(file.existsSync(), isTrue);
      expect(File('${file.path}.tmp').existsSync(), isFalse);

      final List<AnimeDownloadPlan> loaded = await store.loadAll();
      expect(loaded, hasLength(1));
      expect(loaded.single.id, plan.id);
      expect(loaded.single.subtitles, hasLength(2));
    });

    test('save 覆盖同 id 计划（状态推进落盘）', () async {
      final AnimeDownloadPlan plan = _fullPlan();
      await store.save(plan);
      await store.save(
        plan.copyWith(
          status: AnimeDownloadPlan.statusImported,
          collectionId: 7,
        ),
      );
      final List<AnimeDownloadPlan> loaded = await store.loadAll();
      expect(loaded, hasLength(1));
      expect(loaded.single.status, AnimeDownloadPlan.statusImported);
      expect(loaded.single.collectionId, 7);
    });

    test('loadAll 跳过坏文件，按 createdAtMs 升序', () async {
      final AnimeDownloadPlan older = _fullPlan().copyWith(
        id: 'older',
        createdAtMs: 100,
      );
      final AnimeDownloadPlan newer = _fullPlan().copyWith(
        id: 'newer',
        createdAtMs: 200,
      );
      await store.save(newer);
      await store.save(older);
      final Directory plansDir = Directory(p.join(store.baseDir.path, 'plans'));
      File(p.join(plansDir.path, 'garbage.json')).writeAsStringSync('not json');
      File(
        p.join(plansDir.path, 'array.json'),
      ).writeAsStringSync(jsonEncode(<int>[1, 2]));
      File(
        p.join(plansDir.path, 'noid.json'),
      ).writeAsStringSync(jsonEncode(<String, dynamic>{'seriesTitle': 'x'}));

      final List<AnimeDownloadPlan> loaded = await store.loadAll();
      expect(loaded.map((AnimeDownloadPlan e) => e.id).toList(), <String>[
        'older',
        'newer',
      ]);
    });

    test('subsDirFor 布局 = baseDir/subs/<id>', () {
      expect(
        store.subsDirFor('hash1').path,
        p.join(store.baseDir.path, 'subs', 'hash1'),
      );
    });

    test('contentKind 默认 video；round-trip 保留；老 JSON 无字段→video', () {
      // 默认（番剧）= video。
      expect(_fullPlan().contentKind, AnimeDownloadPlan.kindVideo);
      // round-trip 保留 book。
      final AnimeDownloadPlan book = _fullPlan().copyWith(
        contentKind: AnimeDownloadPlan.kindBook,
      );
      final AnimeDownloadPlan decoded = decodeAnimeDownloadPlan(
        encodeAnimeDownloadPlan(book),
      )!;
      expect(decoded.contentKind, AnimeDownloadPlan.kindBook);
      // 老计划（JSON 无 contentKind 字段）→ video（向后兼容）。
      final AnimeDownloadPlan legacy = decodeAnimeDownloadPlan(
        <String, dynamic>{'id': 'x', 'magnet': 'm'},
      )!;
      expect(legacy.contentKind, AnimeDownloadPlan.kindVideo);
    });

    test('delete 删计划 JSON 连同 subs 目录；不存在时幂等', () async {
      final AnimeDownloadPlan plan = _fullPlan();
      await store.save(plan);
      final Directory subs = store.subsDirFor(plan.id)
        ..createSync(recursive: true);
      File(p.join(subs.path, 'a.srt')).writeAsStringSync('sub');

      await store.delete(plan.id);
      expect(await store.loadAll(), isEmpty);
      expect(subs.existsSync(), isFalse);

      // 幂等：再删不抛。
      await store.delete(plan.id);
      await store.delete('never-existed');
    });
  });

  group('BUG-1696 shouldRetrySubtitles（字幕反查的 backoff 判据）', () {
    const int t0 = 1700000000000;

    AnimeDownloadPlan planWith({
      required String subtitleStatus,
      int attempts = 0,
      int? lastAttemptAtMs,
      int? jimakuEntryId = 77,
    }) =>
        AnimeDownloadPlan(
          id: 'abc',
          createdAtMs: t0,
          seriesTitle: 'S',
          torrentTitle: 'T',
          magnet: 'magnet:?xt=urn:btih:abc',
          qbCategory: 'hibiki',
          status: AnimeDownloadPlan.statusImported,
          jimakuEntryId: jimakuEntryId,
          subtitleStatus: subtitleStatus,
          subtitleAttempts: attempts,
          subtitleLastAttemptAtMs: lastAttemptAtMs,
        );

    test('只有 unavailable 才重试；resolved/none/pending 都不碰', () {
      for (final String status in <String>[
        AnimeDownloadPlan.subtitleResolved,
        AnimeDownloadPlan.subtitleNone,
        AnimeDownloadPlan.subtitlePending,
      ]) {
        expect(
          planWith(subtitleStatus: status).shouldRetrySubtitles(t0),
          isFalse,
          reason: '$status 不该被字幕重试通道碰到',
        );
      }
    });

    test('没有 Jimaku 条目 → 不重试（没来源，重试只是每轮白打一次网络）', () {
      expect(
        planWith(
          subtitleStatus: AnimeDownloadPlan.subtitleUnavailable,
          jimakuEntryId: null,
        ).shouldRetrySubtitles(t0),
        isFalse,
      );
    });

    test('老计划（attempts=0，本 bug 之前卡死的那批）立刻获得一次重试机会', () {
      expect(
        planWith(subtitleStatus: AnimeDownloadPlan.subtitleUnavailable)
            .shouldRetrySubtitles(t0),
        isTrue,
      );
    });

    test('未到下一档间隔不重试，到了才重试', () {
      final AnimeDownloadPlan afterFirst = planWith(
        subtitleStatus: AnimeDownloadPlan.subtitleUnavailable,
        attempts: 1,
        lastAttemptAtMs: t0,
      );
      final int gap =
          AnimeDownloadPlan.subtitleRetryBackoff.first.inMilliseconds;
      expect(afterFirst.shouldRetrySubtitles(t0 + gap - 1), isFalse);
      expect(afterFirst.shouldRetrySubtitles(t0 + gap), isTrue);
    });

    test('backoff 用完就停，不无限轮询', () {
      final int exhausted = AnimeDownloadPlan.subtitleRetryBackoff.length + 1;
      expect(
        planWith(
          subtitleStatus: AnimeDownloadPlan.subtitleUnavailable,
          attempts: exhausted,
          lastAttemptAtMs: t0,
        ).shouldRetrySubtitles(t0 + const Duration(days: 30).inMilliseconds),
        isFalse,
        reason: '一个永远不会有字幕的条目不该每轮 tick 都打一次 Jimaku',
      );
    });

    test('新增的两个字段进出 JSON；缺字段的老计划回落 0/null', () {
      final AnimeDownloadPlan plan = planWith(
        subtitleStatus: AnimeDownloadPlan.subtitleUnavailable,
        attempts: 3,
        lastAttemptAtMs: t0,
      );
      final AnimeDownloadPlan? round =
          decodeAnimeDownloadPlan(encodeAnimeDownloadPlan(plan));
      expect(round?.subtitleAttempts, 3);
      expect(round?.subtitleLastAttemptAtMs, t0);

      final Map<String, dynamic> legacy =
          Map<String, dynamic>.from(encodeAnimeDownloadPlan(plan))
            ..remove('subtitleAttempts')
            ..remove('subtitleLastAttemptAtMs');
      final AnimeDownloadPlan? old = decodeAnimeDownloadPlan(legacy);
      expect(old?.subtitleAttempts, 0);
      expect(old?.subtitleLastAttemptAtMs, isNull);
      expect(
        old?.shouldRetrySubtitles(t0),
        isTrue,
        reason: '被旧「取不到就算了」卡住的存量计划要能被救回来',
      );
    });
  });
}
