import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1005 场景A 守卫：浏览器扩展 `content.js` 注入词典查词结果时，必须在每处
/// `window.audioSources = ...` 之后同时注入 `window.needsAudio = true;`——否则
/// `popup.js` 的「制卡时重新解析单词音频」分支（门 `window.audioSources?.length &&
/// window.needsAudio`）恒为 false，扩展/沉浸制卡的 payload `audio` 字段恒空（缺单词音频）。
/// App 内 popup 由 `popup_settings_injection.dart` 两者都注入；此守卫防扩展镜像回退。
///
/// content.js 有两份**逐字节镜像**（app 内置分发 + 扩展源），都要守。文件含少量 NUL 字节，
/// 按字节读、宽容解码。
void main() {
  const List<String> mirrors = <String>[
    'assets/browser_extension/content.js',
    '../tools/browser-extension/content.js',
  ];

  const String audioInject =
      'window.audioSources = Array.isArray(resp.data.audioSources)';
  const String needsInject = 'window.needsAudio = true;';

  for (final String rel in mirrors) {
    test('content.js 每处 audioSources 注入都伴随 needsAudio：$rel', () {
      final File f = File(rel);
      expect(f.existsSync(), true, reason: '找不到 content.js 镜像：$rel');
      final String src = utf8.decode(f.readAsBytesSync(), allowMalformed: true);

      final int audioCount = audioInject.allMatches(src).length;
      final int needsCount = needsInject.allMatches(src).length;
      expect(audioCount, greaterThan(0),
          reason: 'content.js 应注入 window.audioSources');
      expect(needsCount, greaterThanOrEqualTo(audioCount),
          reason: '每处 audioSources 注入都必须伴随 window.needsAudio=true '
              '（否则扩展制卡永远拿不到重新解析的单词音频，BUG-1005）');
    });
  }
}
