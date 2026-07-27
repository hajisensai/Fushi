import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// G7：日文归一化码点原语（`hibiki_core` `jp_codepoint_fold.dart`）。
///
/// 三套 normalizer（媒体库搜索 / 视频刮削 TitleNormalizer / 有声书-阅读器
/// AudioTextNormalizer 及其 ReaderPaginationScripts Dart 影子）共用这批原语；
/// 各自策略层行为由各自既有测试锁定。本文件锁两件事：
/// ① 原语本身的码点变换逐字节冻结（参与搜索归一化与 sasayaki 匹配坐标系，
///    输出一变即改变既有匹配/高亮行为）；
/// ② 运行期 reader JS 持有的半角片假名查表副本（`hwKataToFw`，跨语言无法引用
///    Dart 常量）与共享 Dart 表逐项一致（跨语言 parity 锁）。
void main() {
  group('fullwidthAsciiToHalfwidth', () {
    test('U+FF01..U+FF5E 整段平移 -0xFEE0', () {
      expect(fullwidthAsciiToHalfwidth('！'.runes.single), '!'.codeUnitAt(0));
      expect(fullwidthAsciiToHalfwidth('Ａ'.runes.single), 'A'.codeUnitAt(0));
      expect(fullwidthAsciiToHalfwidth('ｚ'.runes.single), 'z'.codeUnitAt(0));
      expect(fullwidthAsciiToHalfwidth('０'.runes.single), '0'.codeUnitAt(0));
      expect(fullwidthAsciiToHalfwidth(0xFF5E), 0x7E); // ～ → ~（区间上界）
      expect(fullwidthAsciiToHalfwidth(0xFF01), 0x21); // ！ → !（区间下界）
    });

    test('范围外原样：全角空格 U+3000 / 半角片假名 / ASCII / 假名', () {
      expect(fullwidthAsciiToHalfwidth(0x3000), 0x3000);
      expect(fullwidthAsciiToHalfwidth(0xFF66), 0xFF66); // ｦ 不在本原语范围
      expect(fullwidthAsciiToHalfwidth(0x41), 0x41);
      expect(fullwidthAsciiToHalfwidth(0x30A2), 0x30A2);
    });
  });

  group('katakanaToHiragana', () {
    test('基本区 U+30A1..U+30F6 平移 -0x60', () {
      expect(katakanaToHiragana('ア'.runes.single), 'あ'.runes.single);
      expect(katakanaToHiragana('ァ'.runes.single), 'ぁ'.runes.single); // 下界
      expect(katakanaToHiragana('ヶ'.runes.single), 'ゖ'.runes.single); // 上界
    });

    test('范围外原样：长音符 ー / 平假名 / ヺ(30FA)', () {
      expect(katakanaToHiragana(0x30FC), 0x30FC); // ー 无平假名对应
      expect(katakanaToHiragana('あ'.runes.single), 'あ'.runes.single);
      expect(katakanaToHiragana(0x30FA), 0x30FA); // ヺ 超出基本区上界
    });
  });

  group('halfwidthKatakanaToFullwidth', () {
    test('U+FF66..U+FF9D 查表折叠', () {
      expect(halfwidthKatakanaToFullwidth('ｦ'.runes.single), 'ヲ'.runes.single);
      expect(halfwidthKatakanaToFullwidth('ｶ'.runes.single), 'カ'.runes.single);
      expect(halfwidthKatakanaToFullwidth('ｰ'.runes.single), 'ー'.runes.single);
      expect(halfwidthKatakanaToFullwidth('ﾝ'.runes.single), 'ン'.runes.single);
    });

    test('范围外原样：半角浊点 ﾞ(FF9E)/半浊点 ﾟ(FF9F) 刻意不折叠', () {
      expect(halfwidthKatakanaToFullwidth(0xFF9E), 0xFF9E);
      expect(halfwidthKatakanaToFullwidth(0xFF9F), 0xFF9F);
      expect(halfwidthKatakanaToFullwidth(0x30A2), 0x30A2);
    });

    test('查表恒 56 项（U+FF66..U+FF9D 全覆盖）', () {
      expect(kHalfwidthKatakanaToFullwidth.length, 0xFF9D - 0xFF66 + 1);
    });
  });

  group('reader JS hwKataToFw 副本 parity（跨语言锁）', () {
    test('JS 查表与共享 Dart 表逐项一致、基址 0xFF66', () {
      final String src = File(
        'lib/src/reader/reader_pagination_scripts.dart',
      ).readAsStringSync();
      expect(src.contains('hwKataToFwBase: 0xFF66'), isTrue,
          reason: 'JS 查表基址必须是 0xFF66（与 Dart 表索引约定一致）');
      final RegExpMatch? m =
          RegExp(r'hwKataToFw:\s*\[([0-9xA-Fa-f,\s]+)\]').firstMatch(src);
      expect(m, isNotNull, reason: '运行期 JS 必须持有 hwKataToFw 查表副本');
      final List<int> jsTable = m!
          .group(1)!
          .split(',')
          .map((String e) => e.trim())
          .where((String e) => e.isNotEmpty)
          .map((String e) => int.parse(e))
          .toList();
      expect(jsTable, kHalfwidthKatakanaToFullwidth,
          reason: 'JS 半角片假名查表必须与 kHalfwidthKatakanaToFullwidth 逐项一致');
    });
  });
}
