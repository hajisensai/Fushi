import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/lyrics/lyrics_candidate_scoring.dart';

LyricsCandidate _hit(String title, String artist, [int? ms]) => LyricsCandidate(
  providerId: 't',
  title: title,
  artist: artist,
  durationMs: ms,
  ref: <String, String>{'k': '$title|$artist|$ms'},
);

void main() {
  group('候选裁决 pickBestLyricsCandidate', () {
    test('标题 / 艺人相似度优先，时长超 5 s 的剔除', () {
      final LyricsCandidate? best = pickBestLyricsCandidate(
        <LyricsCandidate>[
          _hit('夜に駆ける (Cover)', 'Someone', 261000),
          _hit('夜に駆ける', 'YOASOBI', 300000),
          _hit('夜に駆ける', 'YOASOBI', 262500),
        ],
        title: '夜に駆ける',
        artist: 'YOASOBI',
        durationMs: 261000,
      );
      expect(best!.durationMs, 262500);
    });

    test('文件名式标题按片段比，括注不影响', () {
      final LyricsCandidate? best = pickBestLyricsCandidate(
        <LyricsCandidate>[_hit('爱殇 (电视剧《东宫》插曲)', '小时姑娘'), _hit('光阴之外', '小时姑娘')],
        title: '小时姑娘 - 光阴之外 - 动画《光...》',
        artist: '小时姑娘',
      );
      expect(best!.title, '光阴之外');
    });

    test('全都不像时返回 null（不乱采用）', () {
      expect(
        pickBestLyricsCandidate(
          <LyricsCandidate>[_hit('完全无关', '路人'), _hit('Another', 'X')],
          title: '前前前世',
          artist: 'RADWIMPS',
        ),
        isNull,
      );
      expect(
        pickBestLyricsCandidate(
          <LyricsCandidate>[_hit('前前前世', '翻唱路人')],
          title: '前前前世',
          artist: 'RADWIMPS',
        ),
        isNull,
      );
    });

    test('多艺人（A/B）任一段对得上即可；时长未知不卡', () {
      expect(
        pickBestLyricsCandidate(
          <LyricsCandidate>[_hit('Song', 'Other/Target')],
          title: 'Song',
          artist: 'Target',
          durationMs: 200000,
        ),
        isNotNull,
      );
      expect(
        pickBestLyricsCandidate(
          <LyricsCandidate>[_hit('Song', 'Target', 999000)],
          title: 'Song',
          artist: 'Target',
        ),
        isNotNull,
      );
    });

    test('同分取时长差小者', () {
      final LyricsCandidate? best = pickBestLyricsCandidate(
        <LyricsCandidate>[
          _hit('Song', 'Target', 204000),
          _hit('Song', 'Target', 201000),
        ],
        title: 'Song',
        artist: 'Target',
        durationMs: 200000,
      );
      expect(best!.durationMs, 201000);
    });

    test('查询词：首段+艺人，其次前两段，再各单段', () {
      expect(lyricsQueries('小时姑娘 - 光阴之外 - 动画《光...》', '小时姑娘'), <String>[
        '小时姑娘 小时姑娘',
        '小时姑娘 光阴之外',
        '小时姑娘',
        '光阴之外',
      ]);
      expect(lyricsQueries('Lemon', null), <String>['Lemon']);
    });
  });
}
