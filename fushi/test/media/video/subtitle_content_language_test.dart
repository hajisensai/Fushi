// B1 字幕搜索重做：正文语言检测纯函数。文件名标签常错（上传者复制模板/打包
// 改名），正文是权威——阈值与 RSS-Subtitle-Manager 对齐，逐条规则单测。
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/subtitle/subtitle_content_language.dart';

String _srt(List<String> lines) {
  final StringBuffer sb = StringBuffer();
  for (int i = 0; i < lines.length; i++) {
    sb
      ..writeln(i + 1)
      ..writeln('00:0$i:00,000 --> 00:0$i:02,000')
      ..writeln(lines[i])
      ..writeln();
  }
  return sb.toString();
}

String _ass(List<String> lines) {
  final StringBuffer sb = StringBuffer()
    ..writeln('[Script Info]')
    ..writeln('Title: x')
    ..writeln('[Events]')
    ..writeln('Format: Layer, Start, End, Style, Name, MarginL, MarginR, '
        'MarginV, Effect, Text');
  for (final String line in lines) {
    sb.writeln('Dialogue: 0,0:00:00.00,0:00:02.00,Default,,0,0,0,,$line');
  }
  return sb.toString();
}

void main() {
  group('extractSubtitleDialogueLines', () {
    test('SRT 丢序号/时间轴，保对白', () {
      final List<String> lines = extractSubtitleDialogueLines(
        _srt(<String>['こんにちは', 'Hello there']),
      );
      expect(lines, <String>['こんにちは', 'Hello there']);
    });

    test('ASS 取 Dialogue 第 10 字段起，Text 内逗号不截断，\\N 拆行、剥标签', () {
      final List<String> lines = extractSubtitleDialogueLines(
        _ass(<String>[r'{\an8}おはよう、世界\N你好，世界', '<i>styled</i>']),
      );
      expect(lines, <String>['おはよう、世界', '你好，世界', 'styled']);
    });
  });

  group('detectSubtitleContentLanguage', () {
    test('假名足量 → 日语', () {
      expect(
        detectSubtitleContentLanguage(_srt(<String>[
          'こんにちは、世界',
          '今日はいい天気ですね',
        ])),
        SubtitleContentLanguage.japanese,
      );
    });

    test('日语字幕里的汉字拟声行不构成双语（行数与总量双门槛）', () {
      expect(
        detectSubtitleContentLanguage(_srt(<String>[
          'それでは、始めましょう',
          'あの音は何だろう',
          '物音', // 单个无假名汉字行：不是中文轨
          'きっと風の音ですよ',
        ])),
        SubtitleContentLanguage.japanese,
      );
    });

    test('逐行日文+中文（\\N 双语）→ 中日双语', () {
      expect(
        detectSubtitleContentLanguage(_ass(<String>[
          r'おはようございます\N早上好各位观众朋友们',
          r'今日はいい天気ですね\N今天天气真不错啊朋友',
          r'それでは始めましょう\N那么我们现在就开始吧',
        ])),
        SubtitleContentLanguage.bilingualJaZh,
      );
    });

    // 回归锚：中文字幕组的 .ass 几乎标配几行日文 OP/ED 卡拉 OK 歌词。旧判据只拿汉字
    // 总量跟自己的五分之一比，门槛恒被自己撑爆 → 整份中文字幕被判成「中日双语」。
    test('中文正文 + 零星日文 OP 歌词 → 中文（不是双语）', () {
      final List<String> lines = <String>[
        // 日文歌词 3 行（假名足量，会进日语分支）
        'きらきら光る夜空の星よ',
        'ずっと君のそばにいたいよ',
        'この気持ちを歌にのせて',
        // 中文对白 30 行：占对白行 91%
        for (int i = 0; i < 30; i++) '这是一句很普通的中文对白内容',
      ];
      expect(
        detectSubtitleContentLanguage(_srt(lines)),
        SubtitleContentLanguage.simplifiedChinese,
        reason: '日文歌词只占 9% 的行，不构成日语轨',
      );
    });

    // 反向对称：日语正文 + 零星中文注释行，同样不该判双语。
    test('日语正文 + 零星汉字行 → 日语（不是双语）', () {
      final List<String> lines = <String>[
        for (int i = 0; i < 30; i++) 'これは普通の日本語のセリフです',
        '注釈文字列',
        '補足説明文',
        '追加情報行',
      ];
      expect(
        detectSubtitleContentLanguage(_srt(lines)),
        SubtitleContentLanguage.japanese,
        reason: '无假名汉字行只占 9% 的行，不构成中文轨',
      );
    });

    test('简体正文 → 简体中文', () {
      expect(
        detectSubtitleContentLanguage(_srt(<String>[
          '这个时间点我们还没开始',
          '他们说这样也可以',
        ])),
        SubtitleContentLanguage.simplifiedChinese,
      );
    });

    test('繁体正文 → 繁體中文', () {
      expect(
        detectSubtitleContentLanguage(_srt(<String>[
          '這個時間點我們還沒開始',
          '他們說這樣也可以',
        ])),
        SubtitleContentLanguage.traditionalChinese,
      );
    });

    test('拉丁字母足量 → 英语', () {
      expect(
        detectSubtitleContentLanguage(_srt(<String>[
          'The quick brown fox jumps over the lazy dog',
        ])),
        SubtitleContentLanguage.english,
      );
    });

    test('样本不足 → unknown（不猜）', () {
      expect(
        detectSubtitleContentLanguage(_srt(<String>['ok'])),
        SubtitleContentLanguage.unknown,
      );
      expect(
        detectSubtitleContentLanguage(''),
        SubtitleContentLanguage.unknown,
      );
    });
  });

  test('coarse 投影与母语标签', () {
    expect(coarseLanguageCode(SubtitleContentLanguage.japanese), 'ja');
    expect(coarseLanguageCode(SubtitleContentLanguage.bilingualJaZh), 'zh');
    expect(coarseLanguageCode(SubtitleContentLanguage.unknown), isNull);
    expect(
      subtitleContentLanguageNativeLabel(
        SubtitleContentLanguage.simplifiedChinese,
      ),
      '简体中文',
    );
  });
}
