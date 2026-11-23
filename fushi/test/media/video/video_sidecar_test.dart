import 'package:test/test.dart';
import 'package:fushi_engine/media/video/video_sidecar.dart';

void main() {
  group('pickSidecar（按 app 学习语言优先）', () {
    const String base = "Miss Kobayashi's Dragon Maid - S01E01";

    test('学日语：.ja.srt 优先于其它语言/无语言标记', () {
      final List<String> files = <String>[
        '$base.mkv',
        '$base.srt',
        '$base.en.srt',
        '$base.ja.ass',
        '$base.ja.srt',
      ];
      expect(pickSidecar(base, files, langCode: 'ja'), '$base.ja.srt');
    });

    test('学日语无 .ja.srt：退到 .ja.ass', () {
      final List<String> files = <String>[
        '$base.mkv',
        '$base.ja.ass',
        '$base.srt',
      ];
      expect(pickSidecar(base, files, langCode: 'ja'), '$base.ja.ass');
    });

    test('学韩语但无 ko 标记：回退无语言标记的 .srt', () {
      final List<String> files = <String>[
        '$base.mkv',
        '$base.ja.srt',
        '$base.en.srt',
        '$base.srt',
      ];
      expect(pickSidecar(base, files, langCode: 'ko'), '$base.srt');
    });

    test('学韩语命中 .ko.srt 优先', () {
      final List<String> files = <String>[
        '$base.mkv',
        '$base.ja.srt',
        '$base.ko.srt',
        '$base.srt',
      ];
      expect(pickSidecar(base, files, langCode: 'ko'), '$base.ko.srt');
    });

    test('学英语：.en.srt 优先于 .ja.srt 与无语言标记', () {
      final List<String> files = <String>[
        '$base.mkv',
        '$base.srt',
        '$base.ja.srt',
        '$base.en.srt',
      ];
      expect(pickSidecar(base, files, langCode: 'en'), '$base.en.srt');
    });

    test('无语言标记字幕全格式优先级：srt > ass > ssa > vtt', () {
      final List<String> files = <String>[
        '$base.mkv',
        '$base.vtt',
        '$base.ssa',
        '$base.ass',
        '$base.srt',
      ];
      expect(pickSidecar(base, files, langCode: 'ja'), '$base.srt');
    });

    test('语言标记字幕全格式优先级：.ja.srt > .ja.ass > .ja.ssa > .ja.vtt', () {
      final List<String> files = <String>[
        '$base.mkv',
        '$base.ja.vtt',
        '$base.ja.ssa',
        '$base.ja.ass',
      ];
      expect(pickSidecar(base, files, langCode: 'ja'), '$base.ja.ass');
    });

    test('语言标记字幕整体优先于无语言标记（.ja.vtt 胜过 .srt）', () {
      final List<String> files = <String>[
        '$base.mkv',
        '$base.srt',
        '$base.ja.vtt',
      ];
      expect(pickSidecar(base, files, langCode: 'ja'), '$base.ja.vtt');
    });

    test('无任何同名字幕返回 null', () {
      final List<String> files = <String>['$base.mkv', 'other.srt'];
      expect(pickSidecar(base, files, langCode: 'ja'), isNull);
    });

    test('大小写不敏感匹配，返回原始文件名', () {
      final List<String> files = <String>['$base.JA.SRT'];
      expect(pickSidecar(base, files, langCode: 'ja'), '$base.JA.SRT');
    });
  });

  // 拍板台 review-hbk-audit-220-player-sub-owner：播放器选 / 列字幕、删视频带走字幕、
  // iOS 收件箱搬入共用「最长文件名主干认领字幕」。
  group('最长主干认领字幕', () {
    test('EP01.mkv 与 EP01.ja.mkv 并存：EP01.ja.srt 归 EP01.ja，EP01 不选它', () {
      final List<String> dir = <String>[
        'EP01.mkv',
        'EP01.ja.mkv',
        'EP01.ja.srt',
        'EP01.srt',
      ];
      expect(pickSidecar('EP01', dir, langCode: 'ja'), 'EP01.srt');
      expect(listSidecarSubtitles('EP01', dir), <String>['EP01.srt']);
      expect(pickSidecar('EP01.ja', dir, langCode: 'ja'), 'EP01.ja.srt');
      expect(listSidecarSubtitles('EP01.ja', dir), <String>['EP01.ja.srt']);
    });

    test('较短 stem 的视频没有自己的字幕时选不到别人的', () {
      final List<String> dir = <String>[
        'EP01.mkv',
        'EP01.ja.mkv',
        'EP01.ja.srt',
      ];
      expect(pickSidecar('EP01', dir, langCode: 'ja'), isNull);
      expect(listSidecarSubtitles('EP01', dir), isEmpty);
    });

    test('没有更长主干的视频时，EP01.ja.srt 仍是 EP01 的日语轨', () {
      final List<String> dir = <String>['EP01.mkv', 'EP01.ja.srt'];
      expect(pickSidecar('EP01', dir, langCode: 'ja'), 'EP01.ja.srt');
    });

    test('认领不分大小写；非视频文件（封面 / nfo / 字幕本身）不认领', () {
      expect(
        listSidecarSubtitles('ep01', <String>[
          'ep01.mkv',
          'EP01.JA.MKV',
          'ep01.ja.ass',
        ]),
        isEmpty,
      );
      expect(
        listSidecarSubtitles('EP01', <String>[
          'EP01.mkv',
          'EP01.ja.jpg',
          'EP01.ja.nfo',
          'EP01.ja.srt',
        ]),
        <String>['EP01.ja.srt'],
      );
    });

    test('ep01.5.mkv 认领 ep01.5.srt，ep01 的其余字幕不受影响', () {
      final List<String> dir = <String>[
        'ep01.mkv',
        'ep01.5.mkv',
        'ep01.5.srt',
        'ep01.ja.srt',
        'ep01.srt',
      ];
      expect(listSidecarSubtitles('ep01', dir), <String>[
        'ep01.ja.srt',
        'ep01.srt',
      ]);
      expect(listSidecarSubtitles('ep01.5', dir), <String>['ep01.5.srt']);
    });

    test('sidecarSubtitleOwnerStem：取能配上的最长 stem，原样返回，配不上为 null', () {
      expect(
        sidecarSubtitleOwnerStem('EP01.ja.srt', <String>['EP01', 'ep01.JA']),
        'ep01.JA',
      );
      expect(
        sidecarSubtitleOwnerStem('EP01.srt', <String>['EP01', 'EP01.ja']),
        'EP01',
      );
      expect(sidecarSubtitleOwnerStem('EP02.srt', <String>['EP01']), isNull);
      expect(
        sidecarSubtitleOwnerStem('EP01.ja.srt', <String>['EP01.ja.x']),
        isNull,
      );
    });
  });
}
