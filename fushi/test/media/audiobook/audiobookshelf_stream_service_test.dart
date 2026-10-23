// 「流式播放这一本 / 这一集」的编排：同一条目只建一次书、字幕取自本机或服务器、封面
// 取不到不影响建书、播客单集用「节目 – 单集」命名并单轨、服务器重扫后重切字幕；以及
// 服务器字幕文件的推荐规则。走真实的导入链路与内存数据库。
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/remote/audiobookshelf_stream_service.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_api.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

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

Map<String, Object?> _file(String ino, String name, String type) =>
    <String, Object?>{
      'ino': ino,
      'fileType': type,
      'metadata': <String, Object?>{'filename': name, 'size': 100},
    };

Map<String, Object?> _track(int i, String ino, num start, num dur) =>
    <String, Object?>{
      'index': i,
      'ino': ino,
      'duration': dur,
      'startOffset': start,
      'mimeType': 'audio/mpeg',
      'metadata': <String, Object?>{'filename': 'part$i.mp3', 'size': 1000},
    };

AudiobookshelfItemDetail _bookDetail({
  List<Map<String, Object?>>? tracks,
  List<Map<String, Object?>>? files,
}) => AudiobookshelfItemDetail.parse(<String, Object?>{
  'id': 'item_1',
  'mediaType': 'book',
  'media': <String, Object?>{
    'metadata': <String, Object?>{'title': 'Fables', 'authorName': 'Aesop'},
    'tracks':
        tracks ??
        <Map<String, Object?>>[
          _track(1, '10', 0, 1),
          _track(2, '11', 1, 2),
          _track(3, '12', 3, 0.5),
        ],
  },
  'libraryFiles':
      files ??
      <Map<String, Object?>>[
        _file('10', 'part1.mp3', 'audio'),
        _file('20', 'Fables.srt', 'unknown'),
      ],
})!;

AudiobookshelfItemDetail _podcastDetail() =>
    AudiobookshelfItemDetail.parse(<String, Object?>{
      'id': 'pod_1',
      'mediaType': 'podcast',
      'media': <String, Object?>{
        'metadata': <String, Object?>{'title': 'Show', 'author': 'Host'},
        'episodes': <Object?>[
          <String, Object?>{
            'id': 'ep_1',
            'title': 'Ep One',
            'audioFile': <String, Object?>{
              'ino': '77',
              'duration': 4,
              'mimeType': 'audio/mpeg',
              'metadata': <String, Object?>{'filename': 'e1.mp3'},
            },
          },
        ],
      },
    })!;

List<(int, int, int)> _placed(List<AudioCue> cues) => <(int, int, int)>[
  for (final AudioCue c in cues) (c.audioFileIndex, c.startMs, c.endMs),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory work;
  late Directory docs;
  late Directory books;
  late FushiDatabase db;
  late bool coverAvailable;
  late AudiobookshelfApi api;
  late AudiobookshelfStreamService service;

  setUp(() {
    work = Directory.systemTemp.createTempSync('abs_stream_work_');
    docs = Directory.systemTemp.createTempSync('abs_stream_docs_');
    books = Directory.systemTemp.createTempSync('abs_stream_books_');
    AudiobookStorage.documentsRootResolver = () async => docs;
    EpubStorage.debugBaseDirectoryOverride = books.path;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    coverAvailable = true;
    final MockClient client = MockClient((http.Request request) async {
      if (request.url.path.endsWith('/cover')) {
        return coverAvailable
            ? http.Response.bytes(
                <int>[1, 2, 3],
                200,
                headers: <String, String>{'content-type': 'image/png'},
              )
            : http.Response('nope', 404);
      }
      if (request.url.path.endsWith('/file/20')) {
        return http.Response.bytes(_srt.codeUnits, 200);
      }
      return http.Response('not found', 404);
    });
    api = AudiobookshelfApi(
      serverUrl: Uri.parse('https://abs.example.com'),
      providerId: 'abs-test',
      tokens: const AudiobookshelfTokens(accessToken: 'a'),
      client: client,
    );
    service = AudiobookshelfStreamService(
      db: db,
      api: api,
      serverConfigId: 'srv',
      httpClient: () => client,
      tempDir: work,
    );
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

  String writeLocalSrt() {
    final String path = p.join(work.path, 'mine.srt');
    File(path).writeAsStringSync(_srt);
    return path;
  }

  Future<SrtBook> createBook(
    WidgetTester tester,
    AudiobookshelfSubtitleChoice choice, {
    AudiobookshelfItemDetail? detail,
    AudiobookshelfEpisode? episode,
  }) async {
    final AudiobookshelfItemDetail d = detail ?? _bookDetail();
    return (await tester.runAsync(
      () => service.create(
        item: d.item,
        detail: d,
        episode: episode,
        subtitle: choice,
      ),
    ))!;
  }

  testWidgets('本机字幕：建书、按音轨切时间轴、写绑定、取到封面', (WidgetTester tester) async {
    final SrtBook book = await createBook(
      tester,
      LocalSubtitleChoice(writeLocalSrt()),
    );
    expect(book.title, 'Fables');
    expect(book.author, 'Aesop');
    expect(book.audioPaths, isNull);
    expect(book.coverPath, isNotNull);
    expect(p.extension(book.coverPath!), '.png', reason: '按响应类型定扩展名');
    expect(File(book.coverPath!).existsSync(), isTrue);

    final List<AudioCue> cues = (await tester.runAsync(
      () => SrtBookRepository(db).cuesFor(book.uid),
    ))!;
    expect(_placed(cues), <(int, int, int)>[
      (0, 100, 900),
      (1, 200, 800),
      (1, 1500, 1900),
      (2, 100, 400),
    ]);
    final RemoteAudioBinding binding = (await tester
        .runAsync<RemoteAudioBinding?>(
          () => RemoteAudioBindingRepository(db).get(book.uid),
        ))!;
    expect(binding.serverConfigId, 'srv');
    expect(binding.itemId, 'item_1');
    expect(binding.subtitleOrigin, RemoteAudioBinding.subtitleOriginLocal);
    expect(binding.tracks, hasLength(3));
  });

  testWidgets('服务器上的字幕：下载后同样建书，来源记为 server:<ino>', (WidgetTester tester) async {
    final AudiobookshelfItemDetail detail = _bookDetail();
    final SrtBook book = await createBook(
      tester,
      ServerSubtitleChoice(detail.subtitleFiles.single),
      detail: detail,
    );
    final RemoteAudioBinding binding = (await tester
        .runAsync<RemoteAudioBinding?>(
          () => RemoteAudioBindingRepository(db).get(book.uid),
        ))!;
    expect(binding.serverSubtitleIno, '20');
    final List<AudioCue> cues = (await tester.runAsync(
      () => SrtBookRepository(db).cuesFor(book.uid),
    ))!;
    expect(cues, hasLength(4));
  });

  testWidgets('封面取不到不影响建书', (WidgetTester tester) async {
    coverAvailable = false;
    final SrtBook book = await createBook(
      tester,
      LocalSubtitleChoice(writeLocalSrt()),
    );
    expect(book.coverPath, isNull);
    expect(book.bookKey, isNotEmpty);
  });

  testWidgets('findExisting：同条目复用，别的条目 / 单集不命中', (WidgetTester tester) async {
    final SrtBook book = await createBook(
      tester,
      LocalSubtitleChoice(writeLocalSrt()),
    );
    final SrtBook? same = await tester.runAsync<SrtBook?>(
      () => service.findExisting(itemId: 'item_1'),
    );
    expect(same?.uid, book.uid);
    expect(
      await tester.runAsync<SrtBook?>(
        () => service.findExisting(itemId: 'other'),
      ),
      isNull,
    );
    expect(
      await tester.runAsync<SrtBook?>(
        () => service.findExisting(itemId: 'item_1', episodeId: 'ep_1'),
      ),
      isNull,
      reason: '有声书条目与它的某一集不是同一本',
    );
  });

  testWidgets('播客单集：命名「节目 – 单集」，单轨，绑定带单集 id', (WidgetTester tester) async {
    final AudiobookshelfItemDetail detail = _podcastDetail();
    final AudiobookshelfEpisode episode = detail.episodes.single;
    final SrtBook book = await createBook(
      tester,
      LocalSubtitleChoice(writeLocalSrt()),
      detail: detail,
      episode: episode,
    );
    expect(book.title, 'Show – Ep One');
    final RemoteAudioBinding binding = (await tester
        .runAsync<RemoteAudioBinding?>(
          () => RemoteAudioBindingRepository(db).get(book.uid),
        ))!;
    expect(binding.episodeId, 'ep_1');
    expect(binding.tracks.single.ino, '77');
    expect(binding.tracks.single.startOffsetMs, 0);
    expect(
      (await tester.runAsync<SrtBook?>(
        () => service.findExisting(itemId: 'pod_1', episodeId: 'ep_1'),
      ))?.uid,
      book.uid,
    );
    expect(
      await tester.runAsync<SrtBook?>(
        () => service.findExisting(itemId: 'pod_1'),
      ),
      isNull,
    );
  });

  testWidgets('没有音轨：StateError，不落任何行', (WidgetTester tester) async {
    final AudiobookshelfItemDetail empty = _bookDetail(
      tracks: <Map<String, Object?>>[],
    );
    final Object? error = await tester.runAsync<Object?>(() async {
      try {
        await service.create(
          item: empty.item,
          detail: empty,
          subtitle: LocalSubtitleChoice(writeLocalSrt()),
        );
        return null;
      } catch (e) {
        return e;
      }
    });
    expect(error, isA<StateError>());
    expect(
      await tester.runAsync(() => SrtBookRepository(db).listAll()),
      isEmpty,
    );
  });

  testWidgets('refreshExisting：音轨没变不动，服务器重扫后重切', (WidgetTester tester) async {
    final AudiobookshelfItemDetail detail = _bookDetail();
    final SrtBook book = await createBook(
      tester,
      LocalSubtitleChoice(writeLocalSrt()),
      detail: detail,
    );
    expect(
      await tester.runAsync(
        () => service.refreshExisting(book: book, detail: detail),
      ),
      isFalse,
    );
    final AudiobookshelfItemDetail rescanned = _bookDetail(
      tracks: <Map<String, Object?>>[
        _track(1, '10', 0, 2),
        _track(2, '11', 2, 1),
        _track(3, '12', 3, 0.5),
      ],
    );
    expect(
      await tester.runAsync(
        () => service.refreshExisting(book: book, detail: rescanned),
      ),
      isTrue,
    );
    final List<AudioCue> cues = (await tester.runAsync(
      () => SrtBookRepository(db).cuesFor(book.uid),
    ))!;
    expect(_placed(cues).take(2), <(int, int, int)>[
      (0, 100, 900),
      (0, 1200, 1800),
    ]);
  });

  group('suggestServerSubtitle', () {
    AudiobookshelfItemDetail detailWith(List<String> subtitleNames) =>
        _bookDetail(
          files: <Map<String, Object?>>[
            _file('10', 'part1.mp3', 'audio'),
            for (int i = 0; i < subtitleNames.length; i++)
              _file('${30 + i}', subtitleNames[i], 'unknown'),
          ],
        );

    test('只有一个字幕文件 → 就是它', () {
      expect(
        suggestServerSubtitle(detailWith(<String>['whatever.srt']))?.ino,
        '30',
      );
    });

    test('多个时优先与音频同名的；语言后缀不影响', () {
      final AudiobookshelfItemDetail d = detailWith(<String>[
        'other.srt',
        'part1.ja.srt',
      ]);
      expect(suggestServerSubtitle(d)?.filename, 'part1.ja.srt');
    });

    test('其次与标题同名', () {
      final AudiobookshelfItemDetail d = detailWith(<String>[
        'x.srt',
        'Fables.vtt',
      ]);
      expect(suggestServerSubtitle(d)?.filename, 'Fables.vtt');
    });

    test('多个且都对不上 → null（让用户自己选）；没有字幕 → null', () {
      expect(
        suggestServerSubtitle(detailWith(<String>['a.srt', 'b.srt'])),
        isNull,
      );
      expect(suggestServerSubtitle(detailWith(<String>[])), isNull);
    });
  });
}
