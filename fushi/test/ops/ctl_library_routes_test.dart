import 'dart:async';
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

import 'package:fushi/src/media/library_progress_reset.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/galgame_repository.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/ctl_audiobook_routes.dart';
import 'package:fushi/src/ops/ctl_library_entries.dart';
import 'package:fushi/src/ops/ctl_library_import.dart';
import 'package:fushi/src/ops/ctl_library_manage_routes.dart';
import 'package:fushi/src/ops/ctl_library_routes.dart';
import 'package:fushi/src/ops/ctl_library_shelf.dart';
import 'package:fushi/src/ops/ctl_manga_ocr_routes.dart';
import 'package:fushi/src/media/manga/manga_ocr_engine_probe.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/ops/ctl_reader_routes.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/reader/reader_session_remote.dart';
import 'package:fushi/src/utils/misc/collection_exporter.dart'
    show ExportFormat;
import 'package:fushi_engine/media/audiobook/audiobook_transcribe_import_queue.dart';
import 'package:fushi_engine/media/audiobook/audiobook_alignment_service.dart'
    show AudiobookAlignmentCancelled, throwIfAlignmentCancelled;
import 'package:fushi_engine/media/discovery/import/discovery_engine_importers.dart'
    show importTranscribedAudiobook;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_disclosure.dart';
import 'package:fushi/src/ops/ctl_library_tasks.dart';
import 'package:drift/drift.dart' show Value;
import 'package:fushi_engine/media/video/video_book_repository.dart';

/// 路由表构造期不碰 ref；只为满足 [OpContext] 的签名。
class _UnusedWidgetRef implements WidgetRef {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('路由表构造期不该读 ref');
}

/// 立即「转完」的转录端口：把字幕写到 [_out] 并返回它。
class _FakeTranscriber implements AudiobookTranscriber {
  _FakeTranscriber(this._out);

  final String _out;

  @override
  Future<String> transcribe(
    AudiobookTranscribeJob job, {
    required void Function(AudiobookTranscribeJobPhase phase, double? progress)
    onProgress,
    required AudiobookTranscribeCancelToken cancel,
  }) async {
    onProgress(AudiobookTranscribeJobPhase.transcribing, 1);
    File(_out).writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nx\n');
    return _out;
  }
}

/// 可编排的阅读页遥控面：记下收到的动作，快照按需给。
class _FakeReaderRemote implements ReaderSessionRemote {
  _FakeReaderRemote({this.snap, this.landed = true, this.percentOk = true});

  ReaderSessionSnapshot? snap;
  final bool landed;
  final bool percentOk;
  final List<String> calls = <String>[];

  @override
  ReaderSessionSnapshot? snapshot() => snap;

  @override
  Future<void> turnPage({required bool forward}) async =>
      calls.add(forward ? 'next' : 'prev');

  @override
  Future<bool> goToChapter(int chapterIndex, {double progress = 0}) async {
    calls.add('chapter:$chapterIndex@$progress');
    return landed;
  }

  @override
  Future<bool> goToBookPercent(double percent) async {
    calls.add('percent:$percent');
    return percentOk;
  }

  @override
  Future<bool> goToPage(int pageIndex) async {
    calls.add('page:$pageIndex');
    return landed;
  }
}

const ReaderSessionSnapshot _readerSnap = ReaderSessionSnapshot(
  kind: ReaderSessionKind.epub,
  bookKey: '猫',
  title: '吾輩は猫である',
  chapterIndex: 2,
  chapterCount: 10,
  chapterProgress: 0.25,
  currentChars: 250,
  totalChars: 1000,
  contentReady: true,
);

CtlRoute _route(List<CtlRoute> routes, String method, String pattern) => routes
    .singleWhere((CtlRoute r) => r.method == method && r.pattern == pattern);

Future<Object?> _call(
  CtlRoute route, {
  Map<String, Object?> body = const <String, Object?>{},
}) => route.handler(
  CtlCall(method: route.method, path: route.pattern, body: body),
);

Matcher _ctlFailure(int status) => throwsA(
  isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', status),
);

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
      OpContext(ref: _UnusedWidgetRef(), focusMainWindow: () async {}),
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
    expect(LibraryCtlImportStatus.queued.wireName, 'queued');
    expect(LibraryCtlImportStatus.queued.isFailure, isFalse);
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

    test('有声书缺字幕且本机不能转录 → unsupported 并说明缺什么', () async {
      final LibraryCtlImportResult result = (await importer().importAll(
        <String>[touch('book.txt'), touch('01.mp3')],
        kind: LibraryCtlKind.audiobook,
      )).single;
      expect(result.status, LibraryCtlImportStatus.unsupported);
      expect(result.message, kLibraryCtlTranscribeUnavailable);
    });

    test('有声书缺字幕且本机能转录 → 排进转录队列（正文与音频原样交给队列）', () async {
      final List<Map<String, Object?>> enqueued = <Map<String, Object?>>[];
      final LibraryCtlImporter withQueue = LibraryCtlImporter(
        db: db,
        galgameRepo: games,
        isKindEnabled: (LibraryCtlKind kind) => true,
        keepDuplicates: false,
        enqueueTranscription:
            ({
              required List<String> audioPaths,
              String? contentPath,
              required String title,
            }) async {
              enqueued.add(<String, Object?>{
                'audio': audioPaths,
                'content': contentPath,
                'title': title,
              });
              return 'job-1';
            },
      );
      final String text = touch('銀河鉄道の夜.txt');
      final String mp3 = touch('01.mp3');
      final LibraryCtlImportResult result = (await withQueue.importAll(<String>[
        text,
        mp3,
      ], kind: LibraryCtlKind.audiobook)).single;
      expect(result.status, LibraryCtlImportStatus.queued);
      expect(result.status.isFailure, isFalse);
      expect(result.message, contains('job-1'));
      expect(enqueued.single['audio'], <String>[mp3]);
      expect(enqueued.single['content'], text);
      expect(enqueued.single['title'], '銀河鉄道の夜');
      expect(await SrtBookRepository(db).listAll(), isEmpty);
    });
  });
  group('新增路由', () {
    final List<CtlRoute> routes = buildLibraryCtlRoutes(
      OpContext(ref: _UnusedWidgetRef(), focusMainWindow: () async {}),
    );

    test('书架管理 / 阅读器 / 有声书 / OCR 路由都已注册', () {
      final Set<String> registered = <String>{
        for (final CtlRoute r in routes) '${r.method} ${r.pattern}',
      };
      for (final String expected in <String>[
        'GET /api/admin/library/collections',
        'POST /api/admin/library/collections',
        'PUT /api/admin/library/collections/:id',
        'DELETE /api/admin/library/collections/:id',
        'POST /api/admin/library/collections/:id/members',
        'DELETE /api/admin/library/collections/:id/members',
        'PUT /api/admin/library/collections/:id/cover',
        'POST /api/admin/library/collections/:id/tags',
        'GET /api/admin/library/tags',
        'PUT /api/admin/library/tags/:id',
        'POST /api/admin/library/items/:key/tags',
        'POST /api/admin/library/items/:key/bookmarks',
        'DELETE /api/admin/library/bookmarks/:id',
        'POST /api/admin/library/favorites/export',
        'PUT /api/admin/library/items/:key/title',
        'PUT /api/admin/library/items/:key/cover',
        'PUT /api/admin/library/items/:key/completed',
        'POST /api/admin/library/items/:key/reset',
        'POST /api/admin/library/sources',
        'DELETE /api/admin/library/sources/:id',
        'GET /api/admin/library/reader',
        'POST /api/admin/library/reader/goto',
        'POST /api/admin/library/items/:key/audiobook',
        'POST /api/admin/library/items/:key/audiobook/rematch',
        'POST /api/admin/library/audiobook/jobs',
        'POST /api/admin/library/audiobook/jobs/:id/cancel',
        'POST /api/admin/library/ocr',
        'POST /api/admin/library/ocr/cancel',
      ]) {
        expect(registered, contains(expected));
      }
    });

    test('条目子路由按编码后的键匹配', () {
      final CtlRoute tags = _route(
        routes,
        'POST',
        '/api/admin/library/items/:key/tags',
      );
      final String encoded = Uri.encodeComponent('book:a/b c');
      expect(
        tags.match('/api/admin/library/items/$encoded/tags'),
        <String, String>{'key': 'book:a/b c'},
      );
    });
  });

  group('library open 位置解析', () {
    test('EPUB：--chapter / --at 换成章下标，--progress 换成 0–10000 分数', () {
      final LibraryCtlOpenPosition pos = parseLibraryCtlOpenPosition(
        format: BookFormat.epub,
        chapter: 3,
        progress: 25,
      );
      expect(pos.sectionIndex, 2);
      expect(pos.normCharOffset, 2500);
      expect(
        parseLibraryCtlOpenPosition(
          format: BookFormat.epub,
          at: '5',
        ).sectionIndex,
        4,
      );
      expect(
        parseLibraryCtlOpenPosition(format: BookFormat.epub).sectionIndex,
        isNull,
      );
    });

    test('PDF 只认 --page；漫画认 --chapter + --page', () {
      expect(
        parseLibraryCtlOpenPosition(
          format: BookFormat.pdf,
          page: 9,
        ).sectionIndex,
        8,
      );
      final LibraryCtlOpenPosition manga = parseLibraryCtlOpenPosition(
        format: BookFormat.manga,
        chapter: 2,
        page: 4,
      );
      expect(manga.chapterIndex, 1);
      expect(manga.pageIndex, 3);
      expect(manga.sectionIndex, isNull);
    });

    test('不合法的组合一律报错', () {
      void bad(void Function() fn) =>
          expect(fn, throwsA(isA<LibraryCtlPositionError>()));
      bad(() => parseLibraryCtlOpenPosition(format: BookFormat.epub, page: 1));
      bad(
        () => parseLibraryCtlOpenPosition(
          format: BookFormat.epub,
          at: '1',
          chapter: 1,
        ),
      );
      bad(
        () =>
            parseLibraryCtlOpenPosition(format: BookFormat.epub, progress: 10),
      );
      bad(
        () => parseLibraryCtlOpenPosition(
          format: BookFormat.epub,
          chapter: 1,
          progress: 120,
        ),
      );
      bad(() => parseLibraryCtlOpenPosition(format: BookFormat.epub, at: 'x'));
      bad(
        () => parseLibraryCtlOpenPosition(format: BookFormat.pdf, chapter: 1),
      );
      bad(() => parseLibraryCtlOpenPosition(format: BookFormat.pdf, page: 0));
      bad(() => parseLibraryCtlOpenPosition(format: BookFormat.manga, at: '1'));
    });
  });

  group('参数换算', () {
    test('颜色 #RRGGBB ↔ ARGB', () {
      expect(parseLibraryCtlColor('#FF0000'), 0xFFFF0000);
      expect(parseLibraryCtlColor('00ff00'), 0xFF00FF00);
      expect(parseLibraryCtlColor('#80112233'), 0x80112233);
      expect(parseLibraryCtlColor('red'), isNull);
      expect(formatLibraryCtlColor(0xFFFF0000), '#FF0000');
      expect(formatLibraryCtlColor(0x80112233), '#80112233');
    });

    test('reset --stats 与导出格式', () {
      expect(parseLibraryCtlResetScope(null), StudyRecordResetScope.keep);
      expect(
        parseLibraryCtlResetScope('last'),
        StudyRecordResetScope.lastSession,
      );
      expect(parseLibraryCtlResetScope('all'), StudyRecordResetScope.all);
      expect(parseLibraryCtlResetScope('x'), isNull);
      expect(parseLibraryCtlExportFormat('md'), ExportFormat.markdown);
      expect(parseLibraryCtlExportFormat('csv'), ExportFormat.csv);
      expect(parseLibraryCtlExportFormat(null), ExportFormat.markdown);
      expect(parseLibraryCtlExportFormat('docx'), isNull);
    });

    test('转录任务 / OCR 任务的线上形状', () {
      final AudiobookTranscribeJob job = AudiobookTranscribeJob(
        id: '1-0',
        title: '銀河',
        audioPaths: const <String>['/a.mp3', '/b.mp3'],
        createdAt: 1,
        updatedAt: 2,
        status: AudiobookTranscribeJobStatus.running,
        phase: AudiobookTranscribeJobPhase.transcribing,
        progress: 0.4237,
      );
      expect(audiobookCtlJobJson(job), <String, Object?>{
        'id': '1-0',
        'title': '銀河',
        'status': 'running',
        'phase': 'transcribing',
        'progress': 42.4,
        'audioFiles': 2,
        'createdAt': 1,
        'updatedAt': 2,
      });
      expect(
        mangaOcrCtlJobJson(
          bookKey: 'm',
          directory: null,
          lastEvent: null,
          queuedDirectories: const <String>['/x/c2'],
          ended: false,
          cancelled: false,
        ),
        <String, Object?>{'key': 'book:m', 'state': 'queued', 'queued': 1},
      );
    });
  });

  group('阅读会话遥控路由', () {
    late ReaderSessionRemoteRegistry registry;
    late List<CtlRoute> routes;

    setUp(() {
      registry = ReaderSessionRemoteRegistry();
      routes = buildReaderCtlRoutes(
        OpContext(
          ref: _UnusedWidgetRef(),
          focusMainWindow: () async {},
        ),
        registry: registry,
      );
    });

    test('没有阅读页：status 报 inactive，动作 409', () async {
      expect(
        await _call(_route(routes, 'GET', kReaderCtlPath)),
        <String, Object?>{'active': false},
      );
      expect(
        () => _call(_route(routes, 'POST', '$kReaderCtlPath/turn')),
        _ctlFailure(409),
      );
    });

    test('status 换成 1 起计章号与百分比', () async {
      registry.register(_FakeReaderRemote(snap: _readerSnap));
      expect(
        await _call(_route(routes, 'GET', kReaderCtlPath)),
        <String, Object?>{
          'active': true,
          'kind': 'epub',
          'key': 'book:猫',
          'title': '吾輩は猫である',
          'chapter': 3,
          'chapterCount': 10,
          'chapterProgress': 25.0,
          'percent': 25.0,
          'ready': true,
        },
      );
    });

    test('turn 按 count 逐页转调；越界 400', () async {
      final _FakeReaderRemote remote = _FakeReaderRemote(snap: _readerSnap);
      registry.register(remote);
      final CtlRoute turn = _route(routes, 'POST', '$kReaderCtlPath/turn');
      await _call(
        turn,
        body: <String, Object?>{'direction': 'prev', 'count': 3},
      );
      expect(remote.calls, <String>['prev', 'prev', 'prev']);
      expect(
        () => _call(turn, body: <String, Object?>{'count': 0}),
        _ctlFailure(400),
      );
      expect(
        () => _call(turn, body: <String, Object?>{'direction': 'up'}),
        _ctlFailure(400),
      );
    });

    test('goto：章号 1 起计换下标、progress 换分数；百分比；校验与落定失败', () async {
      final _FakeReaderRemote remote = _FakeReaderRemote(snap: _readerSnap);
      registry.register(remote);
      final CtlRoute go = _route(routes, 'POST', '$kReaderCtlPath/goto');
      await _call(go, body: <String, Object?>{'chapter': 4, 'progress': 50});
      await _call(go, body: <String, Object?>{'percent': 75});
      expect(remote.calls, <String>['chapter:3@0.5', 'percent:75.0']);
      expect(
        () => _call(go, body: <String, Object?>{'chapter': 11}),
        _ctlFailure(400),
      );
      expect(
        () => _call(go, body: <String, Object?>{'chapter': 1, 'percent': 5}),
        _ctlFailure(400),
      );
      expect(() => _call(go), _ctlFailure(400));

      registry
        ..unregister(remote)
        ..register(
          _FakeReaderRemote(snap: _readerSnap, landed: false, percentOk: false),
        );
      expect(
        () => _call(go, body: <String, Object?>{'chapter': 1}),
        _ctlFailure(409),
      );
      expect(
        () => _call(go, body: <String, Object?>{'percent': 1}),
        _ctlFailure(409),
      );
    });
  });

  group('LibraryCtlShelf（内存库）', () {
    late FushiDatabase db;
    late GalgameRepository games;
    late LibraryCtlShelf shelf;
    late Directory tmp;

    Future<String> addBook(
      String bookKey, {
      String format = 'epub',
      int chapters = 5,
    }) async {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: bookKey,
          title: bookKey,
          epubPath: '/x/$bookKey.epub',
          extractDir: '/x/$bookKey',
          chapterCount: chapters,
          chaptersJson: '[]',
          importedAt: 1000,
          format: Value<String>(format),
        ),
      );
      return (await db.resolveEpubBookUid(bookKey))!;
    }

    Future<void> addVideo(String uid) => db
        .into(db.videoBooks)
        .insert(
          VideoBooksCompanion.insert(
            bookUid: uid,
            title: uid,
            videoPath: '/v/$uid.mkv',
          ),
        );

    LibraryCtlKey key(String wire) => LibraryCtlKey.tryParse(wire)!;

    setUp(() {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      games = GalgameRepository(db);
      shelf = LibraryCtlShelf(db: db, galgameRepo: games);
      tmp = Directory.systemTemp.createTempSync('fushi_ctl_shelf_');
    });

    tearDown(() async {
      await db.close();
      tmp.deleteSync(recursive: true);
    });

    test('合集：新建（同名复用）→ 加成员（epub 落 uid）→ 详情 → 改名 → 移出 → 删除', () async {
      final String uid = await addBook('猫');
      final Map<String, Object?> created = await shelf.createCollection('夏');
      expect(created['existed'], isFalse);
      final int id = created['id']! as int;
      expect((await shelf.createCollection('夏'))['existed'], isTrue);

      final Map<String, Object?> added = await shelf.addMembers(
        id,
        <LibraryCtlKey>[key('book:猫'), key('book:猫')],
      );
      expect(
        (added['results']! as List<Object?>).map(
          (Object? r) => (r! as Map<String, Object?>)['status'],
        ),
        <String>['added', 'already'],
      );
      final MediaCollectionItemRow member = (await db.getCollectionItems(
        id,
      )).single;
      expect(member.mediaType, MediaKind.epub.dbValue);
      expect(member.entryKey, uid);
      expect(await shelf.keyForCollectionMember(member), key('book:猫'));

      final List<Map<String, Object?>> listed = await shelf.listCollections(
        containing: key('book:猫'),
      );
      expect(listed.single['members'], 1);

      expect((await shelf.renameCollection(id, '秋'))['name'], '秋');
      await shelf.createCollection('冬');
      final int winter = (await shelf.createCollection('冬'))['id']! as int;
      expect(() => shelf.renameCollection(winter, '秋'), _ctlFailure(409));

      final Map<String, Object?> removed = await shelf.removeMembers(
        id,
        <LibraryCtlKey>[key('book:猫')],
      );
      expect(removed['collectionDeleted'], isTrue);

      expect((await shelf.deleteCollection(winter))['deleted'], isTrue);
      expect(() => shelf.deleteCollection(winter), _ctlFailure(404));
    });

    test('合集：不同库页的条目拒绝混装；条目不存在 404', () async {
      await addBook('猫');
      await addVideo('v1');
      final int id = (await shelf.createCollection('混'))['id']! as int;
      await shelf.addMembers(id, <LibraryCtlKey>[key('book:猫')]);
      final Map<String, Object?> result = await shelf.addMembers(
        id,
        <LibraryCtlKey>[key('video:v1')],
      );
      expect(result['ok'], isFalse);
      expect(
        ((result['results']! as List<Object?>).single!
            as Map<String, Object?>)['status'],
        'rejected',
      );
      expect((await db.getCollectionItems(id)), hasLength(1));
      expect(
        () => shelf.addMembers(id, <LibraryCtlKey>[key('book:没有')]),
        _ctlFailure(404),
      );
    });

    test('标签：新建 / 重名 409 / 打标签（epub 按 bookKey，--create）/ 改名 / 摘 / 删', () async {
      await addBook('猫');
      final Map<String, Object?> tag = await shelf.createTag(
        '名作',
        color: 0xFFFF0000,
      );
      expect(tag['color'], '#FF0000');
      expect(() => shelf.createTag('名作'), _ctlFailure(409));

      final Map<String, Object?> added = await shelf.addTags(<String>[
        '名作',
        '新标签',
        '不存在',
      ], key: key('book:猫'));
      expect(added['ok'], isFalse);
      final Map<String, Object?> created = await shelf.addTags(
        <String>['新标签'],
        key: key('book:猫'),
        create: true,
      );
      expect(
        ((created['results']! as List<Object?>).single!
            as Map<String, Object?>)['status'],
        'added',
      );
      expect(
        (await db.getTagsForBook('猫')).map((BookTagRow t) => t.name).toSet(),
        <String>{'名作', '新标签'},
      );
      expect(
        ((await shelf.itemTags(key('book:猫')))['tags']! as List<Object?>),
        hasLength(2),
      );

      final int tagId = tag['id']! as int;
      expect((await shelf.updateTag(tagId, name: '傑作'))['name'], '傑作');
      expect(() => shelf.updateTag(tagId), _ctlFailure(400));

      await shelf.removeTags(<String>['傑作'], key: key('book:猫'));
      expect(
        (await db.getTagsForBook('猫')).map((BookTagRow t) => t.name),
        <String>['新标签'],
      );
      expect((await shelf.deleteTag(tagId))['deleted'], isTrue);
      expect(() => shelf.deleteTag(tagId), _ctlFailure(404));
    });

    test('标签也能打到合集上', () async {
      final int id = (await shelf.createCollection('C'))['id']! as int;
      await shelf.addTags(<String>['甲'], collectionId: id, create: true);
      expect(
        (await db.getTagsForCollection(id)).map((BookTagRow t) => t.name),
        <String>['甲'],
      );
    });

    test('书签：EPUB 章 + 章内进度、PDF 页；格式不符报错；删除', () async {
      await addBook('猫');
      await addBook('文書', format: 'pdf', chapters: 30);
      final Map<String, Object?> epubMark = await shelf.addBookmark(
        key('book:猫'),
        chapter: 2,
        progressPercent: 50,
      );
      expect(epubMark['chapter'], 2);
      expect(epubMark['progress'], 50);
      expect(epubMark['label'], 'Ch.2');
      final Map<String, Object?> pdfMark = await shelf.addBookmark(
        key('book:文書'),
        page: 7,
        label: '图表',
      );
      expect(pdfMark['page'], 7);
      expect(pdfMark['label'], '图表');

      expect(() => shelf.addBookmark(key('book:猫'), page: 1), _ctlFailure(400));
      expect(
        () => shelf.addBookmark(key('book:猫'), chapter: 9),
        _ctlFailure(400),
      );
      expect(
        () => shelf.addBookmark(key('book:文書'), page: 31),
        _ctlFailure(400),
      );
      expect(() => shelf.listBookmarks(key('video:v')), _ctlFailure(422));

      final List<Object?> marks =
          (await shelf.listBookmarks(key('book:猫')))['bookmarks']!
              as List<Object?>;
      expect(marks, hasLength(1));
      final int id = epubMark['id']! as int;
      expect((await shelf.removeBookmark(id))['deleted'], isTrue);
      expect(() => shelf.removeBookmark(id), _ctlFailure(404));
    });

    test('收藏句：按条目筛、删除、导出、清空', () async {
      await addBook('猫');
      await addVideo('v1');
      final FavoriteSentenceRepository repo = FavoriteSentenceRepository(db);
      await repo.add(
        FavoriteSentence(
          text: '吾輩は猫である。',
          bookTitle: '猫',
          bookKey: '猫',
          createdAt: DateTime(2026, 1, 1),
        ),
      );
      await repo.add(
        FavoriteSentence(
          text: '名前はまだ無い。',
          bookTitle: 'v1',
          bookKey: 'v1',
          source: 'video',
          createdAt: DateTime(2026, 1, 2),
        ),
      );
      final Map<String, Object?> all = await shelf.listFavorites();
      expect(all['total'], 2);
      final Map<String, Object?> onlyBook = await shelf.listFavorites(
        key: key('book:猫'),
      );
      expect(onlyBook['total'], 1);
      final String favId =
          ((onlyBook['favorites']! as List<Object?>).single!
                  as Map<String, Object?>)['id']!
              as String;

      final String out = p.join(tmp.path, 'out', 'fav.json');
      final Map<String, Object?> exported = await shelf.exportFavorites(
        outPath: out,
        format: ExportFormat.json,
        key: key('video:v1'),
      );
      expect(exported['count'], 1);
      expect(File(out).readAsStringSync(), contains('名前はまだ無い。'));

      expect((await shelf.removeFavorite(favId))['deleted'], isTrue);
      expect(() => shelf.removeFavorite(favId), _ctlFailure(404));
      expect((await shelf.clearFavorites())['cleared'], 1);
      expect(
        () => shelf.exportFavorites(outPath: out, format: ExportFormat.json),
        _ctlFailure(422),
      );
    });

    test('读完标记：书写 completedAt、视频只能标记看完、游戏拒绝', () async {
      await addBook('猫');
      await addVideo('v1');
      await shelf.setCompleted(key('book:猫'), completed: true);
      expect((await db.getEpubBook('猫'))!.completedAt, isNotNull);
      await shelf.setCompleted(key('book:猫'), completed: false);
      expect((await db.getEpubBook('猫'))!.completedAt, isNull);
      await shelf.setCompleted(key('video:v1'), completed: true);
      expect(
        (await VideoBookRepository(db).getByBookUid('v1'))!.completedAt,
        isNotNull,
      );
      expect(
        () => shelf.setCompleted(key('video:v1'), completed: false),
        _ctlFailure(422),
      );
      expect(
        () => shelf.setCompleted(key('game:g'), completed: true),
        _ctlFailure(422),
      );
    });

    test('游戏条目：合集身份是 galgames.id，不存在 404', () async {
      await games.addAll(<GalgameEntry>[
        newGalgameEntryFromExe('/g/game.exe', now: DateTime(2026)),
      ]);
      final String gameId = games.games.single.id;
      final MediaRef ref = await shelf.collectionRefFor(key('game:$gameId'));
      expect(ref.kind, MediaKind.game);
      expect(ref.entryKey, gameId);
      expect(() => shelf.collectionRefFor(key('game:nope')), _ctlFailure(404));
    });
  });
  group('阅读器种类与 goto 解析', () {
    const ReaderSessionSnapshot pdf = ReaderSessionSnapshot(
      kind: ReaderSessionKind.pdf,
      bookKey: '文書',
      title: '文書',
      contentReady: true,
      pageIndex: 2,
      pageCount: 30,
    );
    const ReaderSessionSnapshot localManga = ReaderSessionSnapshot(
      kind: ReaderSessionKind.manga,
      bookKey: 'm',
      title: 'm',
      contentReady: true,
      pageIndex: 0,
      pageCount: 20,
    );
    const ReaderSessionSnapshot onlineManga = ReaderSessionSnapshot(
      kind: ReaderSessionKind.manga,
      bookKey: 'o',
      title: 'o',
      contentReady: true,
      pageIndex: 4,
      pageCount: 20,
      chapterIndex: 1,
      chapterCount: 9,
    );

    test('PDF / 漫画只认页码，在线漫画另认话；越界与不适用的方式 400', () {
      expect(
        (parseReaderCtlGoto(pdf, page: 30) as ReaderCtlGotoPage).index,
        29,
      );
      expect(
        (parseReaderCtlGoto(onlineManga, chapter: 3) as ReaderCtlGotoChapter)
            .index,
        2,
      );
      expect(
        (parseReaderCtlGoto(_readerSnap, percent: 40) as ReaderCtlGotoPercent)
            .percent,
        40,
      );
      void bad(void Function() fn) => expect(fn, throwsA(isA<CtlFailure>()));
      bad(() => parseReaderCtlGoto(pdf, page: 31));
      bad(() => parseReaderCtlGoto(pdf, chapter: 1));
      bad(() => parseReaderCtlGoto(localManga, chapter: 1));
      bad(() => parseReaderCtlGoto(localManga, percent: 3));
      bad(() => parseReaderCtlGoto(_readerSnap, page: 1));
      bad(() => parseReaderCtlGoto(pdf, page: 1, chapter: 1));
      bad(() => parseReaderCtlGoto(pdf));
    });

    test('快照 JSON 只带适用字段；路由 goto --page 转调 goToPage', () async {
      expect(readerCtlSnapshotJson(pdf), <String, Object?>{
        'active': true,
        'kind': 'pdf',
        'key': 'book:文書',
        'title': '文書',
        'page': 3,
        'pageCount': 30,
        'ready': true,
      });
      final ReaderSessionRemoteRegistry registry =
          ReaderSessionRemoteRegistry();
      final _FakeReaderRemote remote = _FakeReaderRemote(snap: pdf);
      registry.register(remote);
      final List<CtlRoute> routes = buildReaderCtlRoutes(
        OpContext(
          ref: _UnusedWidgetRef(),
          focusMainWindow: () async {},
        ),
        registry: registry,
      );
      await _call(
        _route(routes, 'POST', '$kReaderCtlPath/goto'),
        body: <String, Object?>{'page': 7},
      );
      expect(remote.calls, <String>['page:6']);
    });
  });

  group('挂载 / 匹配任务登记表', () {
    test('完成落 result；失败经 describe；同键查询 activeFor', () async {
      final LibraryCtlTaskRegistry registry = LibraryCtlTaskRegistry();
      final Completer<void> gate = Completer<void>();
      final LibraryCtlTask ok = registry.start(
        kind: 'attach',
        key: 'book:a',
        run: (LibraryCtlTask task) async {
          task.report(phase: 'matching', progress: 0.5);
          await gate.future;
          return <String, Object?>{'cues': 3};
        },
        describe: (Object e) => 'X',
      );
      expect(registry.activeFor('book:a'), same(ok));
      expect(ok.toJson()['phase'], 'matching');
      expect(ok.toJson()['progress'], 50.0);
      gate.complete();
      await ok.whenDone;
      expect(ok.status, LibraryCtlTaskStatus.done);
      expect(ok.result, <String, Object?>{'cues': 3});
      expect(registry.activeFor('book:a'), isNull);

      final LibraryCtlTask failed = registry.start(
        kind: 'rematch',
        key: 'book:b',
        run: (LibraryCtlTask task) async => throw StateError('boom'),
        describe: (Object e) => '炸了',
      );
      await failed.whenDone;
      expect(failed.status, LibraryCtlTaskStatus.failed);
      expect(failed.error, '炸了');
    });

    test('取消：检查点前请求 → cancelled；进入提交阶段后拒绝；已结束报 finished', () async {
      final LibraryCtlTaskRegistry registry = LibraryCtlTaskRegistry();
      final Completer<void> reachCheckpoint = Completer<void>();
      final LibraryCtlTask cancellable = registry.start(
        kind: 'attach',
        key: 'book:c',
        run: (LibraryCtlTask task) async {
          await reachCheckpoint.future;
          throwIfAlignmentCancelled(() => task.cancelRequested);
          return <String, Object?>{};
        },
        describe: (Object e) => '$e',
      );
      expect(registry.cancel(cancellable), LibraryCtlCancelOutcome.requested);
      expect(cancellable.toJson()['cancelRequested'], isTrue);
      reachCheckpoint.complete();
      await cancellable.whenDone;
      expect(cancellable.status, LibraryCtlTaskStatus.cancelled);
      expect(registry.cancel(cancellable), LibraryCtlCancelOutcome.finished);

      final Completer<void> hold = Completer<void>();
      final LibraryCtlTask committing = registry.start(
        kind: 'attach',
        key: 'book:d',
        run: (LibraryCtlTask task) async {
          task.markCommitting();
          await hold.future;
          return <String, Object?>{};
        },
        describe: (Object e) => '$e',
      );
      await Future<void>.delayed(Duration.zero);
      expect(committing.toJson()['cancellable'], isFalse);
      expect(registry.cancel(committing), LibraryCtlCancelOutcome.committing);
      hold.complete();
      await committing.whenDone;
      expect(committing.status, LibraryCtlTaskStatus.done);
    });

    test('取消检查点：throwIfAlignmentCancelled', () {
      expect(() => throwIfAlignmentCancelled(null), returnsNormally);
      expect(() => throwIfAlignmentCancelled(() => false), returnsNormally);
      expect(
        () => throwIfAlignmentCancelled(() => true),
        throwsA(isA<AudiobookAlignmentCancelled>()),
      );
    });
  });

  group('转录队列：挂到已有书', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('fushi_ctl_tq_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('targetBookKey 交给入库端口、落盘往返；与 contentPath 互斥', () async {
      final List<String?> importedTargets = <String?>[];
      final File store = File(p.join(tmp.path, 'jobs.json'));
      final AudiobookTranscribeImportQueue queue =
          AudiobookTranscribeImportQueue(
            store: store,
            transcriber: _FakeTranscriber(p.join(tmp.path, 'out.srt')),
            importer:
                (
                  AudiobookTranscribeJob job,
                  String subtitle,
                  AudiobookTranscribeImportSink sink,
                ) async {
                  importedTargets.add(job.targetBookKey);
                  return job.targetBookKey;
                },
          );
      final AudiobookTranscribeJob job = await queue.enqueue(
        audioPaths: const <String>['/a.mp3'],
        targetBookKey: '猫',
        title: '猫',
      );
      expect(job.targetBookKey, '猫');
      expect(
        () => queue.enqueue(
          audioPaths: const <String>['/b.mp3'],
          contentPath: '/b.txt',
          targetBookKey: '猫',
          title: 'x',
        ),
        throwsArgumentError,
      );
      while (!job.isTerminal) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await queue.close();
      expect(job.status, AudiobookTranscribeJobStatus.done);
      expect(importedTargets, <String?>['猫']);
      expect(job.resultKey, '猫');
      expect(audiobookCtlJobJson(job)['into'], 'book:猫');
      final AudiobookTranscribeJob reloaded = AudiobookTranscribeJob.fromJson(
        job.toJson(),
      );
      expect(reloaded.targetBookKey, '猫');
    });

    test('入库：目标书已不在库 → StateError，不悄悄新建书', () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      await expectLater(
        importTranscribedAudiobook(
          db: db,
          srtBookRepo: SrtBookRepository(db),
          audiobookRepo: AudiobookRepository(db),
          subtitlePath: p.join(tmp.path, 'x.srt'),
          audioPaths: const <String>[],
          targetBookKey: '没有',
          title: '没有',
        ),
        throwsStateError,
      );
      expect(await db.getEpubBookMetas(), isEmpty);
    });
  });

  test('Google Lens 上传同意：记录与查询同一个键', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    expect(await hasGoogleLensDisclosure(), isFalse);
    await recordGoogleLensDisclosureAccepted();
    expect(await hasGoogleLensDisclosure(), isTrue);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getInt(kGoogleLensDisclosurePreferenceKey),
      kGoogleLensDisclosureVersion,
    );
    expect(
      await hasGoogleLensDisclosure(
        scene: GoogleLensDisclosureScene.videoFrames,
      ),
      isFalse,
    );
  });
  group('ocr start --engine', () {
    test('值域 = 偏好键去掉 auto，与 CLI 一致；解析严格', () {
      expect(kMangaOcrCtlEngineKeys, <String>[
        'local_onnx',
        'system_ocr',
        'google_lens',
        'external_mokuro',
        'paired_host',
      ]);
      expect(parseMangaOcrCtlEngine('local_onnx'), MangaOcrEngineId.localOnnx);
      expect(
        parseMangaOcrCtlEngine('paired_host'),
        MangaOcrEngineId.pairedHost,
      );
      expect(parseMangaOcrCtlEngine('auto'), isNull);
      expect(parseMangaOcrCtlEngine('lens'), isNull);
    });

    test('可用引擎按向导同一判据 isUsable 列出', () {
      const MangaOcrEngineAvailability onlyLensAndSystem =
          MangaOcrEngineAvailability(
            builtinSupported: true,
            builtinReady: false,
            externalOffered: false,
            externalReady: false,
            lensOffered: true,
            remoteOffered: false,
            remoteTarget: null,
            systemOcrOffered: true,
            systemOcrReady: true,
          );
      expect(mangaOcrCtlUsableEngineKeys(onlyLensAndSystem), <String>[
        'system_ocr',
        'google_lens',
      ]);
    });
  });
}
