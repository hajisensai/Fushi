import 'package:flutter_test/flutter_test.dart';

import '../../pages/video_hibiki_page_source_corpus.dart';

/// 源码守卫：视频播放器 chrome 必须吃主题色——无法用纯单测覆盖（控制条由 media_kit
/// 在真实 libmpv player 上渲染），故在源码层钉死：
///
/// 1. 桌面/移动两套控制条主题的 `buttonBarButtonColor` 必须是强调色 `cs.primary`，
///    与已是 `cs.primary` 的进度条统一（不再用 `cs.onSurface` / `Colors.white`）。
/// 2. 弹出菜单/底部 sheet（音轨/字幕/倍速/剧集）不得硬编码 `Colors.black87` 背景，
///    必须跟随 M3 主题表面色（浅色主题下才不会是死黑）。
void main() {
  // TODO-590 batch11：两套 controls 主题已搬到 controls_theme.part.dart，读「合并语料」
  // （主壳 + 全部 part）才能数到两处 buttonBarButtonColor: cs.primary。
  final String page = readVideoHibikiSource();

  group('视频控制条按钮吃主题色', () {
    test('两套控制条主题都用 cs.primary 作为 buttonBarButtonColor', () {
      final int primaryCount =
          'buttonBarButtonColor: cs.primary'.allMatches(page).length;
      expect(primaryCount, 2, reason: '桌面与移动两套控制条主题都必须用 cs.primary（强调色）');
    });

    test('控制条按钮不再用 onSurface / 硬编码白色', () {
      expect(page.contains('buttonBarButtonColor: cs.onSurface'), isFalse,
          reason: 'onSurface 在浅色主题下叠在深色 scrim 上对比差，应换强调色');
      expect(page.contains('buttonBarButtonColor: Colors.white'), isFalse,
          reason: '移动端硬编码白色不吃主题，应换强调色');
    });
  });

  group('视频弹出 sheet 吃主题表面色', () {
    test('sheet 不再硬编码 Colors.black87 背景', () {
      expect(page.contains('backgroundColor: Colors.black87'), isFalse,
          reason: '音轨/字幕/倍速/剧集 sheet 必须跟随主题表面色，不能死黑');
    });
  });
}
