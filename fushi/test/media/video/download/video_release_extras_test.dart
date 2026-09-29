import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/video/download/video_download_organizer.dart';
import 'package:fushi_engine/media/video/download/video_release_extras.dart';

void main() {
  group('looksLikeExtrasOnlyRelease', () {
    const List<String> extrasOnly = <String>[
      '[Group] Show - NCOP (1080p)',
      '[Group] Show NCED 1080p',
      'Show PV 1080p',
      '[Group] Show - PV2',
      '[Group] Show Trailer',
      'Show 予告',
      '【特典映像】Show',
      '[Group] Show Menu',
      'Show CM集',
      '[Group] Show Creditless OP 1080p AAC2.0',
    ];
    for (final String title in extrasOnly) {
      test('只有特典：$title', () {
        expect(looksLikeExtrasOnlyRelease(title), isTrue);
      });
    }

    const List<String> mainContent = <String>[
      '[SubsPlease] Show - 05 (1080p)',
      'Show Special Edition 2020 1080p BluRay',
      '[Group] Show S01 Complete Batch',
      'Doraemon Movie 2020 1080p',
      // 含特典的合集不是「只有特典」。
      '[VCB-Studio] Show [Ma10p_1080p] (BD+SPs)',
      'Extra Ordinary 2019 1080p',
      '[Group] Show 01-12 + NCOP/NCED [1080p]',
      'Trailer Park Boys S01 1080p',
      '[Group] Show - 03 [NCED version]',
      '[Group][Show][05][1080p] PV',
      'Show OVA 1080p',
      'Show SP 1080p',
    ];
    for (final String title in mainContent) {
      test('有正片：$title', () {
        expect(looksLikeExtrasOnlyRelease(title), isFalse);
      });
    }
  });

  group('isVideoDownloadExtraFile', () {
    List<TorrentFileEntry> entries(List<String> names) => <TorrentFileEntry>[
      for (int i = 0; i < names.length; i++)
        TorrentFileEntry(name: names[i], size: 1, progress: 0, index: i),
    ];

    test('特典目录与严格附件名命中，正片不命中', () {
      final List<TorrentFileEntry> files = entries(<String>[
        'Show/EP01.mkv',
        'Show/SPs/Making - 05.mkv',
        'Show/Scans/cover.jpg',
        'Show/[Group] Show NCOP1.mkv',
        'Show/Special A - 01.mkv',
      ]);
      final String? root = videoDownloadSharedRoot(files);
      expect(root, 'Show');
      bool extra(String name) =>
          isVideoDownloadExtraFile(name, sharedRoot: root);
      expect(extra('Show/EP01.mkv'), isFalse);
      expect(extra('Show/SPs/Making - 05.mkv'), isTrue);
      expect(extra('Show/Scans/cover.jpg'), isTrue, reason: '非视频的特典目录文件');
      expect(extra('Show/[Group] Show NCOP1.mkv'), isTrue);
      expect(
        extra('Show/Special A - 01.mkv'),
        isFalse,
        reason: 'BUG-1969 宽词不误伤',
      );
    });

    test('发布根目录名恰好是特典词时不当特典', () {
      final List<TorrentFileEntry> files = entries(<String>[
        'Extras/EP01.mkv',
        'Extras/EP02.mkv',
      ]);
      final String? root = videoDownloadSharedRoot(files);
      expect(root, 'Extras');
      expect(
        isVideoDownloadExtraFile('Extras/EP01.mkv', sharedRoot: root),
        isFalse,
      );
    });

    test('视频扩展名判据与整理器一致', () {
      expect(isVideoDownloadVideoFile('a/b.MKV'), isTrue);
      expect(isVideoDownloadVideoFile('a/b.ass'), isFalse);
    });
  });
}
