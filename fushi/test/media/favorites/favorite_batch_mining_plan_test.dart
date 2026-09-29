import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/favorites/favorite_batch_mining_plan.dart';
import 'package:fushi/src/media/favorites/favorite_mining_item.dart';
import 'package:fushi_anki/fushi_anki.dart' show AnkiMiningSource;
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart'
    show kStatSourceBook, kStatSourceGame, kStatSourceVideo;

FavoriteMiningItem _item({
  String source = kFavoriteSentenceSourceBook,
  String sentence = '猫が好きだ。',
  int? sectionIndex,
  int? normCharOffset,
  int? normCharLength,
}) => FavoriteMiningItem(
  expression: '猫',
  reading: 'ねこ',
  sentence: sentence,
  source: source,
  bookKey: 'book1',
  bookTitle: 'Book',
  sectionIndex: sectionIndex,
  normCharOffset: normCharOffset,
  normCharLength: normCharLength,
);

AudioCue _cue({
  required int audioFileIndex,
  required int startMs,
  required int endMs,
  required int section,
  required int normStart,
  required int normEnd,
  String text = '',
}) => AudioCue()
  ..bookKey = 'book1'
  ..chapterHref = ''
  ..sentenceIndex = 0
  ..textFragmentId = SubtitleRematchCodec.encodeHit(
    sectionIndex: section,
    normCharStart: normStart,
    normCharEnd: normEnd,
  )
  ..text = text
  ..startMs = startMs
  ..endMs = endMs
  ..audioFileIndex = audioFileIndex;

String _playlist(List<({String title, String path})> episodes) =>
    jsonEncode(<Map<String, Object>>[
      for (final ({String title, String path}) e in episodes)
        <String, Object>{'title': e.title, 'path': e.path, 'positionMs': 0},
    ]);

void main() {
  group('planVideoFavoriteMedia', () {
    FavoriteMiningItem video({
      int? episode,
      int? startMs = 12000,
      int? durationMs = 3000,
    }) => _item(
      source: kFavoriteSentenceSourceVideo,
      sectionIndex: episode,
      normCharOffset: startMs,
      normCharLength: durationMs,
    );

    test('single local video clips the cue window from videoPath', () {
      final FavoriteMiningMediaPlan plan = planVideoFavoriteMedia(
        item: video(),
        videoTitle: 'Movie',
        videoPath: r'D:\videos\movie.mkv',
        playlistJson: null,
      );
      expect(plan, isA<FavoriteVideoClipPlan>());
      final FavoriteVideoClipPlan clip = plan as FavoriteVideoClipPlan;
      expect(clip.filePath, r'D:\videos\movie.mkv');
      expect(clip.startMs, 12000);
      expect(clip.endMs, 15000);
      expect(clip.documentTitle, 'Movie');
      expect(clip.titleTag, 'Movie');
    });

    test('playlist picks the favorited episode and titles it series - ep', () {
      final FavoriteMiningMediaPlan plan = planVideoFavoriteMedia(
        item: video(episode: 1),
        videoTitle: 'Series',
        videoPath: '/v/ep1.mkv',
        playlistJson: _playlist(<({String title, String path})>[
          (title: 'Ep 1', path: '/v/ep1.mkv'),
          (title: 'Ep 2', path: '/v/ep2.mkv'),
        ]),
      );
      final FavoriteVideoClipPlan clip = plan as FavoriteVideoClipPlan;
      expect(clip.filePath, '/v/ep2.mkv');
      expect(clip.documentTitle, 'Series - Ep 2');
      expect(clip.titleTag, 'Series');
    });

    test('out-of-range episode is clamped like the collections player', () {
      final FavoriteMiningMediaPlan plan = planVideoFavoriteMedia(
        item: video(episode: 9),
        videoTitle: 'Series',
        videoPath: '/v/ep1.mkv',
        playlistJson: _playlist(<({String title, String path})>[
          (title: 'Ep 1', path: '/v/ep1.mkv'),
          (title: 'Ep 2', path: '/v/ep2.mkv'),
        ]),
      );
      expect((plan as FavoriteVideoClipPlan).filePath, '/v/ep2.mkv');
    });

    test('streaming paths fall back to a text-only card', () {
      for (final String path in <String>[
        'https://example.com/a.m3u8',
        'anime-source://ext/1/ep/2',
      ]) {
        final FavoriteMiningMediaPlan plan = planVideoFavoriteMedia(
          item: video(),
          videoTitle: 'Stream',
          videoPath: path,
          playlistJson: null,
        );
        expect(
          (plan as FavoriteTextOnlyPlan).reason,
          FavoriteTextOnlyReason.videoStreaming,
          reason: path,
        );
      }
    });

    test('a missing library row is text-only (videoMissing)', () {
      final FavoriteMiningMediaPlan plan = planVideoFavoriteMedia(
        item: video(),
        videoTitle: null,
        videoPath: null,
        playlistJson: null,
      );
      expect(
        (plan as FavoriteTextOnlyPlan).reason,
        FavoriteTextOnlyReason.videoMissing,
      );
    });

    test('an unusable cue anchor is text-only', () {
      for (final FavoriteMiningItem item in <FavoriteMiningItem>[
        video(startMs: null),
        video(startMs: -1),
        video(durationMs: 0),
        video(durationMs: null),
      ]) {
        final FavoriteMiningMediaPlan plan = planVideoFavoriteMedia(
          item: item,
          videoTitle: 'Movie',
          videoPath: '/v/movie.mkv',
          playlistJson: null,
        );
        expect(
          (plan as FavoriteTextOnlyPlan).reason,
          FavoriteTextOnlyReason.videoAnchorUnusable,
        );
      }
    });
  });

  group('planAudioFavoriteMedia', () {
    final List<AudioCue> cues = <AudioCue>[
      _cue(
        audioFileIndex: 0,
        startMs: 0,
        endMs: 4000,
        section: 2,
        normStart: 0,
        normEnd: 40,
        text: '最初の文。',
      ),
      _cue(
        audioFileIndex: 1,
        startMs: 7000,
        endMs: 9500,
        section: 2,
        normStart: 40,
        normEnd: 80,
        text: '猫が好きだ。',
      ),
    ];
    const List<String> files = <String>['/a/01.mp3', '/a/02.mp3'];

    test('anchored audiobook sentence clips the matching cue', () {
      final FavoriteMiningMediaPlan plan = planAudioFavoriteMedia(
        item: _item(sectionIndex: 2, normCharOffset: 45, normCharLength: 10),
        cues: cues,
        audioFiles: files,
      );
      final FavoriteAudioClipPlan clip = plan as FavoriteAudioClipPlan;
      expect(clip.audioFilePath, '/a/02.mp3');
      expect(clip.startMs, 7000);
      expect(clip.endMs, 9500);
    });

    test('no anchor falls back to the sentence text', () {
      final FavoriteMiningMediaPlan plan = planAudioFavoriteMedia(
        item: _item(),
        cues: cues,
        audioFiles: files,
      );
      expect((plan as FavoriteAudioClipPlan).audioFilePath, '/a/02.mp3');
    });

    test('a book without an audiobook is text-only', () {
      expect(
        (planAudioFavoriteMedia(
                  item: _item(sectionIndex: 2, normCharOffset: 45),
                  cues: const <AudioCue>[],
                  audioFiles: files,
                )
                as FavoriteTextOnlyPlan)
            .reason,
        FavoriteTextOnlyReason.noAudiobook,
      );
      expect(
        (planAudioFavoriteMedia(
                  item: _item(sectionIndex: 2, normCharOffset: 45),
                  cues: cues,
                  audioFiles: const <String>[],
                )
                as FavoriteTextOnlyPlan)
            .reason,
        FavoriteTextOnlyReason.noAudiobook,
      );
    });

    test('a sentence the cues cannot place is text-only', () {
      final FavoriteMiningMediaPlan plan = planAudioFavoriteMedia(
        item: _item(sentence: '全然関係ない文。'),
        cues: cues,
        audioFiles: files,
      );
      expect(
        (plan as FavoriteTextOnlyPlan).reason,
        FavoriteTextOnlyReason.audioRangeUnresolved,
      );
    });

    test('a cue pointing past the resolved audio files is text-only', () {
      final FavoriteMiningMediaPlan plan = planAudioFavoriteMedia(
        item: _item(sectionIndex: 2, normCharOffset: 45, normCharLength: 10),
        cues: cues,
        audioFiles: const <String>['/a/01.mp3'],
      );
      expect(
        (plan as FavoriteTextOnlyPlan).reason,
        FavoriteTextOnlyReason.audioRangeUnresolved,
      );
    });
  });

  group('source mapping', () {
    test('card tag and stat bucket follow the favorite source', () {
      final Map<String, (AnkiMiningSource, String)>
      expected = <String, (AnkiMiningSource, String)>{
        kFavoriteSentenceSourceBook: (AnkiMiningSource.book, kStatSourceBook),
        kFavoriteSentenceSourceAudiobook: (
          AnkiMiningSource.book,
          kStatSourceBook,
        ),
        kFavoriteSentenceSourceLyrics: (AnkiMiningSource.book, kStatSourceBook),
        kFavoriteSentenceSourceVideo: (
          AnkiMiningSource.video,
          kStatSourceVideo,
        ),
        // SentenceSourceKind has no game member (lenient parse → book); the
        // mapping must read the raw string or game cards get tagged `book`.
        kFavoriteSentenceSourceGame: (AnkiMiningSource.game, kStatSourceGame),
      };
      expected.forEach((String source, (AnkiMiningSource, String) want) {
        final FavoriteMiningItem item = _item(source: source);
        expect(ankiMiningSourceOf(item), want.$1, reason: source);
        expect(statSourceOf(item), want.$2, reason: source);
      });
    });
  });

  group('favoritePayloadBelongsToResult', () {
    test('accepts the favorite word or any headword of this lookup', () {
      expect(
        favoritePayloadBelongsToResult(
          payload: <String, String>{'expression': '猫'},
          itemExpression: '猫',
          resultWords: const <String>['猫舌'],
        ),
        isTrue,
      );
      expect(
        favoritePayloadBelongsToResult(
          payload: <String, String>{'expression': '猫舌'},
          itemExpression: '猫',
          resultWords: const <String>['猫', '猫舌'],
        ),
        isTrue,
      );
    });

    test('rejects a payload from a stale render of another word', () {
      expect(
        favoritePayloadBelongsToResult(
          payload: <String, String>{'expression': '犬'},
          itemExpression: '猫',
          resultWords: const <String>['猫', '猫舌'],
        ),
        isFalse,
      );
      expect(
        favoritePayloadBelongsToResult(
          payload: const <String, String>{},
          itemExpression: '猫',
          resultWords: const <String>['猫'],
        ),
        isFalse,
      );
    });
  });

  test('selectAudiobookFilesInRoot keeps audio files in audiobook order', () {
    expect(
      selectAudiobookFilesInRoot(<String>[
        '/a/10.mp3',
        '/a/cover.jpg',
        '/a/2.MP3',
        '/a/notes.txt',
        '/a/1.m4b',
      ]),
      <String>['/a/1.m4b', '/a/2.MP3', '/a/10.mp3'],
    );
  });

  test('FavoriteBatchSummary counts every status bucket', () {
    final FavoriteBatchSummary summary =
        FavoriteBatchSummary.of(const <FavoriteBatchItemResult>[
          FavoriteBatchItemResult(status: FavoriteBatchItemStatus.added),
          FavoriteBatchItemResult(
            status: FavoriteBatchItemStatus.added,
            textOnlyReason: FavoriteTextOnlyReason.noAudiobook,
          ),
          FavoriteBatchItemResult(status: FavoriteBatchItemStatus.duplicate),
          FavoriteBatchItemResult(status: FavoriteBatchItemStatus.failed),
          FavoriteBatchItemResult(status: FavoriteBatchItemStatus.skipped),
          FavoriteBatchItemResult.pending(),
        ]);
    expect(summary.added, 2);
    expect(summary.duplicate, 1);
    expect(summary.failed, 1);
    expect(summary.skipped, 2);
  });
}
