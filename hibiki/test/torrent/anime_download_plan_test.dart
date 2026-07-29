import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki/src/media/torrent/anime_download_config.dart';
import 'package:hibiki/src/media/torrent/anime_download_plan.dart';

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
      PlanSubtitle(
        fileName: 'extra.ass',
        stagedPath: '/tmp/subs/extra.ass',
      ),
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
      final QbConnectionConfig? decoded =
          decodeQbConnectionConfig(encodeQbConnectionConfig(config));
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

    test('category 缺失/为空回退默认 hibiki', () {
      final QbConnectionConfig? decoded =
          decodeQbConnectionConfig('{"baseUrl":"http://x"}');
      expect(decoded, isNotNull);
      expect(decoded!.category, 'hibiki');
      final QbConnectionConfig? decoded2 =
          decodeQbConnectionConfig('{"baseUrl":"http://x","category":""}');
      expect(decoded2!.category, 'hibiki');
    });

    test('默认构造=auto(开箱即用/已配置)；显式 qb 空=未配置；copyWith 逐字段', () {
      // 默认 auto：桌面内置引擎，无需连接参数 → 已配置。
      const QbConnectionConfig config = QbConnectionConfig();
      expect(config.backend, QbConnectionConfig.backendAuto);
      expect(config.isConfigured, isTrue);
      expect(config.category, 'hibiki');
      // 显式外接 qb 但没填地址 → 未配置。
      const QbConnectionConfig qbEmpty =
          QbConnectionConfig(backend: QbConnectionConfig.backendQbittorrent);
      expect(qbEmpty.isConfigured, isFalse);
      final QbConnectionConfig edited = qbEmpty.copyWith(baseUrl: 'http://x');
      expect(edited.isConfigured, isTrue);
      expect(edited.category, 'hibiki');
      expect(edited.username, '');
    });
  });

  group('AnimeDownloadPlan codec', () {
    test('roundtrip 保持全部字段（含 null 可空字段）', () {
      final AnimeDownloadPlan plan = _fullPlan();
      final AnimeDownloadPlan? decoded =
          decodeAnimeDownloadPlan(encodeAnimeDownloadPlan(plan));
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
      final AnimeDownloadPlan? decoded =
          decodeAnimeDownloadPlan(encodeAnimeDownloadPlan(imported));
      expect(decoded!.status, AnimeDownloadPlan.statusImported);
      expect(decoded.collectionId, 42);
    });

    test('roundtrip 保持边下边播提前入库标记；老 JSON 默认 false', () {
      final AnimeDownloadPlan streaming = _fullPlan().copyWith(
        importedEarly: true,
        collectionId: 42,
      );
      final AnimeDownloadPlan? decoded =
          decodeAnimeDownloadPlan(encodeAnimeDownloadPlan(streaming));
      expect(decoded!.status, AnimeDownloadPlan.statusDownloading);
      expect(decoded.importedEarly, isTrue);
      expect(decoded.collectionId, 42);

      final AnimeDownloadPlan? legacy =
          decodeAnimeDownloadPlan(<String, dynamic>{'id': 'legacy'});
      expect(legacy!.importedEarly, isFalse);
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
      final AnimeDownloadPlan? decoded =
          decodeAnimeDownloadPlan(<String, dynamic>{
        'id': 'hash1',
        'createdAtMs': 'not int',
        'subtitles': <dynamic>[
          'not a map',
          <String, dynamic>{'fileName': 'a.srt'}, // 缺 stagedPath → 跳过
          <String, dynamic>{'fileName': 'b.srt', 'stagedPath': '/tmp/b.srt'},
        ],
      });
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
      final File file =
          File(p.join(store.baseDir.path, 'plans', '${plan.id}.json'));
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
      await store.save(plan.copyWith(
        status: AnimeDownloadPlan.statusImported,
        collectionId: 7,
      ));
      final List<AnimeDownloadPlan> loaded = await store.loadAll();
      expect(loaded, hasLength(1));
      expect(loaded.single.status, AnimeDownloadPlan.statusImported);
      expect(loaded.single.collectionId, 7);
    });

    test('loadAll 跳过坏文件，按 createdAtMs 升序', () async {
      final AnimeDownloadPlan older =
          _fullPlan().copyWith(id: 'older', createdAtMs: 100);
      final AnimeDownloadPlan newer =
          _fullPlan().copyWith(id: 'newer', createdAtMs: 200);
      await store.save(newer);
      await store.save(older);
      final Directory plansDir = Directory(p.join(store.baseDir.path, 'plans'));
      File(p.join(plansDir.path, 'garbage.json')).writeAsStringSync('not json');
      File(p.join(plansDir.path, 'array.json'))
          .writeAsStringSync(jsonEncode(<int>[1, 2]));
      File(p.join(plansDir.path, 'noid.json'))
          .writeAsStringSync(jsonEncode(<String, dynamic>{'seriesTitle': 'x'}));

      final List<AnimeDownloadPlan> loaded = await store.loadAll();
      expect(loaded.map((AnimeDownloadPlan e) => e.id).toList(),
          <String>['older', 'newer']);
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
      final AnimeDownloadPlan book =
          _fullPlan().copyWith(contentKind: AnimeDownloadPlan.kindBook);
      final AnimeDownloadPlan decoded =
          decodeAnimeDownloadPlan(encodeAnimeDownloadPlan(book))!;
      expect(decoded.contentKind, AnimeDownloadPlan.kindBook);
      // 老计划（JSON 无 contentKind 字段）→ video（向后兼容）。
      final AnimeDownloadPlan legacy =
          decodeAnimeDownloadPlan(<String, dynamic>{'id': 'x', 'magnet': 'm'})!;
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
}
