import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/audiobook/audiobook_material_library.dart';

/// 素材文件名的形态取自真实字幕库（TMW audiobook srt part1~11，1716 个文件）：
/// 1074 个带 Audible ASIN、49 个带 `audiobook.jp`/`kikubon` 编号、其余只有书名，
/// 且卷号 `[01]` / `[1巻]` / `[10.5巻]` 大量与身份键同名出现在同一个文件名里。
const Set<String> _subtitleExts = <String>{
  '.srt',
  '.lrc',
  '.vtt',
  '.ass',
  '.ssa',
};
const Set<String> _contentExts = <String>{'.epub', '.txt'};

void main() {
  group('audiobookMaterialKeyOf', () {
    test('三套 id 体系都按同一条判据认出来', () {
      expect(
        audiobookMaterialKeyOf(r'D:\srt\#真相をお話しします [B0B58GV92J].srt'),
        'B0B58GV92J',
      );
      expect(
        audiobookMaterialKeyOf('[01] MM9 [kikubon 139].srt'),
        'kikubon 139',
      );
      expect(
        audiobookMaterialKeyOf(
          '[01] medium 霊媒探偵城塚翡翠 [audiobook.jp 259377].srt',
        ),
        'audiobook.jp 259377',
      );
    });

    test('卷号不被误当身份键——哪怕它排在身份键前面', () {
      // 真实形状：卷号在前、ASIN 在后，取的必须是后者。
      expect(
        audiobookMaterialKeyOf('[01] Fate/strange Fake(1) [B0D4LQY5K7].srt'),
        'B0D4LQY5K7',
      );
      expect(audiobookMaterialKeyOf('[01] MM9.srt'), isNull);
      expect(audiobookMaterialKeyOf('[1巻] リアデイルの大地にて.srt'), isNull);
      expect(
        audiobookMaterialKeyOf('[10.5巻] やはり俺の青春ラブコメはまちがっている。１０．５.srt'),
        isNull,
      );
    });

    test('形似但不合规的方括号内容一律不认', () {
      // 长度不对 / 不以 B0 开头 / 站点名后不是数字：都不是身份键。
      expect(audiobookMaterialKeyOf('x [B0B58GV92].srt'), isNull);
      expect(audiobookMaterialKeyOf('x [B0B58GV92JQ].srt'), isNull);
      expect(audiobookMaterialKeyOf('x [A1B58GV92J].srt'), isNull);
      expect(audiobookMaterialKeyOf('x [kikubon abc].srt'), isNull);
      expect(audiobookMaterialKeyOf('x [audiobook.jp].srt'), isNull);
      expect(audiobookMaterialKeyOf('没有方括号.srt'), isNull);
    });
  });

  group('audiobookMaterialTitleKeyOf', () {
    test('剥掉作者/卷号方括号后归一化', () {
      expect(
        audiobookMaterialTitleKeyOf(r'D:\books\[今村昌弘] 屍人荘の殺人.epub'),
        audiobookMaterialTitleKeyOf('屍人荘の殺人.epub'),
      );
    });

    test('整个名字都是方括号时退回 stem,不塌成空串', () {
      // 否则这类文件会全部挤进同一个空键，互相覆盖。
      final String a = audiobookMaterialTitleKeyOf('[B0B58GV92J].srt');
      final String b = audiobookMaterialTitleKeyOf('[B0D4LQY5K7].srt');
      expect(a, isNotEmpty);
      expect(a, isNot(b));
    });
  });

  group('indexAudiobookMaterials', () {
    test('按扩展名分流,身份键优先,无键者进标题索引', () {
      final AudiobookMaterialIndex index = indexAudiobookMaterials(
        <String>[
          r'D:\m\#真相をお話しします [B0B58GV92J].srt',
          r'D:\m\[01] MM9 [kikubon 139].srt',
          r'D:\m\64（ロクヨン）上.srt',
          r'D:\m\[今村昌弘] 屍人荘の殺人.epub',
          r'D:\m\某作品 [B0D4LQY5K7].epub',
          r'D:\m\封面.jpg',
          r'D:\m\说明.pdf',
        ],
        subtitleExtensions: _subtitleExts,
        contentExtensions: _contentExts,
      );
      expect(index.subtitleByKey['B0B58GV92J'], endsWith('[B0B58GV92J].srt'));
      expect(index.subtitleByKey['kikubon 139'], endsWith('[kikubon 139].srt'));
      expect(index.contentByKey['B0D4LQY5K7'], endsWith('[B0D4LQY5K7].epub'));
      // 纯书名的进标题索引，不进身份索引。
      expect(index.subtitleByKey.containsKey('64（ロクヨン）上'), isFalse);
      expect(index.subtitleByTitle, isNotEmpty);
      expect(index.contentByTitle, isNotEmpty);
      // 非素材扩展名被忽略。
      expect(index.identifiedWorkCount, 3);
    });

    test('同一作品多份素材:先到先得,不被后来的覆盖', () {
      final AudiobookMaterialIndex index = indexAudiobookMaterials(
        <String>[
          r'D:\a\first [B0B58GV92J].srt',
          r'D:\b\second [B0B58GV92J].srt',
        ],
        subtitleExtensions: _subtitleExts,
        contentExtensions: _contentExts,
      );
      expect(index.subtitleByKey['B0B58GV92J'], contains('first'));
    });

    test('空库是 empty', () {
      expect(
        indexAudiobookMaterials(
          const <String>[],
          subtitleExtensions: _subtitleExts,
          contentExtensions: _contentExts,
        ).isEmpty,
        isTrue,
      );
      expect(const AudiobookMaterialIndex.empty().isEmpty, isTrue);
    });
  });

  group('matchAudiobookMaterial', () {
    final AudiobookMaterialIndex index = indexAudiobookMaterials(
      <String>[r'D:\m\#真相をお話しします [B0B58GV92J].srt', r'D:\m\屍人荘の殺人.epub'],
      subtitleExtensions: _subtitleExts,
      contentExtensions: _contentExts,
    );

    test('身份键命中字幕,标题命中正文并标记为弱匹配', () {
      final AudiobookMaterialMatch m = matchAudiobookMaterial(
        index,
        key: 'B0B58GV92J',
        title: '屍人荘の殺人',
      );
      expect(m.subtitlePath, endsWith('[B0B58GV92J].srt'));
      expect(m.subtitleIsWeakMatch, isFalse);
      expect(m.contentPath, endsWith('屍人荘の殺人.epub'));
      // 正文是靠标题猜的——这件事必须能传到 UI，不能冒充原书。
      expect(m.contentIsWeakMatch, isTrue);
      expect(m.hasSubtitle, isTrue);
    });

    test('键不认识且标题不匹配时空手而归,不乱配', () {
      final AudiobookMaterialMatch m = matchAudiobookMaterial(
        index,
        key: 'B0XXXXXXXX',
        title: '完全无关的书',
      );
      expect(m.isEmpty, isTrue);
    });

    test('只有标题没有键也能配,但一律标弱匹配', () {
      final AudiobookMaterialMatch m = matchAudiobookMaterial(
        index,
        title: '屍人荘の殺人',
      );
      expect(m.contentPath, isNotNull);
      expect(m.contentIsWeakMatch, isTrue);
      expect(m.subtitlePath, isNull);
    });

    test('键和标题都没有给出时不配任何东西', () {
      expect(matchAudiobookMaterial(index).isEmpty, isTrue);
      expect(matchAudiobookMaterial(index, title: '   ').isEmpty, isTrue);
    });
  });
}
