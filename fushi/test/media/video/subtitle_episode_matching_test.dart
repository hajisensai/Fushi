import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/jimaku_client.dart';
import 'package:fushi/src/media/video/jimaku_matching.dart';
import 'package:fushi/src/media/video/subtitle/subtitle_episode_matching.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_provider.dart';

/// 最小 registry 候选：只有 fileName / language / episode 参与判据。
class _Candidate extends VideoSubtitleCandidate {
  _Candidate(String fileName, {required String language, int? episode})
    : super(
        providerId: 'test',
        remoteId: fileName,
        fileName: fileName,
        language: language,
        providerPriority: 0,
        episode: episode,
      );
}

/// 泛型核心用最笨的载荷：`(集号, 权重)` 二元组，权重小者优先。
typedef _Item = ({int? ep, int rank});

SubtitleEpisodeIndex<_Item> _index(List<_Item> items) =>
    SubtitleEpisodeIndex<_Item>.build(
      items,
      episodeOf: (_Item it) => it.ep,
      compare: (_Item a, _Item b) => a.rank.compareTo(b.rank),
    );

void main() {
  group('SubtitleEpisodeIndex.build', () {
    test('按集号分组，未编号单独收，列表内按 compare 排序', () {
      final SubtitleEpisodeIndex<_Item> index = _index(<_Item>[
        (ep: 2, rank: 5),
        (ep: 1, rank: 9),
        (ep: 1, rank: 1),
        (ep: null, rank: 7),
        (ep: null, rank: 3),
      ]);
      expect(index.byEpisode.keys, unorderedEquals(<int>[1, 2]));
      expect(index.byEpisode[1]!.map((_Item it) => it.rank), <int>[1, 9]);
      expect(index.byEpisode[2]!.single.rank, 5);
      expect(index.unnumbered.map((_Item it) => it.rank), <int>[3, 7]);
      expect(index.totalFiles, 5);
      expect(index.isEmpty, isFalse);
      expect(index.hasNumberedFiles, isTrue);
    });

    test('空输入 → isEmpty，且没有编号文件', () {
      final SubtitleEpisodeIndex<_Item> index = _index(const <_Item>[]);
      expect(index.isEmpty, isTrue);
      expect(index.hasNumberedFiles, isFalse);
      expect(index.totalFiles, 0);
    });

    test('只有未编号 → 非空但 hasNumberedFiles=false', () {
      final SubtitleEpisodeIndex<_Item> index = _index(<_Item>[
        (ep: null, rank: 0),
      ]);
      expect(index.isEmpty, isFalse);
      expect(index.hasNumberedFiles, isFalse);
    });
  });

  group('chooseSubtitleForEpisode 五种结论', () {
    test('exact：集号命中取该集首选（compare 最小者）', () {
      final SubtitleEpisodeIndex<_Item> index = _index(<_Item>[
        (ep: 3, rank: 9),
        (ep: 3, rank: 2),
        (ep: null, rank: 0),
      ]);
      final SubtitleEpisodeMatch<_Item> match = chooseSubtitleForEpisode(
        index,
        episode: 3,
        soleTarget: false,
      );
      expect(match.kind, SubtitleEpisodeMatchKind.exact);
      expect(match.isMatched, isTrue);
      expect(match.file, (ep: 3, rank: 2));
      expect(match.failureReason, isNull);
    });

    test('episodeConflict：字幕侧有集号但没有这一集，绝不用别集/未编号顶替', () {
      final SubtitleEpisodeIndex<_Item> index = _index(<_Item>[
        (ep: 1, rank: 0),
        (ep: 2, rank: 0),
        (ep: null, rank: 0),
      ]);
      for (final bool sole in <bool>[true, false]) {
        final SubtitleEpisodeMatch<_Item> match = chooseSubtitleForEpisode(
          index,
          episode: 13,
          soleTarget: sole,
        );
        expect(
          match.kind,
          SubtitleEpisodeMatchKind.episodeConflict,
          reason: 'soleTarget=$sole',
        );
        expect(match.isMatched, isFalse);
        expect(match.file, isNull);
        expect(
          match.failureReason,
          'jimaku entry has subtitles but none for this episode',
        );
      }
    });

    test('unnumbered：字幕侧全无集号且 soleTarget=true → 采用未编号首选', () {
      final SubtitleEpisodeIndex<_Item> index = _index(<_Item>[
        (ep: null, rank: 4),
        (ep: null, rank: 1),
      ]);
      final SubtitleEpisodeMatch<_Item> match = chooseSubtitleForEpisode(
        index,
        episode: 1,
        soleTarget: true,
      );
      expect(match.kind, SubtitleEpisodeMatchKind.unnumbered);
      expect(match.isMatched, isTrue);
      expect(match.file, (ep: null, rank: 1));
      expect(match.failureReason, isNull);
    });

    test('ambiguousUnnumbered：字幕侧全无集号但 soleTarget=false → 不配', () {
      final SubtitleEpisodeIndex<_Item> index = _index(<_Item>[
        (ep: null, rank: 0),
      ]);
      final SubtitleEpisodeMatch<_Item> match = chooseSubtitleForEpisode(
        index,
        episode: 1,
        soleTarget: false,
      );
      expect(match.kind, SubtitleEpisodeMatchKind.ambiguousUnnumbered);
      expect(match.isMatched, isFalse);
      expect(match.file, isNull);
      expect(match.failureReason, 'jimaku subtitles carry no episode numbers');
    });

    test('none：索引为空', () {
      final SubtitleEpisodeIndex<_Item> index = _index(const <_Item>[]);
      for (final bool sole in <bool>[true, false]) {
        final SubtitleEpisodeMatch<_Item> match = chooseSubtitleForEpisode(
          index,
          episode: 1,
          soleTarget: sole,
        );
        expect(
          match.kind,
          SubtitleEpisodeMatchKind.none,
          reason: 'soleTarget=$sole',
        );
        expect(match.isMatched, isFalse);
        expect(match.failureReason, 'jimaku entry has no text subtitle');
      }
    });
  });

  group('SubtitleEpisodeIndex.fromCandidates', () {
    test('无偏好：ja 优先，同权重按文件名小写 tie-break', () {
      final SubtitleEpisodeIndex<VideoSubtitleCandidate> index =
          SubtitleEpisodeIndex.fromCandidates(<VideoSubtitleCandidate>[
            _Candidate('b.en.srt', language: 'en', episode: 1),
            _Candidate('Zeta.ja.srt', language: 'ja', episode: 1),
            _Candidate('alpha.ja.srt', language: 'ja', episode: 1),
            _Candidate('c.zh.srt', language: 'zh', episode: 1),
            _Candidate('movie.en.srt', language: 'en'),
            _Candidate('movie.ja.srt', language: 'ja'),
          ]);
      expect(
        index.byEpisode[1]!.map((VideoSubtitleCandidate c) => c.fileName),
        <String>['alpha.ja.srt', 'Zeta.ja.srt', 'c.zh.srt', 'b.en.srt'],
      );
      expect(
        index.unnumbered.map((VideoSubtitleCandidate c) => c.fileName),
        <String>['movie.ja.srt', 'movie.en.srt'],
      );
      expect(index.totalFiles, 6);
    });

    test('preferredLanguage 压过 ja', () {
      final SubtitleEpisodeIndex<VideoSubtitleCandidate> index =
          SubtitleEpisodeIndex.fromCandidates(<VideoSubtitleCandidate>[
            _Candidate('a.ja.srt', language: 'ja', episode: 2),
            _Candidate('a.en.srt', language: 'en', episode: 2),
            _Candidate('a.zh.srt', language: 'zh', episode: 2),
          ], preferredLanguage: 'en');
      expect(
        index.byEpisode[2]!.map((VideoSubtitleCandidate c) => c.fileName),
        <String>['a.en.srt', 'a.ja.srt', 'a.zh.srt'],
      );
      final SubtitleEpisodeMatch<VideoSubtitleCandidate> match =
          chooseSubtitleForEpisode(index, episode: 2, soleTarget: false);
      expect(match.kind, SubtitleEpisodeMatchKind.exact);
      expect(match.file!.fileName, 'a.en.srt');
    });

    test('未编号采用只在 soleTarget=true', () {
      final SubtitleEpisodeIndex<VideoSubtitleCandidate> index =
          SubtitleEpisodeIndex.fromCandidates(<VideoSubtitleCandidate>[
            _Candidate('movie.en.srt', language: 'en'),
            _Candidate('movie.ja.srt', language: 'ja'),
          ]);
      expect(index.hasNumberedFiles, isFalse);

      final SubtitleEpisodeMatch<VideoSubtitleCandidate> sole =
          chooseSubtitleForEpisode(index, episode: 1, soleTarget: true);
      expect(sole.kind, SubtitleEpisodeMatchKind.unnumbered);
      expect(sole.file!.fileName, 'movie.ja.srt');

      final SubtitleEpisodeMatch<VideoSubtitleCandidate> many =
          chooseSubtitleForEpisode(index, episode: 1, soleTarget: false);
      expect(many.kind, SubtitleEpisodeMatchKind.ambiguousUnnumbered);
      expect(many.file, isNull);
    });
  });

  group('Jimaku 适配层与泛型核心同一份判据', () {
    JimakuFile file(String name) =>
        JimakuFile(name: name, url: 'https://jimaku.cc/f/$name');

    test('JimakuEpisodeIndex 是 SubtitleEpisodeIndex<JimakuFile>，且只收文本字幕', () {
      final JimakuEpisodeIndex index =
          JimakuEpisodeIndex.fromFiles(<JimakuFile>[
            file('Show - 01.en.srt'),
            file('Show - 01.ja.ass'),
            file('Show - 01.mkv'),
            file('Show.zip'),
          ]);
      expect(index, isA<SubtitleEpisodeIndex<JimakuFile>>());
      expect(index.totalFiles, 2);
      expect(index.byEpisode[1]!.first.name, 'Show - 01.ja.ass');
    });

    test('chooseJimakuFileForEpisode 与 chooseSubtitleForEpisode 结论一致', () {
      final JimakuEpisodeIndex index = JimakuEpisodeIndex.fromFiles(
        <JimakuFile>[file('Show - 01.ja.srt'), file('Show - 02.ja.srt')],
      );
      for (final int episode in <int>[1, 2, 3]) {
        final JimakuEpisodeMatch viaJimaku = chooseJimakuFileForEpisode(
          index,
          episode: episode,
          soleTarget: false,
        );
        final SubtitleEpisodeMatch<JimakuFile> viaCore =
            chooseSubtitleForEpisode<JimakuFile>(
              index,
              episode: episode,
              soleTarget: false,
            );
        expect(viaJimaku.kind, viaCore.kind, reason: 'episode=$episode');
        expect(viaJimaku.file, viaCore.file, reason: 'episode=$episode');
        expect(viaJimaku.failureReason, viaCore.failureReason);
      }
      expect(
        chooseJimakuFileForEpisode(index, episode: 3, soleTarget: true).kind,
        JimakuEpisodeMatchKind.episodeConflict,
      );
      expect(const JimakuEpisodeMatch.none().kind, JimakuEpisodeMatchKind.none);
    });
  });
}
