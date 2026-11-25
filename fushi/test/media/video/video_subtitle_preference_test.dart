import 'package:test/test.dart';
import 'package:fushi_engine/media/video/video_subtitle_source.dart';

void main() {
  group('pickSameNameSubs（外挂字幕只列当前集同名前缀）', () {
    const String base = "Miss Kobayashi's Dragon Maid - S01E01";

    test('龙女仆 S01E01 在一堆 S01E0x.ja.srt 中只挑 S01E01.ja.srt', () {
      final List<String> dirFiles = <String>[
        '$base.mkv',
        '$base.ja.srt',
        "Miss Kobayashi's Dragon Maid - S01E02.ja.srt",
        "Miss Kobayashi's Dragon Maid - S01E03.ja.srt",
        'random.srt',
      ];
      expect(pickSameNameSubs(base, dirFiles, langCode: 'ja'), <String>[
        '$base.ja.srt',
      ]);
    });

    test('同集多语言后缀都列出（.ja.srt + .en.srt）', () {
      final List<String> dirFiles = <String>[
        '$base.mkv',
        '$base.ja.srt',
        '$base.en.srt',
        "Miss Kobayashi's Dragon Maid - S01E02.ja.srt",
      ];
      expect(
        pickSameNameSubs(base, dirFiles, langCode: 'ja'),
        containsAll(<String>['$base.ja.srt', '$base.en.srt']),
      );
      expect(pickSameNameSubs(base, dirFiles, langCode: 'ja'), hasLength(2));
    });

    test('学习语言标记字幕排在前（学日语 → .ja.srt 排 .en.srt 之前）', () {
      final List<String> dirFiles = <String>[
        '$base.mkv',
        '$base.en.srt',
        '$base.srt',
        '$base.ja.srt',
      ];
      expect(pickSameNameSubs(base, dirFiles, langCode: 'ja'), <String>[
        '$base.ja.srt',
        '$base.en.srt',
        '$base.srt',
      ]);
    });

    test('学韩语 → .ko.srt 排前，无 ko 则按原序', () {
      final List<String> dirFiles = <String>[
        '$base.mkv',
        '$base.ja.srt',
        '$base.ko.srt',
        '$base.srt',
      ];
      expect(pickSameNameSubs(base, dirFiles, langCode: 'ko'), <String>[
        '$base.ko.srt',
        '$base.ja.srt',
        '$base.srt',
      ]);
    });

    test('无后缀的精确同名字幕也列出（base.srt）', () {
      final List<String> dirFiles = <String>['$base.mkv', '$base.srt'];
      expect(pickSameNameSubs(base, dirFiles, langCode: 'ja'), <String>[
        '$base.srt',
      ]);
    });

    test('大小写不敏感匹配，返回原始文件名', () {
      final List<String> dirFiles = <String>['$base.JA.SRT'];
      expect(pickSameNameSubs(base, dirFiles, langCode: 'ja'), <String>[
        '$base.JA.SRT',
      ]);
    });

    test('只收 srt/ass/ssa/vtt 扩展名，前缀同名但非字幕的文件不列', () {
      final List<String> dirFiles = <String>[
        '$base.mkv',
        '$base.nfo',
        '$base.ja.srt',
        '$base.txt',
      ];
      expect(pickSameNameSubs(base, dirFiles, langCode: 'ja'), <String>[
        '$base.ja.srt',
      ]);
    });

    test('前缀不同名（别集）一律不列', () {
      final List<String> dirFiles = <String>[
        "Miss Kobayashi's Dragon Maid - S01E02.ja.srt",
        'S01E01.ja.srt',
      ];
      expect(pickSameNameSubs(base, dirFiles, langCode: 'ja'), isEmpty);
    });
  });

  group('isImportedExternalSubtitlePath（真实下载文件名，用户报「退出再进字幕没了」）', () {
    // 用户实测截图里的 Jimaku 候选文件名：带括号、CRC、双语后缀。恢复捷径靠这个判据
    // 决定「要不要按路径直接加载」——它一旦认不出，重进就会掉回「只扫视频同目录」的
    // 分支，而下载的字幕根本不住在那儿，字幕就此消失（BUG-1848 同批）。
    test('括号 / CRC / 双语后缀都不影响识别', () {
      for (final String name in <String>[
        '(Hi10)_Re_Zero_-_01_(BD_720p)_(BlurayDesuYo)_(DB3C1337).ja-en.ass',
        '[Kamigami] Re Zero kara Hajimeru Isekai Seikatsu - 01v3 '
            '[1920x1080 x265 Ma10p AAC][JPN].ass',
        'Re_ゼロから始める異世界生活.新編集版.S01E01.WEBRip.Netflix.ja[cc].srt',
        'Re Life in a different world from zero.S01E01.WEBRip.ja[cc].srt',
      ]) {
        expect(
          isImportedExternalSubtitlePath(
            '/home/u/Documents/app/video_subtitles/$name',
          ),
          isTrue,
          reason: '认不出就等于重进后字幕消失：$name',
        );
      }
    });

    test('内嵌源与非字幕扩展名仍然不认', () {
      expect(isImportedExternalSubtitlePath('embedded:2'), isFalse);
      expect(isImportedExternalSubtitlePath(''), isFalse);
      expect(
        isImportedExternalSubtitlePath('/x/video_subtitles/subs.zip'),
        isFalse,
      );
    });
  });
}
