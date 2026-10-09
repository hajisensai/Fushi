import 'dart:io';

import 'package:drift/native.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/media/discovery/import/discovery_import_plan.dart'
    show DiscoveryImportBlocker;
import 'package:path/path.dart' as p;

import 'package:fushi/src/mining/galgame_repository.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/platform/desktop/ctl/ctl_library_entries.dart';
import 'package:fushi/src/platform/desktop/ctl/ctl_library_import.dart';
import 'package:fushi/src/platform/desktop/ctl/ctl_library_routes.dart';
import 'package:fushi/src/platform/desktop/ctl/desktop_ctl_context.dart';

/// 路由表构造期不碰 ref；只为满足 [DesktopCtlContext] 的签名。
class _UnusedWidgetRef implements WidgetRef {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('路由表构造期不该读 ref');
}

LibraryCtlEntry _entry(
  String key,
  LibraryCtlKind kind,
  String title, {
  int? recentAt,
  String? rawTitle,
}) => LibraryCtlEntry(
  key: LibraryCtlKey.tryParse(key)!,
  kind: kind,
  title: title,
  rawTitle: rawTitle,
  recentAt: recentAt,
);

void main() {
  group('路由表', () {
    final List<CtlRoute> routes = buildLibraryCtlRoutes(
      DesktopCtlContext(ref: _UnusedWidgetRef(), focusMainWindow: () async {}),
    );

    test('路径都在 /api/admin/library/ 下', () {
      expect(routes, isNotEmpty);
      for (final CtlRoute route in routes) {
        expect(route.pattern, startsWith('/api/admin/library/'));
      }
    });

    test('method + path 不重复', () {
      final Set<String> seen = <String>{};
      for (final CtlRoute route in routes) {
        expect(
          seen.add('${route.method} ${route.pattern}'),
          isTrue,
          reason: '${route.method} ${route.pattern} 重复',
        );
      }
    });

    test('条目路由按编码后的键匹配，id 里的 / 不拆段', () {
      final CtlRoute open = routes.singleWhere(
        (CtlRoute r) => r.pattern.endsWith('/open'),
      );
      final String encoded = Uri.encodeComponent('video:video/ext/ab c');
      expect(
        open.match('/api/admin/library/items/$encoded/open'),
        <String, String>{'key': 'video:video/ext/ab c'},
      );
    });
  });

  group('LibraryCtlKey', () {
    test('解析与往返', () {
      final LibraryCtlKey key = LibraryCtlKey.tryParse('book:猫の本')!;
      expect(key.store, LibraryCtlStore.book);
      expect(key.id, '猫の本');
      expect(key.wire, 'book:猫の本');
      expect(
        LibraryCtlKey.tryParse('video:video/ext/a:b')!.id,
        'video/ext/a:b',
      );
      expect(
        LibraryCtlKey.tryParse('srt:srtbook_1')!.store,
        LibraryCtlStore.srt,
      );
      expect(LibraryCtlKey.tryParse('game:g1')!.store, LibraryCtlStore.game);
    });

    test('前缀未知 / 缺 id / 缺冒号 → null', () {
      expect(LibraryCtlKey.tryParse('epub:x'), isNull);
      expect(LibraryCtlKey.tryParse('book:'), isNull);
      expect(LibraryCtlKey.tryParse(':x'), isNull);
      expect(LibraryCtlKey.tryParse('book'), isNull);
    });
  });

  group('LibraryCtlKind', () {
    test('解析大小写不敏感，未知为 null', () {
      expect(LibraryCtlKind.tryParse('Manga'), LibraryCtlKind.manga);
      expect(LibraryCtlKind.tryParse(' video '), LibraryCtlKind.video);
      expect(LibraryCtlKind.tryParse('comic'), isNull);
      expect(LibraryCtlKind.tryParse(null), isNull);
    });

    test('format → 种类 与 模块映射', () {
      expect(
        LibraryCtlKind.forBookFormat(BookFormat.epub),
        LibraryCtlKind.book,
      );
      expect(LibraryCtlKind.forBookFormat(BookFormat.pdf), LibraryCtlKind.pdf);
      expect(
        LibraryCtlKind.forBookFormat(BookFormat.manga),
        LibraryCtlKind.manga,
      );
      expect(LibraryCtlKind.pdf.module, ModuleId.books);
      expect(LibraryCtlKind.audiobook.module, ModuleId.books);
      expect(LibraryCtlKind.manga.module, ModuleId.manga);
      expect(LibraryCtlKind.video.module, ModuleId.video);
      expect(LibraryCtlKind.game.module, ModuleId.games);
    });
  });

  group('--at 解析', () {
    test('视频时间点', () {
      expect(parseCtlTimestampMs('90'), 90000);
      expect(parseCtlTimestampMs('90.5'), 90500);
      expect(parseCtlTimestampMs('1:30'), 90000);
      expect(parseCtlTimestampMs('1:02:03'), 3723000);
      expect(parseCtlTimestampMs('1:75'), isNull);
      expect(parseCtlTimestampMs('1.5:00'), isNull);
      expect(parseCtlTimestampMs('-3'), isNull);
      expect(parseCtlTimestampMs('a'), isNull);
      expect(parseCtlTimestampMs('1:2:3:4'), isNull);
      expect(parseCtlTimestampMs(''), isNull);
    });

    test('书章号 1 起计 → sectionIndex 0 起计', () {
      expect(parseCtlChapterIndex('1'), 0);
      expect(parseCtlChapterIndex('12'), 11);
      expect(parseCtlChapterIndex('0'), isNull);
      expect(parseCtlChapterIndex('x'), isNull);
    });
  });

  group('进度', () {
    test('百分比与文案', () {
      expect(libraryCtlPercent(position: 1, duration: 3), 33);
      expect(libraryCtlPercent(position: 5, duration: 0), 0);
      expect(libraryCtlPercent(position: 9, duration: 3), 100);
      expect(
        libraryCtlProgressLabel(
          LibraryCtlEntry(
            key: const LibraryCtlKey(LibraryCtlStore.book, 'a'),
            kind: LibraryCtlKind.book,
            title: 'a',
            percent: 37,
          ),
        ),
        '37%',
      );
      expect(
        libraryCtlProgressLabel(
          const LibraryCtlEntry(
            key: LibraryCtlKey(LibraryCtlStore.video, 'v'),
            kind: LibraryCtlKind.video,
            title: 'v',
            positionMs: 3723000,
          ),
        ),
        '1:02:03',
      );
      expect(
        libraryCtlProgressLabel(
          const LibraryCtlEntry(
            key: LibraryCtlKey(LibraryCtlStore.game, 'g'),
            kind: LibraryCtlKind.game,
            title: 'g',
            playSeconds: 5400,
          ),
        ),
        '1.5h',
      );
      expect(
        libraryCtlProgressLabel(
          const LibraryCtlEntry(
            key: LibraryCtlKey(LibraryCtlStore.video, 'v'),
            kind: LibraryCtlKind.video,
            title: 'v',
            positionMs: 10,
            completed: true,
          ),
        ),
        '完成',
      );
    });
  });

  group('筛选', () {
    final List<LibraryCtlEntry> entries = <LibraryCtlEntry>[
      _entry('book:a', LibraryCtlKind.book, 'ネコの本'),
      _entry('video:v', LibraryCtlKind.video, 'Fate／stay night'),
      _entry('game:g', LibraryCtlKind.game, '改名后', rawTitle: '原名ゲーム'),
    ];

    test('搜索走库页同一归一化：片假名 ↔ 平假名、全角 ↔ 半角', () {
      expect(
        filterLibraryCtlEntries(entries, search: 'ねこ').single.key.wire,
        'book:a',
      );
      expect(
        filterLibraryCtlEntries(entries, search: 'fate stay').single.key.wire,
        'video:v',
      );
      expect(
        filterLibraryCtlEntries(entries, search: '原名').single.key.wire,
        'game:g',
      );
    });

    test('按种类筛；空搜索不过滤', () {
      expect(
        filterLibraryCtlEntries(
          entries,
          kinds: <LibraryCtlKind>{LibraryCtlKind.video, LibraryCtlKind.game},
          search: '  ',
        ).map((LibraryCtlEntry e) => e.key.wire),
        <String>['video:v', 'game:g'],
      );
    });
  });

  test('最近打开流：去重留最新、倒序、截断、跳过没打开过的', () {
    final List<LibraryCtlEntry> merged =
        mergeLibraryCtlHistory(<LibraryCtlEntry>[
          _entry('book:a', LibraryCtlKind.book, 'a', recentAt: 100),
          _entry('book:a', LibraryCtlKind.book, 'a', recentAt: 300),
          _entry('video:v', LibraryCtlKind.video, 'v', recentAt: 200),
          _entry('game:g', LibraryCtlKind.game, 'g'),
          _entry('book:b', LibraryCtlKind.book, 'b', recentAt: 50),
        ], limit: 2);
    expect(
      merged.map((LibraryCtlEntry e) => '${e.key.wire}@${e.recentAt}'),
      <String>['book:a@300', 'video:v@200'],
    );
  });

  test('导入状态线上名与失败判定', () {
    expect(LibraryCtlImportStatus.sourceAdded.wireName, 'source_added');
    expect(LibraryCtlImportStatus.unsupported.isFailure, isTrue);
    expect(LibraryCtlImportStatus.failed.isFailure, isTrue);
    expect(LibraryCtlImportStatus.skipped.isFailure, isFalse);
    expect(
      const LibraryCtlImportResult(
        path: '/a',
        status: LibraryCtlImportStatus.imported,
        kind: LibraryCtlKind.book,
        keys: <String>['book:a'],
      ).toJson(),
      <String, Object?>{
        'path': '/a',
        'status': 'imported',
        'kind': 'book',
        'keys': <String>['book:a'],
      },
    );
    for (final DiscoveryImportBlocker blocker
        in DiscoveryImportBlocker.values) {
      expect(libraryCtlBlockerMessage(blocker), isNotEmpty);
    }
  });

  group('LibraryCtlImporter（内存库）', () {
    late FushiDatabase db;
    late GalgameRepository games;
    late Directory tmp;
    Set<LibraryCtlKind> disabled = <LibraryCtlKind>{};

    LibraryCtlImporter importer({
      bool keepDuplicates = false,
      Future<String?> Function(String path)? ingestVideoFile,
    }) => LibraryCtlImporter(
      db: db,
      galgameRepo: games,
      isKindEnabled: (LibraryCtlKind kind) => !disabled.contains(kind),
      keepDuplicates: keepDuplicates,
      ingestVideoFile: ingestVideoFile,
    );

    String touch(String name) {
      // 用例里的相对名一律写 `/`，落盘前换成本平台分隔符：否则 Windows 上
      // `p.join` 原样保留 `/`，期望值与导入器返回的本机路径对不上。
      final File file = File(p.joinAll(<String>[tmp.path, ...name.split('/')]))
        ..createSync(recursive: true)
        ..writeAsBytesSync(List<int>.filled(16, 0));
      return file.path;
    }

    setUp(() {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      games = GalgameRepository(db);
      tmp = Directory.systemTemp.createTempSync('fushi_ctl_library_');
      disabled = <LibraryCtlKind>{};
    });

    tearDown(() async {
      await db.close();
      tmp.deleteSync(recursive: true);
    });

    test('路径不存在 → failed', () async {
      final List<LibraryCtlImportResult> results = await importer().importAll(
        <String>[p.join(tmp.path, 'nope.epub')],
      );
      expect(results.single.status, LibraryCtlImportStatus.failed);
    });

    test('视频 / 字幕 / 音频 / 词典 / 种子文件不会被当文本转成书', () async {
      final List<LibraryCtlImportResult> results = await importer()
          .importAll(<String>[
            touch('a.mkv'),
            touch('b.srt'),
            touch('c.mp3'),
            touch('d.mdx'),
            touch('e.torrent'),
            touch('f.weird'),
          ]);
      expect(
        results.map((LibraryCtlImportResult r) => r.status).toSet(),
        <LibraryCtlImportStatus>{LibraryCtlImportStatus.unsupported},
      );
      expect(results.first.message, kLibraryCtlVideoFileHint);
      expect(results[1].kind, LibraryCtlKind.audiobook);
      expect(await db.getEpubBookMetas(), isEmpty);
    });

    test('--kind video 给文件 → unsupported 并指路', () async {
      final List<LibraryCtlImportResult> results = await importer().importAll(
        <String>[touch('a.mp4')],
        kind: LibraryCtlKind.video,
      );
      expect(results.single.status, LibraryCtlImportStatus.unsupported);
      expect(results.single.message, kLibraryCtlVideoFileHint);
    });

    test('宿主提供外部视频入库入口 → 视频文件走它入库，键为 video:<bookUid>', () async {
      final List<String> ingested = <String>[];
      final LibraryCtlImporter withIngest = importer(
        ingestVideoFile: (String path) async {
          ingested.add(path);
          return 'video/ext/abc';
        },
      );
      final String video = touch('ep01.mkv');
      final List<LibraryCtlImportResult> results = await withIngest.importAll(
        <String>[video],
      );
      expect(ingested, <String>[video]);
      expect(results.single.status, LibraryCtlImportStatus.imported);
      expect(results.single.keys, <String>['video:video/ext/abc']);
    });

    test('外部视频入库失败 → failed；视频模块关闭 → 不调用入库', () async {
      int calls = 0;
      Future<String?> failing(String path) async {
        calls++;
        return null;
      }

      final String video = touch('ep02.mp4');
      expect(
        (await importer(
          ingestVideoFile: failing,
        ).importAll(<String>[video])).single.status,
        LibraryCtlImportStatus.failed,
      );
      disabled = <LibraryCtlKind>{LibraryCtlKind.video};
      expect(
        (await importer(
          ingestVideoFile: failing,
        ).importAll(<String>[video])).single.status,
        LibraryCtlImportStatus.unsupported,
      );
      expect(calls, 1);
    });

    test('游戏 exe：登记入库，再导一次按已在库跳过', () async {
      final String exe = touch('Game/game.exe');
      final LibraryCtlImportResult first = (await importer().importAll(<String>[
        exe,
      ])).single;
      expect(first.status, LibraryCtlImportStatus.imported);
      expect(first.kind, LibraryCtlKind.game);
      expect(first.keys.single, startsWith('game:'));
      await games.load();
      expect(games.games.single.exePath, exe);

      final LibraryCtlImportResult again = (await importer().importAll(<String>[
        exe,
      ])).single;
      expect(again.status, LibraryCtlImportStatus.skipped);
    });

    test('游戏目录：按启发式挑主程序', () async {
      touch('Gal/setup.exe');
      final String main = touch('Gal/Gal.exe');
      final LibraryCtlImportResult result = (await importer().importAll(
        <String>[p.join(tmp.path, 'Gal')],
        kind: LibraryCtlKind.game,
      )).single;
      expect(result.status, LibraryCtlImportStatus.imported);
      await games.load();
      expect(games.games.single.exePath, main);
    });

    test('模块关闭时不入库', () async {
      disabled = <LibraryCtlKind>{LibraryCtlKind.game};
      final LibraryCtlImportResult result = (await importer().importAll(
        <String>[touch('x.exe')],
      )).single;
      expect(result.status, LibraryCtlImportStatus.unsupported);
      await games.load();
      expect(games.games, isEmpty);
    });

    test('有声书只有字幕 + 音频 → 成独立字幕书（与发现页同一导入器）', () async {
      final EnginePaths previousPaths = enginePaths;
      final Future<Directory> Function()? previousDocsRoot =
          AudiobookStorage.documentsRootResolver;
      enginePaths = FixedEnginePaths(documents: tmp, support: tmp, temp: tmp);
      AudiobookStorage.documentsRootResolver = () async => tmp;
      addTearDown(() {
        enginePaths = previousPaths;
        AudiobookStorage.documentsRootResolver = previousDocsRoot;
      });
      final File srt = File(p.join(tmp.path, 'src', '銀河鉄道の夜.srt'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          '1\n00:00:00,000 --> 00:00:02,000\nジョバンニは走った。\n\n'
          '2\n00:00:02,000 --> 00:00:04,000\nカムパネルラもいた。\n',
        );
      final File mp3 = File(p.join(tmp.path, 'src', '01.mp3'))
        ..writeAsBytesSync(<int>[0, 1, 2, 3]);

      final LibraryCtlImportResult result = (await importer().importAll(
        <String>[srt.path, mp3.path],
        kind: LibraryCtlKind.audiobook,
      )).single;
      expect(
        result.status,
        LibraryCtlImportStatus.imported,
        reason: result.message,
      );
      final SrtBook book = (await SrtBookRepository(db).listAll()).single;
      expect(book.title, '銀河鉄道の夜');
      expect(result.keys, <String>[
        LibraryCtlKey(LibraryCtlStore.srt, book.uid).wire,
      ]);
    });

    test('有声书缺字幕 → unsupported 并说明缺什么', () async {
      final LibraryCtlImportResult result = (await importer().importAll(
        <String>[touch('book.txt'), touch('01.mp3')],
        kind: LibraryCtlKind.audiobook,
      )).single;
      expect(result.status, LibraryCtlImportStatus.unsupported);
      expect(
        result.message,
        libraryCtlBlockerMessage(
          DiscoveryImportBlocker.audiobookMissingSubtitle,
        ),
      );
    });
  });
}
