import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码扫描守卫（BUG-345）：视频片段导出 / 桌面音频裁剪两条 ffmpeg 路径里，任何
/// `-map 0:a:<expr>` 的字符串插值都必须带尾随 `?`，让越界音轨映射降级回退默认轨，
/// 而不是 `Stream map matches no streams` 硬失败。
///
/// 越界根因：`currentAudioStreamIndex` 用 libmpv `tracks.audio` 的轨序号，挂外挂音频
/// 或枚举顺序与 ffmpeg `0:a:N` 不一致时会越界。`?` 是浏览器无关的健壮降级。
void main() {
  // 仓库根（test 工作目录是 hibiki/）。
  String src(String rel) => File(rel).readAsStringSync();

  // 匹配 `0:a:` 后跟一个 `$...`（裸标识符或 `${...}`）插值，再看其后**第一个非空白**
  // 字符是否是 `?`。这样既覆盖 `'0:a:$idx'` 也覆盖 `'0:a:${idx}'`。
  final RegExp audioMap = RegExp(r'0:a:\$(?:\{[^}]*\}|[A-Za-z_][A-Za-z0-9_]*)');

  void assertEveryAudioMapIsTolerant(String path) {
    final String text = src(path);
    final List<RegExpMatch> matches = audioMap.allMatches(text).toList();
    expect(matches, isNotEmpty,
        reason: '$path 应至少有一处 `-map 0:a:\$idx` 拼接；若已重构请更新此守卫');
    for (final RegExpMatch m in matches) {
      final int end = m.end;
      // `${...}` 形式插值后紧跟的应是 `?`；裸标识符形式同理（标识符已被吃完）。
      // 取插值结束位置后的下一个字符。
      final String after = end < text.length ? text[end] : '';
      expect(after, '?',
          reason: '$path 第 ${m.start} 处 `${m.group(0)}` 缺少尾随 `?`：'
              '越界音轨映射会让 ffmpeg 硬失败，必须写成 `0:a:\$idx?`（BUG-345）');
    }
  }

  test('video_clip_exporter 的音轨 -map 全部带 ? 容错', () {
    assertEveryAudioMapIsTolerant(
        'lib/src/media/video/video_clip_exporter.dart');
  });

  test('desktop_audio_clipper 的音轨 -map 全部带 ? 容错', () {
    assertEveryAudioMapIsTolerant(
        'lib/src/utils/misc/desktop_audio_clipper.dart');
  });
}
