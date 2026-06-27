import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/video_hibiki_page.dart';

/// TODO-916 症状③：点英文字幕必须点首字母才能查词。
///
/// 根因：旧逻辑 `sentence.characters.skip(graphemeIndex).join()` 从被点字位一直取到
/// **句尾**——日语逐字查没问题，但拉丁词点中间字母（"hello" 点 'e'）得到 "ello" 查不到。
///
/// 修复：被点字位是拉丁单词字符时回退到词首并延伸到词尾，查整词（任意位置点击都选中
/// 完整单词）；CJK 维持逐字「取到句尾」语义不变。
///
/// 守卫是 load-bearing：把 [subtitleLookupTerm] 改回旧 `skip(graphemeIndex)`，
/// 「拉丁词点任意位置都返回整词」与「CJK 逐字行为」用例都会红。
void main() {
  group('subtitleLookupTerm — 拉丁词点任意位置都选中完整单词', () {
    const String hello = 'hello';
    test('点 "hello" 任意 index（含首/中/尾）都返回 "hello"', () {
      for (int i = 0; i < hello.characters.length; i++) {
        expect(subtitleLookupTerm(hello, i), 'hello',
            reason: 'tap at index $i should select whole word');
      }
    });

    test('句中单词点中间字母选中整词，不串到下一个词', () {
      const String s = 'say hello world';
      // 'say'=0..2, ' '=3, 'hello'=4..8, ' '=9, 'world'=10..14
      expect(subtitleLookupTerm(s, 5), 'hello'); // 'e' in hello
      expect(subtitleLookupTerm(s, 8), 'hello'); // 'o' in hello
      expect(subtitleLookupTerm(s, 0), 'say');
      expect(subtitleLookupTerm(s, 12), 'world'); // 'r' in world
    });

    test('重音字母（café）按拉丁词整体选中', () {
      const String s = 'un café noir';
      // 'café' 占 index 3..6（é 是单个字位簇）
      expect(subtitleLookupTerm(s, 5), 'café'); // 'f'
      expect(subtitleLookupTerm(s, 6), 'café'); // 'é'
    });

    test('连字号是词边界（well-known 各取一段）', () {
      const String s = 'well-known';
      expect(subtitleLookupTerm(s, 1), 'well'); // 'e'
      expect(subtitleLookupTerm(s, 6), 'known'); // 'n' after hyphen
    });

    test('数字与字母同词（mp3 整体）', () {
      const String s = 'play mp3 file';
      expect(subtitleLookupTerm(s, 5), 'mp3'); // 'm'
      expect(subtitleLookupTerm(s, 7), 'mp3'); // '3'
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
