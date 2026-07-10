import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1391 / BUG-702 guard: Netflix 剧集开头左上角短暂显示的年龄分级/成熟度评级
/// overlay 会被制卡录制录进卡片截图/gif。修法复用 TODO-1361 ① 的常驻 CSS 隐藏机制
/// （style id `hibiki-nf-hide-next`，由 `netflixHideNextEpisode` 开关门控、缺省隐藏），
/// 只往选择器列表加年龄分级 overlay 的 selector——不另造一套。此守卫在两个扩展镜像
/// （bundled assets/ + real source tools/）都断言 selector 在隐藏清单里；两镜像的
/// 逐字节一致由 browser_extension_dict_media_mirror_guard_test.dart 另行强制。
///
/// flutter test cwd is the hibiki package root.
void main() {
  const Map<String, String> mirrors = <String, String>{
    'assets': 'assets/browser_extension',
    'tools': '../tools/browser-extension',
  };

  mirrors.forEach((String name, String root) {
    test('[$name] hides Netflix start-of-episode maturity-rating overlay', () {
      final String content = File('$root/content.js').readAsStringSync();

      // 复用既有隐藏机制，而非新增一套（同一 style id + 同一开关门控）。
      expect(content.contains('hibiki-nf-hide-next'), isTrue,
          reason:
              '$root content.js must reuse the hibiki-nf-hide-next style id');
      expect(content.contains('netflixHideNextEpisode'), isTrue,
          reason:
              '$root content.js maturity hide must share the netflixHideNextEpisode gate');

      // 年龄分级 overlay 选择器进入隐藏清单：播放器作用域的容器前缀 + data-uia 兜底。
      expect(
          content.contains('[class*="watch-video--maturity-rating"]'), isTrue,
          reason:
              '$root content.js must target the player maturity-rating container');
      expect(content.contains('.watch-video [data-uia*="maturity"]'), isTrue,
          reason:
              '$root content.js must target the maturity data-uia player hook');
      expect(
          content.contains('.watch-video [class*="maturity-rating"]'), isTrue,
          reason:
              '$root content.js must target nested player maturity-rating nodes');
    });
  });
}
