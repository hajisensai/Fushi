import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/scan_scale.dart';
import '../helpers/source_guard.dart';

/// 守卫（2026-10-05 动效 / 排版统一为 M3E）：lib/ 下**不得新增**硬编码的动画
/// 曲线（`Curves.xxx`）与裸数字字号（`fontSize: 14`）。
///
/// - 动效一律走 `fushi_motion_tokens.dart`：`context.fushiMotion` 的六个弹簧
///   token（spatial/effects × fast/default/slow）、`FushiSprings`、
///   `FushiSpringCurve`、兼容常量 `FushiMotion.*`。
/// - 字号一律走主题字阶：`context.fushiType.<角色>` / `.<角色>Emphasized`
///   （`fushi_typography.dart`）或 `Theme.of(context).textTheme`。阅读器正文、
///   漫画 OCR、歌词、字幕等用户可配字体的内容区若必须写死字号，放进白名单并
///   说明原因。
///
/// 这是**棘轮**：下面两张表是 2026-10-05 的存量（每个文件的出现次数），只许
/// 减少不许增加；新文件一律不许出现。迁移掉存量后把对应计数调低或删行。
void main() {
  Map<String, int> scan(RegExp pattern) {
    final Map<String, int> counts = <String, int>{};
    int scanned = 0;
    for (final FileSystemEntity e in Directory(
      'lib',
    ).listSync(recursive: true)) {
      if (e is! File) continue;
      final String path = e.path.replaceAll(r'\', '/');
      if (!path.endsWith('.dart') || path.endsWith('.g.dart')) continue;
      scanned++;
      final String code = maskCommentsAndStrings(e.readAsStringSync());
      final int n = identical(pattern, _curvePattern)
          ? _curveCount(path, code)
          : pattern.allMatches(code).length;
      if (n > 0) counts[path] = n;
    }
    expectScanScale(
      scanned,
      what: 'motion/type lib Dart sources',
      atLeast: 1200,
      measured: 1547,
    );
    return counts;
  }

  List<String> overBudget(Map<String, int> actual, Map<String, int> budget) {
    return <String>[
      for (final MapEntry<String, int> e in actual.entries)
        if (e.value > (budget[e.key] ?? 0))
          '${e.key}: ${e.value} > ${budget[e.key] ?? 0}',
    ];
  }

  test(
    'token scanner detects code and excludes comments, strings and lookalikes',
    () {
      final String code = maskCommentsAndStrings(r'''
      curve: Curves.easeOut,
      curve: Curves.linear,
      final MyCurves.easeOut = 0;
      final String example = 'Curves.easeIn fontSize: 18';
      // curve: Curves.bounceOut, fontSize: 24
      style: TextStyle(fontSize: 14),
    ''');
      expect(_curvePattern.allMatches(code), hasLength(2));
      expect(_fontSizePattern.allMatches(code), hasLength(1));
    },
  );

  test(
    'geometry exemption is limited to one exact expression in its owner',
    () {
      const String path = 'lib/src/reader/reader_panel_kit.dart';
      const String envelope =
          'Curves.easeInOut.transform(math.min(head, tail))';
      expect(_curveCount(path, envelope), 0);
      expect(_curveCount(path, '$envelope; $envelope'), 1);
      expect(_curveCount(path, '$envelope; Curves.easeOut.transform(t)'), 1);
      expect(_curveCount('lib/new_widget.dart', envelope), 1);
    },
  );

  test('lib/ 不新增硬编码 Curves.*（用 FushiMotion / 弹簧 token）', () {
    final List<String> offenders = overBudget(
      scan(_curvePattern),
      _curveBudget,
    );
    expect(
      offenders,
      isEmpty,
      reason:
          '动画曲线改用 context.fushiMotion.<token>.curve / FushiSpringCurve / '
          'FushiMotion.*：\n${offenders.join('\n')}',
    );
  });

  test('lib/ 不新增裸数字 fontSize（用 context.fushiType / textTheme）', () {
    final List<String> offenders = overBudget(
      scan(_fontSizePattern),
      <String, int>{..._fontSizeBudget, ..._fontSpecimenBudget},
    );
    expect(
      offenders,
      isEmpty,
      reason:
          '字号改用 context.fushiType.<角色>（含 Emphasized）或 textTheme：\n'
          '${offenders.join('\n')}',
    );
  });
}

final RegExp _curvePattern = RegExp(r'\bCurves\.\w+');
final RegExp _fontSizePattern = RegExp(r'fontSize:\s*[0-9]');

/// 这两处把下载进度映射成静态波幅，并非按时间驱动动画。保留几何轮廓；
/// 豁免仅限指定文件里此完整表达式的一次调用，不放宽该文件其它曲线预算。
const Set<String> _waveEnvelopeOwners = <String>{
  'lib/src/reader/reader_panel_kit.dart',
  'lib/src/utils/components/fushi_expressive_progress.dart',
};
final RegExp _waveEnvelope = RegExp(
  r'\bCurves\.easeInOut\.transform\(\s*math\.min\(head,\s*tail\)\s*\)',
);

int _curveCount(String path, String code) {
  final int total = _curvePattern.allMatches(code).length;
  return total -
      (_waveEnvelopeOwners.contains(path) && _waveEnvelope.hasMatch(code)
          ? 1
          : 0);
}

/// 字体库的五处都是用户字体的样张/字形/字重比较内容，不是 UI 字阶。
/// 保持对照样张的固定字号，周围标题、按钮与说明仍须走主题字阶。
const Map<String, int> _fontSpecimenBudget = <String, int>{
  'lib/src/pages/implementations/font_preview/font_library_widgets.dart': 5,
};

/// 2026-10-05 存量：`Curves.` 每文件出现次数（只许减少）。
const Map<String, int> _curveBudget = <String, int>{
  'lib/src/focus/fushi_focus_scroll.dart': 3,
  'lib/src/media/audiobook/lyrics_player/lyrics_player_apple.dart': 2,
  'lib/src/media/video/video_apple_chrome.dart': 1,
  'lib/src/media/video/video_subtitle_overlay.dart': 1,
  'lib/src/pages/implementations/reader_fushi_page.dart': 1,
  'lib/src/pages/implementations/updates_dashboard_banner.dart': 1,
  'lib/src/pages/implementations/video_fushi/subtitle.part.dart': 1,
  'lib/src/reader/reader_desktop_chrome.dart': 1,
  'lib/src/settings/settings_search.dart': 1,
  'lib/src/startup/startup_splash_mark.dart': 1,
  'lib/src/utils/adaptive/adaptive_widgets.dart': 3,
  'lib/src/utils/components/fading_chrome_gate.dart': 1,
  'lib/src/utils/components/fushi_expressive_progress.dart': 2,
  'lib/src/utils/components/fushi_marquee.dart': 4,
  'lib/src/utils/components/fushi_material_components.dart': 1,
  'lib/src/utils/components/glass/fushi_glass_feedback.dart': 3,
  'lib/src/utils/components/glass/fushi_glass_inputs.dart': 1,
  'lib/src/utils/components/glass/fushi_glass_lists.dart': 2,
  'lib/src/utils/components/glass/fushi_glass_overlays.dart': 8,
  'lib/src/utils/components/glass/fushi_glass_toggles.dart': 4,
  'lib/src/utils/components/settings_shared.dart': 3,
  'lib/src/utils/misc/smooth_wheel_scroll.dart': 1,
};

/// 2026-10-05 存量：裸数字 `fontSize:` 每文件出现次数（只许减少）。
const Map<String, int> _fontSizeBudget = <String, int>{
  'lib/src/media/audiobook/lyrics_player/lyrics_player_apple.dart': 5,
  'lib/src/media/video/video_long_press_speed_badge.dart': 1,
  'lib/src/media/video/video_m3e_chrome.dart': 3,
  'lib/src/media/video/video_subtitle_overlay.dart': 2,
  'lib/src/media/video/video_subtitle_style.dart': 1,
  'lib/src/media/video/video_volume_overlays.dart': 2,
  'lib/src/models/theme_notifier.dart': 12,
  'lib/src/pages/implementations/anime_download_dialog.dart': 1,
  'lib/src/pages/implementations/game_stream_page.dart': 1,
  'lib/src/pages/implementations/reader_fushi/chrome.part.dart': 5,
  'lib/src/pages/implementations/shortcut_settings/action_tile.part.dart': 1,
  'lib/src/pages/implementations/video_fushi/controls_popover.part.dart': 1,
  'lib/src/pages/implementations/video_fushi/controls_theme.part.dart': 2,
  'lib/src/pages/implementations/video_fushi/episode.part.dart': 3,
  'lib/src/pages/implementations/video_fushi/subtitle.part.dart': 1,
  'lib/src/pages/implementations/video_fushi_page.dart': 7,
  'lib/src/reader/illustration_zoom_viewer.dart': 2,
  'lib/src/settings/glass_settings_renderer.dart': 3,
  'lib/src/settings/settings_home_page.dart': 1,
  'lib/src/utils/adaptive/adaptive_navigation.dart': 2,
  'lib/src/utils/components/fushi_bottom_action_bar.dart': 1,
  'lib/src/utils/components/fushi_design_tokens.dart': 1,
  'lib/src/utils/components/fushi_material_components.dart': 5,
  'lib/src/utils/components/fushi_placeholder_message.dart': 1,
  'lib/src/utils/components/fushi_tag.dart': 1,
  'lib/src/utils/components/glass/fushi_glass_bars.dart': 1,
  'lib/src/utils/components/glass/fushi_glass_feedback.dart': 1,
  'lib/src/utils/components/glass/fushi_glass_overlays.dart': 1,
  'lib/src/utils/components/glass/fushi_glass_toggles.dart': 1,
  'lib/src/utils/misc/fushi_toast.dart': 1,
};
