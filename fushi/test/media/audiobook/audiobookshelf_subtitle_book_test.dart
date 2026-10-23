// Audiobookshelf 远端字幕书的真实导入链路：解析字幕 → 按音轨偏移切时间轴 → 生成
// 正文 EPUB → 落 SrtBook → 写绑定；绑定写失败整体回滚；服务器重扫后按新偏移重切；
// 取服务器上的字幕文件。走真实的 EpubImporter 与内存数据库。
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/book_title_conflict.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_api.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_models.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_subtitle_book.dart';
import 'package:path/path.dart' as p;

// 三条轨：[0,1000) [1000,3000) [3000,3500)（全书时间轴，毫秒）。
const List<RemoteAudioTrack> _tracks = <RemoteAudioTrack>[
  RemoteAudioTrack(ino: '10', startOffsetMs: 0, durationMs: 1000),
  RemoteAudioTrack(ino: '11', startOffsetMs: 1000, durationMs: 2000),
  RemoteAudioTrack(ino: '12', startOffsetMs: 3000, durationMs: 500),
];

const String _srt = '''1
00:00:00,100 --> 00:00:00,900
一つ目の文です。

2
00:00:01,200 --> 00:00:01,800
二つ目の文です。

3
00:00:02,500 --> 00:00:02,900
三つ目の文です。

4
00:00:03,100 --> 00:00:03,400
四つ目の文です。
''';

class _FailingBindings extends RemoteAudioBindingRepository {
  _FailingBindings(super.db);

  @override
  Future<void> save(RemoteAudioBinding binding) =>
      Future<void>.error(StateError('disk full'));
}

List<(int, int, int)> _placed(List<AudioCue> cues) => <(int, int, int)>[
  for (final AudioCue c in cues) (c.audioFileIndex, c.startMs, c.endMs),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory work;
  late Directory docs;
  late Directory books;
  late FushiDatabase db;
  late SrtBookRepository repo;
  late RemoteAudioBindingRepository bindings;

  setUp(() {
    work = Directory.systemTemp.createTempSync('abs_subbook_work_');
    docs = Directory.systemTemp.createTempSync('abs_subbook_docs_');
    books = Directory.systemTemp.createTempSync('abs_subbook_books_');
    AudiobookStorage.documentsRootResolver = () async => docs;
    EpubStorage.debugBaseDirectoryOverride = books.path;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = SrtBookRepository(db);
    bindings = RemoteAudioBindingRepository(db);
  });

  tearDown(() async {
    await db.close();
    AudiobookStorage.documentsRootResolver = null;
    EpubStorage.debugBaseDirectoryOverride = null;
    for (final Directory d in <Directory>[work, docs, books]) {
      try {
        if (d.existsSync()) d.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  String writeSrt([String content = _srt]) {
    final String path = p.join(work.path, 'Fables.srt');
    File(path).writeAsStringSync(content);
    return path;
  }

  Future<SrtBook> importIt(
    WidgetTester tester, {
    RemoteAudioBindingRepository? bindingRepo,
    String origin = RemoteAudioBinding.subtitleOriginLocal,
  }) async => (await tester.runAsync(
    () => importAudiobookshelfSubtitleBook(
      db: db,
      repo: repo,
      bindings: bindingRepo ?? bindings,
      serverConfigId: 'srv',
      itemId: 'item_1',
      tracks: _tracks,
      title: 'Fables',
      subtitlePath: writeSrt(),
      subtitleOrigin: origin,
      policy: const DuplicatePolicy.suffix(),
      tempDir: work,
    ),
  ))!;

  testWidgets('导入：cue 按音轨切成本地时间，音频路径为空，绑定写入', (WidgetTester tester) async {
    final SrtBook book = await importIt(
      tester,
      origin: RemoteAudioBinding.subtitleOriginServer('20'),
    );

    expect(book.title, 'Fables');
    expect(book.bookKey, isNotEmpty, reason: '有正文 EPUB');
    expect(book.audioPaths, isNull, reason: '音频在服务器上，本机路径列保持为空');
    expect(book.audioRoot, isNull);

    final List<AudioCue> cues = (await tester.runAsync(
      () => repo.cuesFor(book.uid),
    ))!;
    expect(_placed(cues), <(int, int, int)>[
      (0, 100, 900),
      (1, 200, 800),
      (1, 1500, 1900),
      (2, 100, 400),
    ]);

    final RemoteAudioBinding binding = (await tester
        .runAsync<RemoteAudioBinding?>(() => bindings.get(book.uid)))!;
    expect(binding.itemId, 'item_1');
    expect(binding.serverConfigId, 'srv');
    expect(binding.episodeId, isNull);
    expect(binding.tracks, _tracks);
    expect(binding.serverSubtitleIno, '20');
  });

  testWidgets('绑定写失败：回滚字幕书与正文 EPUB，原样抛出', (WidgetTester tester) async {
    final String subtitlePath = writeSrt();
    final Object? error = await tester.runAsync<Object?>(() async {
      try {
        await importAudiobookshelfSubtitleBook(
          db: db,
          repo: repo,
          bindings: _FailingBindings(db),
          serverConfigId: 'srv',
          itemId: 'item_1',
          tracks: _tracks,
          title: 'Fables',
          subtitlePath: subtitlePath,
          policy: const DuplicatePolicy.suffix(),
          tempDir: work,
        );
        return null;
      } catch (e) {
        return e;
      }
    });
    expect(error, isA<StateError>());
    await tester.runAsync(() async {
      expect(await repo.listAll(), isEmpty, reason: '不留没有音频来源的半成品');
      expect(await db.getAllEpubBooks(), isEmpty);
      expect(await bindings.listAll(), isEmpty);
    });
  });

  testWidgets('没有音轨 → ArgumentError，不落任何行', (WidgetTester tester) async {
    await expectLater(
      importAudiobookshelfSubtitleBook(
        db: db,
        repo: repo,
        bindings: bindings,
        serverConfigId: 'srv',
        itemId: 'item_1',
        tracks: const <RemoteAudioTrack>[],
        title: 'Fables',
        subtitlePath: writeSrt(),
        policy: const DuplicatePolicy.suffix(),
        tempDir: work,
      ),
      throwsArgumentError,
    );
    await tester.runAsync(() async => expect(await repo.listAll(), isEmpty));
  });

  testWidgets('服务器重扫：音轨变了按新偏移重切，没变不动', (WidgetTester tester) async {
    final SrtBook book = await importIt(tester);

    // 没变 → false。
    expect(
      await tester.runAsync(
        () => resplitAudiobookshelfSubtitleBook(
          repo: repo,
          bindings: bindings,
          srtBookUid: book.uid,
          currentTracks: _tracks,
        ),
      ),
      isFalse,
    );

    // 服务器重扫后第一轨变长了：后面的轨整体后移。
    const List<RemoteAudioTrack> rescanned = <RemoteAudioTrack>[
      RemoteAudioTrack(ino: '10', startOffsetMs: 0, durationMs: 2000),
      RemoteAudioTrack(ino: '11', startOffsetMs: 2000, durationMs: 1000),
      RemoteAudioTrack(ino: '12', startOffsetMs: 3000, durationMs: 500),
    ];
    expect(
      await tester.runAsync(
        () => resplitAudiobookshelfSubtitleBook(
          repo: repo,
          bindings: bindings,
          srtBookUid: book.uid,
          currentTracks: rescanned,
        ),
      ),
      isTrue,
    );

    final List<AudioCue> cues = (await tester.runAsync(
      () => repo.cuesFor(book.uid),
    ))!;
    expect(_placed(cues), <(int, int, int)>[
      (0, 100, 900),
      (0, 1200, 1800),
      (1, 500, 900),
      (2, 100, 400),
    ]);
    final RemoteAudioBinding binding = (await tester
        .runAsync<RemoteAudioBinding?>(() => bindings.get(book.uid)))!;
    expect(binding.tracks, rescanned);
    expect(binding.sameTracksAs(rescanned), isTrue);

    // 再来一次同样的音轨 → 已是最新，不再重切。
    expect(
      await tester.runAsync(
        () => resplitAudiobookshelfSubtitleBook(
          repo: repo,
          bindings: bindings,
          srtBookUid: book.uid,
          currentTracks: rescanned,
        ),
      ),
      isFalse,
    );
  });

  testWidgets('重切：没有绑定 / 书已删 → false，什么都不动', (WidgetTester tester) async {
    expect(
      await tester.runAsync(
        () => resplitAudiobookshelfSubtitleBook(
          repo: repo,
          bindings: bindings,
          srtBookUid: 'nope',
          currentTracks: _tracks,
        ),
      ),
      isFalse,
    );
  });

  test('downloadAudiobookshelfSubtitle：保留扩展名、文件名消毒、带条目前缀', () async {
    late Uri seen;
    final AudiobookshelfApi api = AudiobookshelfApi(
      serverUrl: Uri.parse('https://abs.example.com'),
      providerId: 'abs-test',
      tokens: const AudiobookshelfTokens(accessToken: 'a'),
      client: MockClient((http.Request request) async {
        seen = request.url;
        return http.Response.bytes('字幕'.codeUnits, 200);
      }),
    );
    final File out = await downloadAudiobookshelfSubtitle(
      api: api,
      itemId: 'item_1',
      file: const AudiobookshelfLibraryFile(
        ino: '20',
        filename: 'sub:title?.SRT',
        fileType: 'unknown',
      ),
      tempDir: work,
    );
    expect(seen.path, '/api/items/item_1/file/20');
    expect(p.basename(out.path), 'abs_item_1_sub_title_.SRT');
    expect(p.extension(out.path).toLowerCase(), '.srt');
    expect(out.existsSync(), isTrue);
    api.close();
  });

  test('remoteTracksOf：服务器音轨 → 绑定里存的音轨', () {
    final List<RemoteAudioTrack> tracks = remoteTracksOf(<AudiobookshelfTrack>[
      const AudiobookshelfTrack(
        index: 1,
        ino: '10',
        itemId: 'i',
        durationMs: 5,
        startOffsetMs: 0,
        mimeType: 'audio/mpeg',
        sizeBytes: 9,
        filename: 'a.mp3',
      ),
    ]);
    expect(tracks.single.ino, '10');
    expect(tracks.single.durationMs, 5);
    expect(tracks.single.filename, 'a.mp3');
  });
}
