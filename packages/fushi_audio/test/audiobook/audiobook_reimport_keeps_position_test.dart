import 'package:drift/native.dart';
import 'package:fushi_audio/src/audiobook/audiobook_model.dart';
import 'package:fushi_audio/src/audiobook/audiobook_position_rebase.dart';
import 'package:fushi_audio/src/audiobook/audiobook_repository.dart';
import 'package:fushi_audio/src/audiobook/srt_book_model.dart';
import 'package:fushi_audio/src/audiobook/srt_book_repository.dart';
import 'package:fushi_audio/src/parsers/srt_parser.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:test/test.dart';

/// BUG-3197：重新导入字幕后有声书的音频进度被重置（阅读页数不受影响）。
///
/// `audiobook_pos_<key>` 存的是全书毫秒，而多文件有声书的「文件时长」是从 cue 推的
/// （该文件内 cue 的最大 endMs）。换一份字幕 = 换一组文件时长 = 同一个毫秒数指向
/// 别的文件 / 别的偏移。修法：cue 整组替换的唯一入口（两个 repository 的
/// `saveCues`）按旧 cue 把全书毫秒拆回（文件下标, 文件内偏移），再按新 cue 重新
/// 编码——真实时间位置与字幕无关，必须原样保留。
void main() {
  late FushiDatabase db;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  AudioCue cue({
    required String key,
    required int index,
    required int file,
    required int startMs,
    required int endMs,
    String chapter = 'chapter.xhtml',
  }) =>
      AudioCue()
        ..bookKey = key
        ..chapterHref = chapter
        ..sentenceIndex = index
        ..textFragmentId = 'f$index'
        ..text = 'cue $index'
        ..startMs = startMs
        ..endMs = endMs
        ..audioFileIndex = file;

  /// 三个音频文件的旧字幕：各文件最后一句结束于 100s / 200s / 300s。
  List<AudioCue> oldCues(String key, {String chapter = 'chapter.xhtml'}) =>
      <AudioCue>[
        cue(
            key: key,
            index: 0,
            file: 0,
            startMs: 0,
            endMs: 100000,
            chapter: chapter),
        cue(
            key: key,
            index: 1,
            file: 1,
            startMs: 0,
            endMs: 200000,
            chapter: chapter),
        cue(
            key: key,
            index: 2,
            file: 2,
            startMs: 0,
            endMs: 300000,
            chapter: chapter),
      ];

  /// 新字幕：句子切法、条数、各文件末句时间全都不同（cue 序号对不上）。
  List<AudioCue> newCues(String key, {String chapter = 'chapter.xhtml'}) =>
      <AudioCue>[
        cue(
            key: key,
            index: 0,
            file: 0,
            startMs: 0,
            endMs: 50000,
            chapter: chapter),
        cue(
            key: key,
            index: 1,
            file: 0,
            startMs: 50000,
            endMs: 120000,
            chapter: chapter),
        cue(
            key: key,
            index: 2,
            file: 1,
            startMs: 0,
            endMs: 90000,
            chapter: chapter),
        cue(
            key: key,
            index: 3,
            file: 1,
            startMs: 90000,
            endMs: 180000,
            chapter: chapter),
        cue(
            key: key,
            index: 4,
            file: 2,
            startMs: 0,
            endMs: 250000,
            chapter: chapter),
      ];

  group('rebaseAudiobookGlobalPositionMs', () {
    test('keeps (file, offset) when per-file cue durations change', () {
      // 旧编码：文件 2 内 42s = 100000 + 200000 + 42000。
      expect(
        rebaseAudiobookGlobalPositionMs(
          342000,
          const <int>[100000, 200000, 300000],
          const <int>[120000, 180000, 250000],
        ),
        120000 + 180000 + 42000,
      );
    });

    test('does not clamp the tail past the last cue of the last file', () {
      // 片尾没有 cue：最后一个文件内的偏移可以超过 cue 推出的「时长」。
      expect(
        rebaseAudiobookGlobalPositionMs(
          100000 + 200000 + 310000,
          const <int>[100000, 200000, 300000],
          const <int>[120000, 180000, 250000],
        ),
        120000 + 180000 + 310000,
      );
    });

    test('single-file book and zero position are identity', () {
      expect(
        rebaseAudiobookGlobalPositionMs(
            75000, const <int>[100000], const <int>[60000]),
        75000,
      );
      expect(
        rebaseAudiobookGlobalPositionMs(
            0, const <int>[1, 2], const <int>[3, 4]),
        0,
      );
    });

    test('durations come from the max cue end per file', () {
      expect(audiobookFileDurationsFromCues(newCues('k')),
          const <int>[120000, 180000, 250000]);
      expect(audiobookFileDurationsFromCues(const <AudioCue>[]), isEmpty);
    });
  });

  test('AudiobookRepository.saveCues keeps the audio time position', () async {
    final AudiobookRepository repo = AudiobookRepository(db);
    await repo.ensureAudiobook('Demo');
    await repo.saveCues(bookKey: 'Demo', cues: oldCues('Demo'));
    // 正在听第 3 个文件的第 42 秒（旧 cue 编码）。
    await repo.updatePositionMs(bookKey: 'Demo', positionMs: 342000);
    final int stampBefore = await repo.readPositionUpdatedAtMs('Demo');

    await repo.saveCues(bookKey: 'Demo', cues: newCues('Demo'));

    final int stored = await repo.readPositionMs('Demo');
    final List<int> newDurations =
        audiobookFileDurationsFromCues(await repo.cuesForBook('Demo'));
    expect(stored, 120000 + 180000 + 42000);
    // 按新 cue 拆回去仍是文件 2 的第 42 秒——与开书恢复 seek 同一口径。
    int remaining = stored;
    int file = 0;
    for (; file < newDurations.length - 1; file++) {
      if (remaining < newDurations[file]) break;
      remaining -= newDurations[file];
    }
    expect((file, remaining), (2, 42000));
    expect(await repo.readPositionUpdatedAtMs('Demo'), stampBefore,
        reason: '同一个时间位置只是换了编码，不得盖新时间戳（BUG-2328 LWW）');
  });

  test('saveCues with an identical timeline leaves the position untouched',
      () async {
    final AudiobookRepository repo = AudiobookRepository(db);
    await repo.ensureAudiobook('Demo');
    await repo.saveCues(bookKey: 'Demo', cues: oldCues('Demo'));
    await repo.updatePositionMs(bookKey: 'Demo', positionMs: 342000);

    await repo.saveCues(bookKey: 'Demo', cues: oldCues('Demo'));

    expect(await repo.readPositionMs('Demo'), 342000);
  });

  test('SrtBookRepository.saveCues keeps the uid-keyed audio position',
      () async {
    final SrtBookRepository srtRepo = SrtBookRepository(db);
    final AudiobookRepository prefs = AudiobookRepository(db);
    await srtRepo.save(SrtBook()
      ..uid = 'srtbook_1'
      ..title = 'Demo'
      ..srtPath = '/src/demo.srt'
      ..importedAt = 1);
    await srtRepo.saveCues(
      uid: 'srtbook_1',
      cues: oldCues('srtbook_1', chapter: SrtParser.defaultChapter),
    );
    // 第 2 个文件的第 30 秒。
    await prefs.updatePositionMs(bookKey: 'srtbook_1', positionMs: 130000);

    await srtRepo.saveCues(
      uid: 'srtbook_1',
      cues: newCues('srtbook_1', chapter: SrtParser.defaultChapter),
    );

    expect(await prefs.readPositionMs('srtbook_1'), 120000 + 30000);
  });
}
