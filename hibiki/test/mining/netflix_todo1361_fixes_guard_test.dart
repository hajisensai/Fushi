import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1361 guards: three Netflix browser-extension fixes, asserted in BOTH
/// extension mirrors (bundled assets/ + real source tools/). Byte-identity of
/// these files is enforced separately by
/// browser_extension_dict_media_mirror_guard_test.dart; here we lock the
/// behaviour presence so a regression that silently drops any fix turns red.
///
/// flutter test cwd is the hibiki package root.
void main() {
  const Map<String, String> mirrors = <String, String>{
    'assets': 'assets/browser_extension',
    'tools': '../tools/browser-extension',
  };

  mirrors.forEach((String name, String root) {
    // ① BUG-674：隐藏网飞剧末「下一集」按钮（options 开关门控，缺省隐藏）。
    test('[$name] hides Netflix next-episode button gated by a setting', () {
      final String content = File('$root/content.js').readAsStringSync();
      expect(content.contains('fushi-nf-hide-next'), isTrue,
          reason: '$root content.js missing next-episode hide style id');
      expect(
          content.contains('[data-uia="next-episode-seamless-button"]'), isTrue,
          reason:
              '$root content.js missing the seamless next-episode selector');
      expect(content.contains('netflixHideNextEpisode'), isTrue,
          reason:
              '$root content.js must gate the hide on netflixHideNextEpisode');
      expect(content.contains('display:none!important'), isTrue,
          reason: '$root content.js next-episode hide must use display:none');
      // 缺省=隐藏（仅显式 false 才显示），content 与 options 判据一致。
      expect(content.contains('netflixHideNextEpisode === false'), isTrue,
          reason:
              '$root content.js default must be hide (only === false shows)');

      final String html = File('$root/options.html').readAsStringSync();
      final String js = File('$root/options.js').readAsStringSync();
      expect(html.contains('id="nfHideNext"'), isTrue,
          reason: '$root options.html missing the next-episode hide toggle');
      expect(js.contains('netflixHideNextEpisode'), isTrue,
          reason: '$root options.js must persist netflixHideNextEpisode');
    });

    // ② BUG-675：批量结束不再一律报「全部完成」，残留（录制失败）项 >0 时明确告知可重试。
    test('[$name] surfaces un-generated Netflix cards at batch completion', () {
      final String content = File('$root/content.js').readAsStringSync();
      expect(content.contains('张录制失败未生成，可再点生成重试'), isTrue,
          reason: '$root content.js must surface the leftover/failed count');
      expect(
          content.contains(
              "it && it.site === 'netflix' && st.episodes.indexOf(it.netflixId) >= 0"),
          isTrue,
          reason:
              '$root content.js must count remaining netflix items for the run');
    });

    // ③ BUG-676：网飞制卡带剧名 documentTitle（Anki 视频名字段），不再回落字面「Netflix」。
    test('[$name] Netflix mining carries the show title (documentTitle)', () {
      final String adapters =
          File('$root/subtitle-adapters.js').readAsStringSync();
      expect(adapters.contains('function netflixDocumentTitle'), isTrue,
          reason: '$root subtitle-adapters.js missing netflixDocumentTitle');
      expect(adapters.contains('[data-uia="video-title"]'), isTrue,
          reason:
              '$root subtitle-adapters.js must read the Netflix title bar element');

      final String content = File('$root/content.js').readAsStringSync();
      // 入队即抓剧名并随卡持久化。
      expect(content.contains('documentTitle: documentTitle'), isTrue,
          reason:
              '$root content.js must persist documentTitle on the queue item');
      // 生成时把剧名发进 mineClip（旧项回落到录制时现抓）。
      expect(
          content.contains(
              'q.documentTitle || (typeof netflixDocumentTitle === \'function\' ? netflixDocumentTitle() : \'\')'),
          isTrue,
          reason:
              '$root content.js mineClip must send documentTitle (with live fallback)');

      final String background = File('$root/background.js').readAsStringSync();
      expect(background.contains('msg.documentTitle'), isTrue,
          reason: '$root background.js mineClip must forward documentTitle');
    });
  });
}
