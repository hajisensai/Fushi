import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_coordinator.dart';

void main() {
  group('isEpisodeLabelTitle', () {
    for (final String label in <String>[
      '01',
      '02',
      '第01集',
      '第01话',
      'S01E01',
      'E05',
      // 两位纯数字文件名的常见含义就是集号；番名「86」靠目录名候选兜住
      // （见下面 videoScrapeTitleCandidates 的用例）。
      '86',
    ]) {
      test('"$label" is an episode label, not a title', () {
        expect(isEpisodeLabelTitle(label), isTrue, reason: label);
      });
    }

    for (final String title in <String>[
      '葬送的芙莉莲',
      'Sousou no Frieren',
      '1917',
      '2001',
      'Oshi no Ko S2',
      '',
    ]) {
      test('"$title" stays a searchable title', () {
        expect(isEpisodeLabelTitle(title), isFalse, reason: title);
      });
    }
  });

  group('videoScrapeTitleCandidates', () {
    test('drops file-derived episode labels but keeps directory names', () {
      final List<String> candidates = videoScrapeTitleCandidates(
        workTitle: '01',
        parsedSeries: '01',
        videoPath: r'D:\Videos\动漫\葬送的芙莉莲\01.mp4',
      );
      expect(candidates, isNot(contains('01')));
      expect(candidates.first, '葬送的芙莉莲');
      expect(candidates, contains('动漫'));
    });

    test('a directory literally named after a numeric title is kept', () {
      final List<String> candidates = videoScrapeTitleCandidates(
        workTitle: '86',
        parsedSeries: '86',
        videoPath: r'D:\Videos\86\86 - 01.mkv',
      );
      // 文件派生的「86」被剔除，目录名「86」仍进候选。
      expect(candidates, contains('86'));
    });

    test('keeps the cleaned title ahead of the raw directory block', () {
      final List<String> candidates = videoScrapeTitleCandidates(
        workTitle: 'Sousou no Frieren',
        parsedSeries: 'Sousou no Frieren',
        videoPath:
            r'D:\Videos\[Sakurato] Sousou no Frieren [01-28][1080p]\[Sakurato] Sousou no Frieren [01][1080p].mp4',
      );
      expect(candidates.first, 'Sousou no Frieren');
      expect(
        candidates,
        contains('[Sakurato] Sousou no Frieren [01-28][1080p]'),
      );
      expect(candidates.toSet().length, candidates.length);
    });
  });
}
