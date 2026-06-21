import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../pages/video_hibiki_page_source_corpus.dart';

/// BUG-190 source guard（TODO-080/092）：字幕在 Hibiki 一律走可点
/// [VideoSubtitleOverlay]（cue 同步 + 逐字查词），libmpv / media_kit 不该自己渲染
/// 任何字幕。本守卫锁定三处调用点不变量——它们都无法在无头 libmpv 下驱动真实
/// player，故用源码扫描守住「禁用内置渲染」的不变量（纯函数 map 本身由
/// video_mpv_config_test.dart 覆盖）：
///
/// 1. [VideoHibikiPage] 的窗口侧与全屏路由侧两个 `Video(...)` 都把
///    `subtitleViewConfiguration` 设成 `SubtitleViewConfiguration(visible: false)`，
///    彻底关掉 media_kit 内置 `SubtitleView`（否则不可点字幕叠在 overlay 上 →
///    点字幕穿透 / 随机透明 / 横竖屏残留黑底）。
/// 2. [VideoPlayerController.load] 在 `setSubtitleTrack(no())` 之后注入
///    `buildSubtitleSuppressionProperties()`（sub-auto=no + sub-visibility=no），
///    根除「字幕轨异步就绪后被 mpv 自动重选」竞态。
/// 3. 图形 PGS 轨例外（[VideoPlayerController.selectEmbeddedGraphicTrack]）才重开
///    可见性（buildGraphicSubtitleVisibilityProperties），保住 BUG-122。
void main() {
  String region(String src, String startSig, String endSig) {
    final int start = src.indexOf(startSig);
    expect(start, greaterThanOrEqualTo(0), reason: 'missing $startSig');
    final int end = src.indexOf(endSig, start + startSig.length);
    expect(end, greaterThan(start), reason: 'missing $endSig after $startSig');
    return src.substring(start, end);
  }

  final RegExp disabledSubtitleViewConfig = RegExp(
    r'subtitleViewConfiguration:\s*const\s+'
    r'SubtitleViewConfiguration\s*\(\s*visible:\s*false\s*,?\s*\)',
  );
  final RegExp noTrackThenSuppression = RegExp(
    r'setSubtitleTrack\s*\(\s*SubtitleTrack\.no\(\)\s*\)[\s\S]*?'
    r'applySubtitleMpvPropertiesToPlayer\s*\(\s*player\s*,\s*'
    r'buildSubtitleSuppressionProperties\(\)\s*,?\s*\)',
  );
  final RegExp graphicVisibilityOverride = RegExp(
    r'applySubtitleMpvPropertiesToPlayer\s*\(\s*player\s*,\s*'
    r'buildGraphicSubtitleVisibilityProperties\(\)\s*,?\s*\)',
  );

  group('video_hibiki_page disables media_kit built-in SubtitleView', () {
    // TODO-590 batch15：全屏路由侧 Video（含 visible:false）随 fullscreen 域搬到
    // fullscreen.part.dart，故改读合并语料；窗口侧 Video 仍在主壳（语料最前段）。
    final String src = readVideoHibikiSource();

    test('both Video widgets set subtitleViewConfiguration visible:false', () {
      // 两处 Video（窗口侧 + 全屏路由侧）都必须显式禁用内置 SubtitleView。
      final int count = disabledSubtitleViewConfig.allMatches(src).length;
      expect(count, greaterThanOrEqualTo(2),
          reason: '窗口侧与全屏路由侧两个 Video 都要显式 visible:false，'
              '否则内置 SubtitleView 会把字幕渲染成不可点块叠在 overlay 上 '
              '(BUG-190)。当前匹配数=$count');
    });
  });

  group('video_player_controller suppresses libmpv subtitle rendering', () {
    final String src = File('lib/src/media/video/video_player_controller.dart')
        .readAsStringSync();

    test('load() injects buildSubtitleSuppressionProperties after no()', () {
      final String body = region(
        src,
        'Future<void> load(',
        'Future<void> _loadEmbeddedSubtitleIfNeeded(',
      );
      expect(body.contains('setSubtitleTrack(SubtitleTrack.no())'), isTrue,
          reason: 'load 仍需先把选中轨清成 no()');
      expect(noTrackThenSuppression.hasMatch(body), isTrue,
          reason: 'load 必须注入 sub-auto=no + sub-visibility=no，'
              '根除字幕轨异步就绪后被 mpv 自动重选的竞态 (BUG-190)');
    });

    test('graphic PGS track reopens visibility (BUG-122 exception)', () {
      final String body = region(
        src,
        'Future<bool> selectEmbeddedGraphicTrack(',
        'Future<void> _waitUntilSubtitleTracksReady(',
      );
      expect(graphicVisibilityOverride.hasMatch(body), isTrue,
          reason: '图形 PGS 轨是字幕抑制的唯一例外：选轨后必须重开 sub-visibility，'
              '否则用户选了图形字幕却看不到 (回归 BUG-122)');
    });
  });
}
