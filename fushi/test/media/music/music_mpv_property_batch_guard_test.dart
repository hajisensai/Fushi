// 源码守卫（BUG-4911 的音乐侧，#3722 c46 遗留）：mpv 属性批量下发只有一份实现
// [setMpvPropertiesInOrder]（逐条保序、被拒留痕）。音乐输出后端的初始属性与 MV / 卡拉
// OK 页的字幕 / CDG 属性原先各自 `for (...) await native.setProperty(...)`：mpv 拒绝写入
// （属性名拼错 / 值非法）无声无息，写入抛出时还会把整次打开打断。
import 'dart:io';

import 'package:test/test.dart';

void main() {
  for (final String path in <String>[
    'lib/src/media/music/mpv_music_output_backend.dart',
    'lib/src/pages/implementations/music/music_mv_page.dart',
  ]) {
    test('$path 批量属性走 setMpvPropertiesInOrder', () {
      final String src = File(path).readAsStringSync();
      expect(src, contains('setMpvPropertiesInOrder(_player,'));
      expect(
        RegExp(
          r'for \(final MapEntry<String, String> e[^)]*\)\s*\{\s*'
          r'await native\.setProperty\(e\.key, e\.value\);',
        ).hasMatch(src),
        isFalse,
        reason: '同形逐条循环又回来了',
      );
    });
  }
}
