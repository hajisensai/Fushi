import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import '../helpers/scan_scale.dart';

/// M3E 收口守卫（2026-10-05「所有组件都是 m3e」）：提示条 / tooltip / 徽标 /
/// 下拉刷新一律走 Fushi 的统一实现，禁止新增裸 Material 用法。
///
/// - 提示条：`FushiSnackBar`（或 `FushiToast`），不写裸 `SnackBar(`；
/// - tooltip：`FushiTooltip` / `FushiRichTooltip`，不写裸 `Tooltip(`；
/// - 徽标：`FushiBadgeControl`，不写裸 `Badge(` / `Badge.count(`；
/// - 下拉刷新：`FushiRefreshIndicator`，不写裸 `RefreshIndicator(`。
///
/// 存量按「文件 → 次数」白名单渐进收紧：只许减少，不许新增文件或调高次数。
/// 迁走一处就把白名单里对应计数减一（降到 0 删掉该行）。注释与字符串不计。
/// flutter test cwd 是 fushi 包根。
void main() {
  const Map<String, String> patterns = <String, String>{
    'SnackBar': r'(?<![A-Za-z0-9_])SnackBar\(',
    'Tooltip': r'(?<![A-Za-z0-9_])Tooltip\(',
    'Badge': r'(?<![A-Za-z0-9_])Badge(\.count)?\(',
    'RefreshIndicator': r'(?<![A-Za-z0-9_])RefreshIndicator\(',
  };

  const Map<String, Map<String, int>> allowlist = <String, Map<String, int>>{
    'SnackBar': <String, int>{},
    'Tooltip': <String, int>{
      'lib/src/media/audiobook/lyrics_player/lyrics_player_md3.dart': 2,
      'lib/src/media/audiobook/lyrics_player/lyrics_speed_panel.dart': 1,
      'lib/src/media/audiobook/reader_quick_settings_sheet.dart': 1,
      'lib/src/media/video/video_m3e_chrome.dart': 1,
      'lib/src/pages/implementations/discovery/discovery_hero_carousel.dart': 1,
      'lib/src/pages/implementations/media_server/media_server_widgets.dart': 2,
      'lib/src/utils/components/fushi_m3e_feedback.dart': 1,
      'lib/src/utils/components/fushi_material_components.dart': 2,
      'lib/src/utils/components/glass/fushi_expressive.dart': 1,
      'lib/src/utils/components/glass/fushi_glass_buttons.dart': 1,
      'lib/src/utils/components/glass/fushi_glass_feedback.dart': 2,
      'lib/src/utils/components/glass/fushi_glass_overlays.dart': 2,
      'lib/src/utils/components/glass/fushi_glass_toggles.dart': 2,
      'lib/src/utils/components/library_section_tabs.dart': 1,
    },
    'Badge': <String, int>{
      'lib/src/utils/components/glass/fushi_glass_lists.dart': 2,
    },
    'RefreshIndicator': <String, int>{
      'lib/src/pages/implementations/home_video_page.dart': 1,
      'lib/src/pages/implementations/reader_fushi_history_page.dart': 1,
      'lib/src/utils/components/fushi_m3e_feedback.dart': 1,
    },
  };

  final Map<String, Map<String, int>> found = <String, Map<String, int>>{
    for (final String k in patterns.keys) k: <String, int>{},
  };
  int scanned = 0;
  for (final FileSystemEntity e in Directory('lib').listSync(recursive: true)) {
    if (e is! File) continue;
    final String path = e.path.replaceAll(r'\', '/');
    if (!path.endsWith('.dart') || path.endsWith('.g.dart')) continue;
    scanned++;
    final String code = maskCommentsAndStrings(e.readAsStringSync());
    for (final String line in code.split('\n')) {
      patterns.forEach((String kind, String source) {
        final int n = RegExp(source).allMatches(line).length;
        if (n > 0) found[kind]![path] = (found[kind]![path] ?? 0) + n;
      });
    }
  }

  test('扫描覆盖完整 lib 源码树', () {
    expectScanScale(
      scanned,
      what: 'lib 非生成 Dart 文件',
      atLeast: 1200,
      measured: 1547,
    );
  });

  test('计数忽略注释与字符串，URL 不遮掉真实调用', () {
    const String source = """// Tooltip(
/* Badge.count(
RefreshIndicator( */
final hint = 'SnackBar(';
final url = 'https://example.test'; Tooltip();
Badge.count();
""";
    final String code = maskCommentsAndStrings(source);
    expect(
      <String, int>{
        for (final MapEntry<String, String> pattern in patterns.entries)
          pattern.key: RegExp(pattern.value).allMatches(code).length,
      },
      <String, int>{
        'SnackBar': 0,
        'Tooltip': 1,
        'Badge': 1,
        'RefreshIndicator': 0,
      },
    );
  });

  for (final String kind in patterns.keys) {
    test('裸 $kind 不新增（白名单只减不增）', () {
      final List<String> violations = <String>[];
      found[kind]!.forEach((String path, int count) {
        final int allowed = allowlist[kind]![path] ?? 0;
        if (count > allowed) {
          violations.add('$path: $count 处（白名单 $allowed）');
        }
      });
      expect(
        violations,
        isEmpty,
        reason: '新增了裸 $kind 用法——改用 Fushi 统一组件（见本文件头注释）',
      );
    });
  }
}
