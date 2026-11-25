import 'package:fushi_engine/media/collections/book_series_key.dart';
import 'package:fushi_engine/media/tracking/local_title_clean.dart';
import 'package:fushi_engine/media/tracking/title_match.dart';
import 'package:test/test.dart';

TitleMatchCandidate<int> _site(int id, List<String> titles) =>
    TitleMatchCandidate<int>(subject: id, id: id, titles: titles);

void main() {
  group('localTitleSearchCandidates', () {
    // title → candidates, best first; the original always comes last.
    const Map<String, List<String>> table = <String, List<String>>{
      'Ajin (HD Scan) Ajin 01': <String>['Ajin', 'Ajin (HD Scan) Ajin 01'],
      'Ajin - Ajin 02': <String>['Ajin', 'Ajin - Ajin 02'],
      '14 Sai no Koi [水谷フーカ] 14歳の恋 第01巻': <String>[
        '14 Sai no Koi',
        '14歳の恋',
        '14 Sai no Koi 14歳の恋',
        '14 Sai no Koi [水谷フーカ] 14歳の恋 第01巻',
      ],
      '[Group] Berserk v02 (Digital) [3574f94a].cbz': <String>[
        'Berserk',
        '[Group] Berserk v02 (Digital) [3574f94a].cbz',
      ],
      'Ajin_v01.cbz': <String>['Ajin', 'Ajin_v01.cbz'],
      'Ajin (2016) [v2]': <String>['Ajin', 'Ajin (2016) [v2]'],
      'One Piece ch.1050': <String>['One Piece', 'One Piece ch.1050'],
      'ダンジョン飯 第12話': <String>['ダンジョン飯', 'ダンジョン飯 第12話'],
      '化物語 (上)': <String>['化物語', '化物語 (上)'],
      'Re:ゼロから始める異世界生活 1': <String>['Re:ゼロから始める異世界生活', 'Re:ゼロから始める異世界生活 1'],
      'Sword Art Online ソードアート・オンライン 3': <String>[
        'Sword Art Online',
        'ソードアート・オンライン',
        'Sword Art Online ソードアート・オンライン',
        'Sword Art Online ソードアート・オンライン 3',
      ],
      // Video file names (the T1 test's real titles, finding F2): the
      // episode part, release tags, a trailing group and the year go.
      'The Ramparts of Ice S1E2': <String>[
        'The Ramparts of Ice',
        'The Ramparts of Ice S1E2',
      ],
      'As Promised S1': <String>['As Promised', 'As Promised S1'],
      "Beyond Time's Gaze (2025) - S01E01 - Kill to Live "
          '[HDTV-2160p][AAC 2.0][HEVC]-GM-Team': <String>[
        "Beyond Time's Gaze",
        "Beyond Time's Gaze (2025) - S01E01 - Kill to Live "
            '[HDTV-2160p][AAC 2.0][HEVC]-GM-Team',
      ],
      "[FSP] Beyond Time's Gaze Episode 46 [4K HEVC AAC]": <String>[
        "Beyond Time's Gaze",
        "[FSP] Beyond Time's Gaze Episode 46 [4K HEVC AAC]",
      ],
      'How Dare You!! (2026) - S01E01 - Episode 1 '
          '[WEBDL-1080p][AAC 2.0][ZH][h264]-ANDY': <String>[
        'How Dare You!!',
        'How Dare You!! (2026) - S01E01 - Episode 1 '
            '[WEBDL-1080p][AAC 2.0][ZH][h264]-ANDY',
      ],
      '[SubsPlease] Frieren - 12 (1080p) [ABCD1234].mkv': <String>[
        'Frieren',
        '[SubsPlease] Frieren - 12 (1080p) [ABCD1234].mkv',
      ],
      'Show.Name.S02E03.1080p.WEB-DL.x265-GRP.mkv': <String>[
        'Show Name',
        'Show.Name.S02E03.1080p.WEB-DL.x265-GRP.mkv',
      ],
      'Movie.Title.2019.1080p.BluRay.x264-GRP': <String>[
        'Movie Title',
        'Movie.Title.2019.1080p.BluRay.x264-GRP',
      ],
      'Re:Zero 1x05': <String>['Re:Zero', 'Re:Zero 1x05'],
      'Mushishi EP 12': <String>['Mushishi', 'Mushishi EP 12'],
      'Attack on Titan Season 2': <String>[
        'Attack on Titan',
        'Attack on Titan Season 2',
      ],
      // Plain titles stay as they are.
      'The Ramparts of Ice': <String>['The Ramparts of Ice'],
      "Charlotte's Web": <String>["Charlotte's Web"],
      'Spy x Family': <String>['Spy x Family'],
      'Mr. Robot': <String>['Mr. Robot'],
      'Dr.Stone': <String>['Dr.Stone'],
      'Episode': <String>['Episode'],
      '86': <String>['86'],
      'Catch-22': <String>['Catch-22'],
      // A slug with more than one hyphen still loses its volume number.
      'Karakai-Jouzu-Takagi-san-02': <String>[
        'Karakai-Jouzu-Takagi-san',
        'Karakai-Jouzu-Takagi-san-02',
      ],
      'よつばと!': <String>['よつばと!'],
      // A short Latin part is not split off (it could match anything).
      'とある魔術の禁書目録 SS': <String>['とある魔術の禁書目録 SS'],
      // Nothing left after cleaning: the original only.
      '(HD Scan)': <String>['(HD Scan)'],
      '[水谷フーカ]': <String>['[水谷フーカ]'],
      // A parenthesis that is not a release tag stays.
      'Fate (Zero) Origins': <String>['Fate (Zero) Origins'],
    };
    for (final MapEntry<String, List<String>> row in table.entries) {
      test(row.key, () {
        expect(localTitleSearchCandidates(row.key), row.value);
      });
    }

    test('never empty, never an empty candidate, original last', () {
      for (final String title in <String>[
        ...table.keys,
        '   ',
        '01',
        'Vol.3',
        '[a] [b]',
      ]) {
        final List<String> out = localTitleSearchCandidates(title);
        expect(out, isNotEmpty, reason: title);
        expect(out.last, title.trim().isEmpty ? title : title.trim());
        if (title.trim().isNotEmpty) {
          expect(out, everyElement(isNotEmpty), reason: title);
        }
      }
    });

    test('the shelf series key is unchanged', () {
      final BookSeriesKey? key = parseBookSeriesKey('Ajin (HD Scan) Ajin 01');
      expect(key?.key, 'ajin (hd scan) ajin');
      expect(key?.seriesTitle, 'Ajin (HD Scan) Ajin');
      expect(key?.volume, 1);
    });
  });

  group('matching the user titles', () {
    test('Ajin (HD Scan) Ajin 01: was no match (query "Ajin (HD Scan) Ajin"), '
        'now an automatic link', () {
      final TitleMatchQuery query = TitleMatchQuery.fromLocalTitle(
        'Ajin (HD Scan) Ajin 01',
      );
      expect(query.searchTerms.first, 'Ajin');
      expect(query.volume, 1);
      final TitleMatchDecision<int> decision = decideTitleMatch(
        query,
        <TitleMatchCandidate<int>>[
          _site(1, <String>['Ajin', '亜人', 'Ajin: Demi-Human']),
          _site(2, <String>['Ajin-chan wa Kataritai']),
        ],
      );
      expect(decision.auto?.candidate.id, 1);
      expect(decision.auto?.score, 1);
    });

    test('14 Sai no Koi: both names are searched before the full title', () {
      final TitleMatchQuery query = TitleMatchQuery.fromLocalTitle(
        '14 Sai no Koi [水谷フーカ] 14歳の恋 第01巻',
      );
      expect(query.searchTerms.take(2), <String>['14 Sai no Koi', '14歳の恋']);
      final TitleMatchDecision<int> decision = decideTitleMatch(
        query,
        <TitleMatchCandidate<int>>[
          _site(3, <String>['14-sai no Koi', '14歳の恋']),
        ],
      );
      expect(decision.auto?.candidate.id, 3);
    });
  });
}
