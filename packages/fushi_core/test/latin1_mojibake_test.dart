import 'dart:convert';

import 'package:test/test.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-4243 遗留乱码的剥层：一层 = 把 UTF-8 字节当 Latin-1 解码一次。
String _garble(final String s) => latin1.decode(utf8.encode(s));

void main() {
  group('unwrapLatin1Mojibake', () {
    test('剥掉任意层数的乱码，回到原书名', () {
      const String title = 'ダンジョン飯 第1巻';
      String garbled = title;
      for (int level = 1; level <= 6; level++) {
        garbled = _garble(garbled);
        expect(hasLatin1Mojibake(garbled), isTrue, reason: 'level $level');
        expect(unwrapLatin1Mojibake(garbled), title, reason: 'level $level');
      }
    });

    test('拉丁字母书名的乱码（Café → CafÃ©）也能剥回', () {
      expect(unwrapLatin1Mojibake(_garble('Café')), 'Café');
      expect(unwrapLatin1Mojibake(_garble(_garble('Café'))), 'Café');
    });

    test('正常文本原样返回', () {
      for (final String s in <String>[
        '',
        'Plain ASCII title',
        'Café au lait',
        '日本語のタイトル',
        'Ünïcödé — mixed 日本',
        '😀 emoji',
      ]) {
        expect(hasLatin1Mojibake(s), isFalse, reason: s);
        expect(unwrapLatin1Mojibake(s), s, reason: s);
      }
    });

    test('含 >0xFF 字符的字符串不会被当成乱码', () {
      final String mixed = '${_garble('本')}本';
      expect(hasLatin1Mojibake(mixed), isFalse);
      expect(unwrapLatin1Mojibake(mixed), mixed);
    });
  });
}
