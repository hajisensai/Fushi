// Apple（Cupertino，iOS 27 / macOS 27）设计系统的令牌守卫：与 M3E 令牌守卫
// （m3e_design_system_static_test.dart）对称。M3E 守卫跳过 Apple 专属文件，本
// 守卫只扫它们（判据共用 test/helpers/apple_design_sources.dart），审四件事：
//
// 1. 不用 M3E 专属令牌（FushiBorderRadius / FushiRadii / FushiM3eShape /
//    kFushiMd3* / tokens.radii）——Apple 圆角走 FushiAppleRadii。双系统分派的
//    共享令牌（context.fushiType、fushiCardBorderRadius、FushiDesignTokens 的
//    间距）不在此列。
// 2. 不画裸 Material 控件（IconButton / ListTile / AlertDialog / showMenu …）
//    ——走 Fushi* 共享组件的 Apple 分支（用户 2026-11-24：Material 与 Cupertino
//    不混搭）。
// 3. 不读 Material 色调角色（colorScheme.* / ColorScheme）——颜色走
//    appleColorsOf；只允许读 colorScheme.brightness。
// 4. 固定圆角不写数字字面量（`Radius.circular(8)` / `circular(6 * k)`）——走
//    FushiAppleRadii 刻度。胶囊（`extent / 2`）与随边长成比例的连续曲率
//    （`side * 0.22`）是派生几何，不受限。
//
// 豁免按「文件 → 规则」逐条登记并写明理由；登记了却不再命中的过期项判红。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/apple_design_sources.dart';
import '../helpers/scan_scale.dart';
import '../helpers/source_guard.dart';

/// 规则名 → 禁止形态（在剥掉注释的源码上匹配）。
final Map<String, RegExp> _rules = <String, RegExp>{
  'm3e-token': RegExp(
    r'\bFushiBorderRadius\.|\bFushiRadii\b|\bFushiM3eShape\b|\bkFushiMd3\w*'
    r'|\.radii\b',
  ),
  'material-control': RegExp(
    r'(?<![\w.$])(?:IconButton|AlertDialog|SimpleDialog|ListTile'
    r'|SwitchListTile|CheckboxListTile|RadioListTile|PopupMenuButton|Card'
    r'|InkWell|InkResponse|FilledButton|ElevatedButton|OutlinedButton'
    r'|TextButton|SegmentedButton|Chip|ActionChip|FilterChip|ChoiceChip'
    r'|InputChip|Switch|Checkbox|Radio|Slider|AppBar|SliverAppBar'
    r'|NavigationBar|NavigationRail|BottomNavigationBar|FloatingActionButton'
    r'|Divider|VerticalDivider|SnackBar|Tooltip|DropdownButton|TabBar'
    r'|ExpansionTile|Material)(?:\.\w+)?\('
    r'|(?<![\w.$])(?:showDialog|showModalBottomSheet|showMenu)\s*[<(]',
  ),
  // `colorScheme:` 是命名参数标签（把派生好的配色传给共享子件），不是读色调。
  'material-tone': RegExp(
    r'\bcolorScheme\b(?!\.brightness|\s*:)|\bColorScheme\b',
  ),
  'literal-radius': RegExp(
    r'Radius\.(?:circular|elliptical)\(\s*[\d.]+\s*[,)*]',
  ),
};

/// 审过的豁免：文件 → 规则 → 理由。
const Map<String, Map<String, String>> _allowed = <String, Map<String, String>>{
  'lib/src/utils/components/glass/fushi_apple_palette.dart': <String, String>{
    'material-tone':
        'Apple 色板本身：appleColorsOf 在非玻璃主题下从 colorScheme 现算 Apple '
        '系统色，appleColorScheme 把 Apple 系统色写回 ColorScheme 槽位供少数 '
        'Material 表面使用——它就是两套颜色之间的唯一映射源。',
  },
};

void main() {
  late final Map<String, String> sources;

  setUpAll(() {
    final List<File> files =
        Directory('lib/src')
            .listSync(recursive: true)
            .whereType<File>()
            .where((File file) => file.path.endsWith('.dart'))
            .where((File file) => isAppleDesignOnlySource(file.path))
            .toList(growable: false)
          ..sort((File a, File b) => a.path.compareTo(b.path));
    sources = <String, String>{
      for (final File file in files)
        file.path.replaceAll(r'\', '/'): maskComments(file.readAsStringSync()),
    };
  });

  test('Apple-only source classification excludes Apple service names', () {
    for (final String path in <String>[
      'lib/src/pages/implementations/srs/apple/apple_srs_charts.dart',
      'lib/src/media/audiobook/lyrics_player/lyrics_player_apple.dart',
      'lib/src/pages/implementations/music/music_lyrics_page_apple.part.dart',
      'lib/src/utils/components/glass/fushi_apple_palette.dart',
      'lib/src/utils/adaptive/nav_rail/apple_sidebar_tabs.part.dart',
    ]) {
      expect(isAppleDesignOnlySource(path), isTrue, reason: path);
    }
    for (final String path in <String>[
      'lib/src/media/music/apple_music/apple_music_web_login_page.dart',
      'lib/src/pages/implementations/music/music_apple_music_pages.dart',
      'lib/src/asr_host/apple_speech_channel.dart',
      'lib/src/platform/home_widgets/apple_widgets_host.dart',
      'lib/src/pages/implementations/home_dashboard_page.dart',
      'lib/src/utils/components/pineapple_widget.dart',
    ]) {
      expect(isAppleDesignOnlySource(path), isFalse, reason: path);
    }
  });

  test('Apple-only files use Apple tokens and Apple components only', () {
    expectScanScale(
      sources.length,
      what: 'lib/src 下的 Apple 设计系统专属 .dart',
      atLeast: 50,
      measured: 65,
    );
    final List<String> violations = <String>[];
    final Map<String, Set<String>> liveAllowed = <String, Set<String>>{};
    for (final MapEntry<String, String> entry in sources.entries) {
      final String path = entry.key;
      final String source = entry.value;
      final Map<String, String> allowedRules =
          _allowed[path] ?? const <String, String>{};
      for (final MapEntry<String, RegExp> rule in _rules.entries) {
        final List<RegExpMatch> hits = rule.value
            .allMatches(source)
            .toList(growable: false);
        if (hits.isEmpty) continue;
        if (allowedRules.containsKey(rule.key)) {
          liveAllowed.putIfAbsent(path, () => <String>{}).add(rule.key);
          continue;
        }
        for (final RegExpMatch hit in hits) {
          final int line =
              '\n'.allMatches(source.substring(0, hit.start)).length + 1;
          violations.add('$path:$line [${rule.key}] ${hit.group(0)}');
        }
      }
    }
    expect(
      violations,
      isEmpty,
      reason:
          'Apple 专属文件里出现了 M3E 令牌 / 裸 Material 控件 / Material 色调 / '
          '数字圆角。圆角走 FushiAppleRadii，颜色走 appleColorsOf，控件走 Fushi* '
          '共享组件的 Apple 分支；确属例外的在 _allowed 里按规则登记理由。',
    );
    final List<String> stale = <String>[
      for (final MapEntry<String, Map<String, String>> entry
          in _allowed.entries)
        for (final String rule in entry.value.keys)
          if (!(liveAllowed[entry.key]?.contains(rule) ?? false))
            '${entry.key} [$rule]',
    ];
    expect(stale, isEmpty, reason: '豁免已不再命中，删掉过期登记。');
  });

  test('rules catch the forms they are meant to ban', () {
    bool hits(String rule, String code) => _rules[rule]!.hasMatch(code);
    expect(hits('m3e-token', 'borderRadius: FushiBorderRadius.chip,'), isTrue);
    expect(hits('m3e-token', 'FushiM3eShape.cardRadius'), isTrue);
    expect(hits('m3e-token', 'context.fushiType.bodyMedium'), isFalse);
    expect(hits('material-control', 'child: IconButton('), isTrue);
    expect(hits('material-control', 'const Card(child: x)'), isTrue);
    expect(hits('material-control', 'await showMenu<int>('), isTrue);
    expect(hits('material-control', 'FushiCardControl('), isFalse);
    expect(hits('material-control', 'actions.showMenu(game)'), isFalse);
    expect(
      hits('material-tone', 'Theme.of(context).colorScheme.primary'),
      isTrue,
    );
    expect(hits('material-tone', 'theme.colorScheme.brightness'), isFalse);
    expect(hits('material-tone', 'colorScheme: chromeScheme,'), isFalse);
    expect(hits('literal-radius', 'BorderRadius.circular(8)'), isTrue);
    expect(hits('literal-radius', 'BorderRadius.circular(6 * k)'), isTrue);
    expect(hits('literal-radius', 'const Radius.circular(12),'), isTrue);
    expect(
      hits('literal-radius', 'BorderRadius.circular(height / 2)'),
      isFalse,
    );
    expect(
      hits('literal-radius', 'BorderRadius.circular(side * 0.22)'),
      isFalse,
    );
  });
}
