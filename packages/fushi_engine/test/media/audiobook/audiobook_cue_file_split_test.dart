import 'dart:io';

import 'package:drift/native.dart';
import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/audiobook/audiobook_cue_file_split.dart';
import 'package:fushi_engine/media/audiobook/srt_book_reimport.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// BUG-4248：「单时间轴字幕 + 多个音频文件」的 cue 归文件只有一个入口
/// [splitSingleTimelineCuesAcrossAudioFiles]，导入 / 重新导入路径都经它。
const String _kSrt =
    '1\n00:00:00,000 --> 00:00:01,500\nA\n\n'
    '2\n00:00:02,500 --> 00:00:03,500\nB\n\n'
    '3\n00:00:04,500 --> 00:00:05,500\nC\n';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_cue_split_');
    AudiobookStorage.documentsRootResolver = () async => tmp;
    AudiobookStorage.audioDurationProbeMs = (String path) async =>
        const <String, int>{'01.mp3': 2000, '02.mp3': 2000, '03.mp3': 2000}[p
            .basename(path)] ??
        0;
  });

  tearDown(() async {
    AudiobookStorage.documentsRootResolver = null;
    AudiobookStorage.audioDurationProbeMs = null;
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  String audio(String name) {
    final File f = File(p.join(tmp.path, 'lib', name))
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(<int>[1, 2, 3]);
    return f.path;
  }

  List<AudioCue> globalCues() => <AudioCue>[
    for (final (int i, int s, int e) in <(int, int, int)>[
      (0, 0, 1500),
      (1, 2500, 3500),
      (2, 4500, 5500),
    ])
      AudioCue()
        ..bookKey = 'u1'
        ..chapterHref = SrtParser.defaultChapter
        ..sentenceIndex = i
        ..textFragmentId = 's$i'
        ..text = 't$i'
        ..startMs = s
        ..endMs = e
        ..audioFileIndex = 0,
  ];

  List<(int, int)> placement(List<AudioCue> cues) => <(int, int)>[
    for (final AudioCue c
        in List<AudioCue>.of(cues)..sort(
          (AudioCue a, AudioCue b) => a.startMs == b.startMs
              ? a.audioFileIndex.compareTo(b.audioFileIndex)
              : a.sentenceIndex.compareTo(b.sentenceIndex),
        ))
      (c.audioFileIndex, c.startMs),
  ];

  test('多个文件：按实测时长分到各文件、改成文件内时间', () async {
    final List<AudioCue> out = await splitSingleTimelineCuesAcrossAudioFiles(
      cues: globalCues(),
      subtitlePath: '/x/book.SRT',
      audioPaths: <String>[audio('01.mp3'), audio('02.mp3'), audio('03.mp3')],
    );
    expect(placement(out), <(int, int)>[(0, 0), (1, 500), (2, 500)]);
  });

  test('不切：单文件、对齐自带文件映射（SMIL / JSON）、已分过文件、探不出时长', () async {
    final List<String> two = <String>[audio('01.mp3'), audio('02.mp3')];
    expect(
      placement(
        await splitSingleTimelineCuesAcrossAudioFiles(
          cues: globalCues(),
          subtitlePath: 'b.srt',
          audioPaths: <String>[audio('01.mp3')],
        ),
      ),
      <(int, int)>[(0, 0), (0, 2500), (0, 4500)],
    );
    for (final String format in <String>['b.smil', 'b.json']) {
      expect(
        placement(
          await splitSingleTimelineCuesAcrossAudioFiles(
            cues: globalCues(),
            subtitlePath: format,
            audioPaths: two,
          ),
        ),
        <(int, int)>[(0, 0), (0, 2500), (0, 4500)],
        reason: format,
      );
    }
    final List<AudioCue> mapped = globalCues()..last.audioFileIndex = 1;
    expect(
      (await splitSingleTimelineCuesAcrossAudioFiles(
        cues: mapped,
        subtitlePath: 'b.srt',
        audioPaths: two,
      )).map((AudioCue c) => c.startMs),
      <int>[0, 2500, 4500],
    );
    expect(
      placement(
        await splitSingleTimelineCuesAcrossAudioFiles(
          cues: globalCues(),
          subtitlePath: 'b.srt',
          audioPaths: <String>[audio('01.mp3'), audio('unknown.mp3')],
        ),
      ),
      <(int, int)>[(0, 0), (0, 2500), (0, 4500)],
    );
  });

  group('reimportSrtBook', () {
    late FushiDatabase db;
    late SrtBookRepository repo;

    setUp(() {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      repo = SrtBookRepository(db);
    });

    tearDown(() async => db.close());

    Future<String> seed(List<String> audioPaths) async {
      final Directory persist = await AudiobookStorage.ensurePersistDir('u1');
      final File srt = File(p.join(persist.path, 'book.srt'))
        ..writeAsStringSync(_kSrt);
      final SrtBook book = SrtBook()
        ..uid = 'u1'
        ..title = 'Book'
        ..srtPath = srt.path
        ..importedAt = 1
        ..bookKey = ''
        ..audioPaths = audioPaths;
      await repo.save(book);
      return srt.path;
    }

    test('只换音频（2 → 3 个文件）：用库里那份字幕按新音频重新分配 cue', () async {
      await seed(<String>[audio('01.mp3'), audio('02.mp3')]);
      await repo.saveCues(uid: 'u1', cues: globalCues());

      await reimportSrtBook(
        db: db,
        repo: repo,
        uid: 'u1',
        audioPaths: <String>[audio('01.mp3'), audio('02.mp3'), audio('03.mp3')],
        copyAudio: false,
      );

      expect(placement(await repo.cuesFor('u1')), <(int, int)>[
        (0, 0),
        (1, 500),
        (2, 500),
      ]);
    });

    test('只换音频且换前换后都是单文件：cue 不动', () async {
      await seed(<String>[audio('01.mp3')]);
      final List<AudioCue> cues = globalCues()..first.text = 'kept';
      await repo.saveCues(uid: 'u1', cues: cues);

      await reimportSrtBook(
        db: db,
        repo: repo,
        uid: 'u1',
        audioPaths: <String>[audio('02.mp3')],
        copyAudio: false,
      );

      expect(
        (await repo.cuesFor('u1')).map((AudioCue c) => c.text),
        contains('kept'),
      );
    });
  });
}
