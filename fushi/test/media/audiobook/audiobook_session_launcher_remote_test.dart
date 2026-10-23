// 会话启动材料的远端分支：绑定了服务器的字幕书（没有本机音频）解析出流式材料，
// 占位文件撑下标、cue 带进来；本机有音频的书永远走老路，不受远端绑定影响；服务器
// 配置丢了（解析器给 null）就照旧判为「没有可播放的音频」。
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_session_launcher.dart';
import 'package:fushi/src/media/audiobook/remote/audiobook_remote_playback.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;

class _FakeRemote implements AudiobookRemotePlayback {
  _FakeRemote(this.binding);

  final RemoteAudioBinding binding;
  int released = 0;

  @override
  int get trackCount => binding.tracks.length;

  @override
  late final List<File> placeholderFiles = <File>[
    for (final RemoteAudioTrack t in binding.tracks)
      File(p.join('abs-remote', '${t.ino}.mp3')),
  ];

  @override
  List<AudioSource> buildSources() => const <AudioSource>[];

  @override
  AudioSource buildTrackSource(int index) =>
      throw UnimplementedError('not needed');

  @override
  Future<AudiobookTrackInput> trackInput(int index) async =>
      AudiobookTrackInput(input: 'https://abs.example/file/$index');

  @override
  Future<void> release() async => released++;
}

const List<RemoteAudioTrack> _tracks = <RemoteAudioTrack>[
  RemoteAudioTrack(ino: '10', startOffsetMs: 0, durationMs: 1000),
  RemoteAudioTrack(ino: '11', startOffsetMs: 1000, durationMs: 2000),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docsDir;
  late FushiDatabase db;
  late SrtBookRepository srtRepo;

  setUp(() async {
    docsDir = await Directory.systemTemp.createTemp('fushi_launcher_remote_');
    AudiobookStorage.documentsRootResolver = () async => docsDir;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    srtRepo = SrtBookRepository(db);
  });

  tearDown(() async {
    await db.close();
    AudiobookStorage.documentsRootResolver = null;
    if (docsDir.existsSync()) docsDir.deleteSync(recursive: true);
  });

  Future<SrtBook> seedBook({
    required String bookKey,
    List<String>? audioPaths,
  }) async {
    final SrtBook book = SrtBook()
      ..uid = 'srtbook_$bookKey'
      ..title = 'Fables'
      ..srtPath = '/src/fables.srt'
      ..importedAt = 1
      ..bookKey = bookKey
      ..audioPaths = audioPaths;
    await srtRepo.save(book);
    await srtRepo.saveCues(
      uid: book.uid,
      cues: <AudioCue>[
        AudioCue()
          ..bookKey = book.uid
          ..chapterHref = SrtParser.defaultChapter
          ..sentenceIndex = 0
          ..textFragmentId = '#s0'
          ..text = '一つ目'
          ..startMs = 100
          ..endMs = 900
          ..audioFileIndex = 0,
        AudioCue()
          ..bookKey = book.uid
          ..chapterHref = SrtParser.defaultChapter
          ..sentenceIndex = 1
          ..textFragmentId = '#s1'
          ..text = '二つ目'
          ..startMs = 200
          ..endMs = 800
          ..audioFileIndex = 1,
      ],
    );
    return book;
  }

  Future<void> bind(SrtBook book) => RemoteAudioBindingRepository(db).save(
    RemoteAudioBinding(
      srtBookUid: book.uid,
      provider: RemoteAudioBinding.providerAudiobookshelf,
      serverConfigId: 'srv',
      itemId: 'item_1',
      tracks: _tracks,
      createdAt: 1,
      updatedAt: 1,
    ),
  );

  test('绑定了服务器且解析器给出接缝 → 流式材料：占位文件、cue、远端接缝', () async {
    final SrtBook book = await seedBook(bookKey: 'epubkey');
    await bind(book);
    final List<RemoteAudioBinding> resolved = <RemoteAudioBinding>[];
    late _FakeRemote remote;
    final AudiobookSessionLauncher launcher = AudiobookSessionLauncher(
      db,
      remoteResolver: (RemoteAudioBinding binding) {
        resolved.add(binding);
        return remote = _FakeRemote(binding);
      },
    );

    final AudiobookSessionStartRequest? req = await launcher.resolve('epubkey');

    expect(req, isNotNull);
    expect(req!.remote, same(remote));
    expect(resolved.single.itemId, 'item_1');
    expect(req.audioFiles, hasLength(2), reason: '一轨一个占位文件，撑住 audioFileIndex');
    expect(req.audioFiles.any((File f) => f.existsSync()), isFalse);
    expect(req.isSrtBookSource, isTrue);
    expect(req.info.bookKey, book.uid);
    expect(req.info.title, 'Fables');
    expect(req.cues.map((AudioCue c) => c.audioFileIndex), <int>[0, 1]);
  });

  test('没有解析器（或没有绑定）→ 照旧：没有可播放的音频', () async {
    final SrtBook book = await seedBook(bookKey: 'epubkey');
    await bind(book);
    expect(await AudiobookSessionLauncher(db).resolve('epubkey'), isNull);

    final SrtBook unbound = await seedBook(bookKey: 'other');
    expect(unbound.uid, isNot(book.uid));
    expect(
      await AudiobookSessionLauncher(
        db,
        remoteResolver: (RemoteAudioBinding b) => _FakeRemote(b),
      ).resolve('other'),
      isNull,
      reason: '没有绑定行的字幕书不受影响',
    );
  });

  test('解析器给 null（服务器已删 / 已登出）→ 没有可播放的音频', () async {
    final SrtBook book = await seedBook(bookKey: 'epubkey');
    await bind(book);
    final AudiobookSessionLauncher launcher = AudiobookSessionLauncher(
      db,
      remoteResolver: (RemoteAudioBinding binding) => null,
    );
    expect(await launcher.resolve('epubkey'), isNull);
  });

  test('本机有音频的书永远走老路：远端绑定不抢，解析器不被调用', () async {
    final File audio = File(p.join(docsDir.path, 'local.mp3'))
      ..writeAsStringSync('AUDIO');
    final SrtBook book = await seedBook(
      bookKey: 'epubkey',
      audioPaths: <String>[audio.path],
    );
    await bind(book);
    int calls = 0;
    final AudiobookSessionLauncher launcher = AudiobookSessionLauncher(
      db,
      remoteResolver: (RemoteAudioBinding binding) {
        calls++;
        return _FakeRemote(binding);
      },
    );

    final AudiobookSessionStartRequest? req = await launcher.resolve('epubkey');

    expect(req, isNotNull);
    expect(req!.remote, isNull);
    expect(req.audioFiles.single.path, audio.path);
    expect(calls, 0);
  });
}
