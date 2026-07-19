import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-900 守卫：副字幕（视频双字幕副层）必须与主字幕轨行**共用同一份可用字幕列表**
/// [_subtitleMenuSources]（内嵌轨 + 同目录外挂文件），而不是只取内嵌轨。
///
/// 回归历史：`_buildSecondarySubtitleRows` 曾把 `_subtitleMenuSources` 过滤成
/// `.where((s) => s.isEmbedded)`，外挂 sidecar 字幕文件（用户下载的 .srt/.ass，最常见
/// 的「添加字幕」方式）被整批排除 → 用户报「副字幕没办法添加」。选择链路
/// `_selectSecondarySubtitleSource` → `loadCuesForSource` → `toPersistedValue` 本就
/// 支持外挂，只有列表构建与恢复把外挂挡在门外。
///
/// 私有 State 方法（`_build*` / `_restore*`）无法直接 widget 测试（需整页真
/// [VideoPlayerController]），故按 CLAUDE.md「源码扫描守卫」层锁死两条不变量：
///  1. 副字幕行遍历完整 `_subtitleMenuSources`，不得再引入 `isEmbedded` 过滤。
///  2. 副字幕恢复对称支持外挂绝对路径（`SubtitleSource.external` + 文件存在判据），
///     否则重开视频副字幕丢失。
void main() {
  final File source = File(
    'lib/src/pages/implementations/video_hibiki/subtitle.part.dart',
  );

  /// 抽取以 [signature] 起头的方法体（到下一个方法的文档注释 `\n  /// ` 之前）。
  /// 用**定义签名**（含返回类型）而非裸方法名做锚点：裸名会先命中调用点（如
  /// `children: _buildSecondarySubtitleRows(...)` 出现在定义之前），框错段。
  String methodBody(String src, String signature) {
    final int start = src.indexOf(signature);
    expect(start, greaterThanOrEqualTo(0), reason: '找不到方法定义 $signature');
    final int next = src.indexOf('\n  /// ', start + signature.length);
    return src.substring(start, next < 0 ? src.length : next);
  }

  test('副字幕行遍历完整 _subtitleMenuSources（不得过滤成 isEmbedded）', () {
    final String src = source.readAsStringSync();
    final String body =
        methodBody(src, 'List<Widget> _buildSecondarySubtitleRows(');

    expect(
      body.contains(
          'for (final SubtitleSource source in _subtitleMenuSources)'),
      isTrue,
      reason: '副字幕行必须遍历完整 _subtitleMenuSources（与主字幕同一份可用列表）',
    );
    expect(
      body.contains('.where((SubtitleSource s) => s.isEmbedded)'),
      isFalse,
      reason: 'BUG-900 回归：副字幕行不得把可用列表过滤成只剩内嵌轨（外挂字幕会消失）',
    );
  });

  test('副字幕恢复对称支持外挂绝对路径（SubtitleSource.external + 文件存在）', () {
    final String src = source.readAsStringSync();
    final String body =
        methodBody(src, 'Future<void> _restoreSecondarySubtitle(');

    expect(
      body.contains('SubtitleSource.external('),
      isTrue,
      reason: '副字幕恢复必须支持外挂源（否则重开视频外挂副字幕丢失）',
    );
    expect(
      body.contains('File(persisted).existsSync()'),
      isTrue,
      reason: '外挂恢复须校验文件仍在（与主字幕 _restorePersistedSubtitle 同判据）',
    );
    expect(
      body.contains('SubtitleSource.embeddedPrefix'),
      isTrue,
      reason: '内嵌轨恢复路径仍须保留',
    );
  });
}
