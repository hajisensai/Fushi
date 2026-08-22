import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';

/// [subtitleLookupTerm] 的不变式：查询串只由**起点**决定，终点恒为句尾。
///
/// TODO-916 症状③（起点）：旧逻辑 `sentence.characters.skip(graphemeIndex).join()`
/// 从被点字位起算，拉丁词点中间字母（"hello" 点 'e'）得到 "ello" 查不到。修复是把
/// 拉丁命中的**起点**回退到词首。
///
/// BUG-1773（终点）：上面那次修复顺手把拉丁分支的**终点**也钉死在词尾，于是查询串
/// 被截成单个单词，`listen to` / `look forward to` 这类空格分词短语的词条永远匹配
/// 不到——点 "listen" 只出 listen，而点它前面的空格（走 CJK 的「到句尾」分支）反而
/// 能查出短语。终点从来不该由脚本决定：引擎按查询串做最长匹配并回报 `bestLength`，
/// C++ `scan_candidates` 明确禁止在空格分词语言的单词中间切，候选恒是
/// `listen to music` / `listen to` / `listen`，单词自己不会被短语挤掉。
///
/// 守卫是 load-bearing：
/// - 把终点改回「延伸到词尾」→「短语可达」整组红；
/// - 把起点改回裸 `skip(graphemeIndex)` →「点中间字母从词首起」整组红。
void main() {
  group('subtitleLookupTerm — 起点：拉丁词点任意位置都从词首起查', () {
    test('点 "hello" 任意 index（含首/中/尾）都从词首起', () {
      const String hello = 'hello';
      for (int i = 0; i < hello.characters.length; i++) {
        expect(subtitleLookupTerm(hello, i), 'hello',
            reason: 'tap at index $i should start at the word head');
      }
    });

    test('句中单词点中间字母从词首起（不是从被点字母起）', () {
      const String s = 'say hello world';
      // 'say'=0..2, ' '=3, 'hello'=4..8, ' '=9, 'world'=10..14
      expect(subtitleLookupTerm(s, 5).startsWith('hello'), isTrue); // 'e'
      expect(subtitleLookupTerm(s, 8).startsWith('hello'), isTrue); // 'o'
      expect(subtitleLookupTerm(s, 0).startsWith('say'), isTrue);
      expect(subtitleLookupTerm(s, 12), 'world'); // 'r'，词首在 10，到句尾
    });

    test('重音字母（café）按拉丁词回退到词首', () {
      const String s = 'un café noir';
      // 'café' 占 index 3..6（é 是单个字位簇）
      expect(subtitleLookupTerm(s, 5), 'café noir'); // 'f'
      expect(subtitleLookupTerm(s, 6), 'café noir'); // 'é'
    });

    test('连字号是词首边界（well-known 的 known 不回退到 well）', () {
      const String s = 'well-known';
      expect(subtitleLookupTerm(s, 1), 'well-known'); // 'e'，词首=0
      expect(subtitleLookupTerm(s, 6), 'known'); // 'n' after hyphen，词首=5
    });

    test('数字与字母同词（mp3 回退到 m）', () {
      const String s = 'play mp3 file';
      expect(subtitleLookupTerm(s, 5), 'mp3 file'); // 'm'
      expect(subtitleLookupTerm(s, 7), 'mp3 file'); // '3'
    });
  });

  group('subtitleLookupTerm — BUG-1773 终点：查询串必须留到句尾（短语可达）', () {
    const String s = 'I listen to music.';
    // 'I'=0, ' '=1, 'listen'=2..7, ' '=8, 'to'=9..10, ' '=11, 'music'=12..16, '.'=17

    test('点 "listen" 的任意字母，查询串都保留后续 " to"', () {
      for (int i = 2; i <= 7; i++) {
        final String term = subtitleLookupTerm(s, i);
        expect(term, 'listen to music.',
            reason: 'tap at index $i must keep the rest of the sentence');
        expect(term.startsWith('listen to'), isTrue,
            reason: '引擎要能把 "listen to" 当候选，查询串必须含空格与后一个词');
      }
    });

    test('点单词与点它前面的空格给出同样的短语可达性', () {
      // 修复前：点空格（非拉丁 → 到句尾）能查出短语，点单词（截到词尾）不能。
      // 这个不对称正是 BUG-1773 的用户可见症状。
      expect(subtitleLookupTerm(s, 1).contains('listen to'), isTrue); // 空格
      expect(subtitleLookupTerm(s, 2).contains('listen to'), isTrue); // 'l'
    });

    test('句尾单词没有后文可留，等于单词本身', () {
      expect(subtitleLookupTerm('a phrase', 2), 'phrase');
    });
  });

  group('subtitleLookupTerm — CJK 逐字「取到句尾」行为不变', () {
    test('日文点字位仍从该位置取到句尾（逐字查词语义）', () {
      const String s = '今日は';
      expect(subtitleLookupTerm(s, 0), '今日は');
      expect(subtitleLookupTerm(s, 1), '日は');
      expect(subtitleLookupTerm(s, 2), 'は');
    });

    test('中文同理逐字到句尾', () {
      const String s = '你好世界';
      expect(subtitleLookupTerm(s, 1), '好世界');
      expect(subtitleLookupTerm(s, 3), '界');
    });

    test('点空白/标点（非拉丁）维持 skip-to-end 历史语义', () {
      const String s = 'a, b';
      // index 1 = ',' (标点，非拉丁) → 取到句尾
      expect(subtitleLookupTerm(s, 1), ', b');
    });
  });

  group('subtitleLookupTerm — 边界', () {
    test('越界返回空串', () {
      expect(subtitleLookupTerm('hi', -1), '');
      expect(subtitleLookupTerm('hi', 2), '');
      expect(subtitleLookupTerm('', 0), '');
    });
  });
}
