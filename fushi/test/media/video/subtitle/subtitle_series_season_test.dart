import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/anilist_client.dart';
import 'package:fushi/src/media/video/subtitle/subtitle_series_season.dart';

/// BUG-2713：AniList 把每一季登记成独立条目、相关度首条恒为第一季，字幕面板无条件
/// 取首条，看第四季也按第一季的 id 查 Jimaku。
///
/// 候选顺序取自 2026-09-26 实测 AniList 对「Re:Zero kara Hajimeru Isekai Seikatsu」的
/// 原样返回（顺序每次都可能变，但第一季恒为首条）。
void main() {
  const List<AniListMedia> reZero = <AniListMedia>[
    AniListMedia(id: 21355, romaji: 'Re:Zero kara Hajimeru Isekai Seikatsu'),
    AniListMedia(
      id: 100049,
      romaji: 'Re:Zero kara Hajimeru Isekai Seikatsu OVAs',
    ),
    AniListMedia(
      id: 119661,
      romaji: 'Re:Zero kara Hajimeru Isekai Seikatsu 2nd Season Part 2',
    ),
    AniListMedia(
      id: 108632,
      romaji: 'Re:Zero kara Hajimeru Isekai Seikatsu 2nd Season',
    ),
    AniListMedia(
      id: 163134,
      romaji: 'Re:Zero kara Hajimeru Isekai Seikatsu 3rd Season',
    ),
    AniListMedia(
      id: 189046,
      romaji: 'Re:Zero kara Hajimeru Isekai Seikatsu 4th Season',
      native: 'Re:ゼロから始める異世界生活 4th season',
    ),
  ];

  group('subtitleSeasonFromName（用户附的三份第四季字幕的文件名形态）', () {
    test('NanakoRaws：S04E18', () {
      expect(
        subtitleSeasonFromName(
          '[NanakoRaws] Re Zero kara Hajimeru Isekai Seikatsu S04E18 '
          '(AT-X TV 1080p HEVC AAC).mkv',
        ),
        4,
      );
    });

    test('ABEMA：日文番名 + S04E83（绝对集号）', () {
      expect(
        subtitleSeasonFromName(
          'Re：ゼロから始める異世界生活.S04E83.グッドルーザー.WEBRip.ABEMA.mkv',
        ),
        4,
      );
    });

    test('shincaps：4th season - 18', () {
      expect(
        subtitleSeasonFromName(
          '[shincaps] Re Zero kara Hajimeru Isekai Seikatsu 4th season - 18 '
          '(AT-X 1440x1080 MPEG2 AAC).ts',
        ),
        4,
      );
    });

    test('Jellyfin/Emby 单集标题：剧名 S04E18 集名', () {
      expect(subtitleSeasonFromName('Re:ゼロから始める異世界生活 S04E18 グッドルーザー'), 4);
    });

    test('没有季号 → null', () {
      expect(subtitleSeasonFromName(null), isNull);
      expect(subtitleSeasonFromName(''), isNull);
    });
  });

  group('subtitleSeasonHint', () {
    test('解析出的季号优先于标题', () {
      expect(
        subtitleSeasonHint(
          parsedSeason: 4,
          titles: <String>['Re:Zero 2nd Season'],
        ),
        4,
      );
    });

    test('合集名里的季度记号：预填词被换成不带季的日文原名时靠它', () {
      expect(
        subtitleSeasonHint(
          titles: <String?>[
            'Re:ゼロから始める異世界生活',
            null,
            'Re:ゼロから始める異世界生活 4th season (2026)',
          ],
        ),
        4,
      );
    });

    test('中文显示名「第四季」', () {
      expect(subtitleSeasonHint(titles: <String>['Re：从零开始的异世界生活 第四季 丧失篇']), 4);
    });

    test('一个标题里出现多个季号不猜，看下一个', () {
      expect(
        subtitleSeasonHint(
          titles: <String>['Foo 3rd Season Part 2', 'Foo Season 3'],
        ),
        3,
      );
    });

    test('都没有 → null', () {
      expect(
        subtitleSeasonHint(titles: <String>['Re:Zero kara Hajimeru']),
        isNull,
      );
    });

    test('Part / 第N部 / cour 分段记号不是季号', () {
      // 《JoJo》Part 5 在 TMDB 上不是第 5 季；「The Final Season Part 2」是 S4 后半。
      expect(
        subtitleSeasonHint(
          titles: <String>['JoJo no Kimyou na Bouken Part 5'],
        ),
        isNull,
      );
      expect(
        subtitleSeasonHint(titles: <String>['ジョジョの奇妙な冒険 第5部']),
        isNull,
      );
      expect(
        subtitleSeasonHint(
          titles: <String>['Shingeki no Kyojin: The Final Season Part 2'],
        ),
        isNull,
      );
      expect(
        subtitleSeasonHint(titles: <String>['Foo 2nd Season Part 2']),
        2,
      );
    });
  });

  group('pickAniListSeriesForSeason', () {
    test('第四季挑 4th Season，而不是相关度首条的第一季', () {
      expect(pickAniListSeriesForSeason(reZero, season: 4)?.id, 189046);
    });

    test('第三季挑 3rd Season', () {
      expect(pickAniListSeriesForSeason(reZero, season: 3)?.id, 163134);
    });

    test('第二季：恰好是第二季的条目优先于 Part 2（哪怕 Part 2 排在前面）', () {
      expect(pickAniListSeriesForSeason(reZero, season: 2)?.id, 108632);
    });

    test('只有 Part 形式的第二季条目时退而取含该季的那条', () {
      expect(
        pickAniListSeriesForSeason(<AniListMedia>[
          reZero[0],
          reZero[2],
        ], season: 2)?.id,
        119661,
      );
    });

    test('第一季：跳过排在前面的续作', () {
      expect(
        pickAniListSeriesForSeason(<AniListMedia>[
          reZero[4],
          reZero[0],
          reZero[5],
        ], season: 1)?.id,
        21355,
      );
    });

    test('找第二季时不拿「3rd Season Part 2」冒充（Part 记号不算季号）', () {
      expect(
        pickAniListSeriesForSeason(<AniListMedia>[
          const AniListMedia(id: 1, romaji: 'Foo'),
          const AniListMedia(id: 3, romaji: 'Foo 3rd Season Part 2'),
        ], season: 2)?.id,
        1,
        reason: '没有第二季条目 → 回退首条（旧行为），不挑第三季下半',
      );
    });

    test('季号未知 / 没有对应季的条目 → 首条（旧行为）', () {
      expect(pickAniListSeriesForSeason(reZero, season: null)?.id, 21355);
      expect(pickAniListSeriesForSeason(reZero, season: 7)?.id, 21355);
    });

    test('空列表 → null', () {
      expect(
        pickAniListSeriesForSeason(const <AniListMedia>[], season: 4),
        isNull,
      );
    });
  });
}
