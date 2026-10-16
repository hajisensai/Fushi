import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/scan_scale.dart';
import '../helpers/source_guard.dart';

/// 分段选择一律用设计系统组件（用户 2026-10-16：「分段选择器还是老样式，用 m3e，写进规则吧都用
/// 新的」）。页面里直接构造 Flutter 原生 [SegmentedButton] 会绕过设计系统分派，在 Material 下画出
/// 旧版 MD3 的描边分段，而不是 M3E 胶囊分段；Apple 设计系统下也拿不到 iOS 分段控件。
///
/// 该用的入口：
/// - `adaptiveSegmentedButton(...)`（`lib/src/utils/adaptive/adaptive_widgets.dart`）：Material =
///   M3E 胶囊分段（`FushiPillSegmentedButton`）、Apple = iOS 分段；设置行用
///   `AdaptiveSettingsSegmentedRow`，它内部也走这条。
/// - `FushiSegmentedButton`（多选、竖排、允许空选等 `SegmentedButton` 同参需求）：Material =
///   M3E 连接式按钮组（`FushiConnectedButtonGroup`）。
///
/// 只有组件实现自己可以碰原生 `SegmentedButton`（下面的豁免表，每条写明理由）。
void main() {
  const Map<String, String> allowed = <String, String>{
    'lib/src/utils/components/glass/fushi_glass_toggles.dart':
        'FushiSegmentedButton itself: e-ink keeps the Material original (the '
        'inverted selected fill is tuned for e-ink in theme_notifier).',
    'lib/src/utils/components/fushi_pill_segmented_button.dart':
        'The M3E capsule segmented control is implemented as a SegmentedButton '
        'subclass (extends / State<SegmentedButton<T>>).',
  };
  // `SegmentedButton(` / `SegmentedButton<`，前面不是标识符字符（排除 FushiSegmentedButton、
  // FushiPillSegmentedButton 等）；`SegmentedButton.styleFrom` 这类静态成员不算构造。
  final RegExp raw = RegExp(r'(?<![A-Za-z0-9_])SegmentedButton\s*[<(]');

  test(
    'pages build segmented controls through the design-system components',
    () {
      final List<File> files =
          Directory('lib/src')
              .listSync(recursive: true)
              .whereType<File>()
              .where((File f) => f.path.endsWith('.dart'))
              .toList(growable: false)
            ..sort((File a, File b) => a.path.compareTo(b.path));
      expectScanScale(
        files.length,
        what: 'lib/src 下的 .dart',
        atLeast: 750,
        measured: 930,
      );
      final List<String> offenders = <String>[];
      final Set<String> usedAllowances = <String>{};
      for (final File file in files) {
        final String path = file.path.replaceAll(r'\', '/');
        final String source = maskComments(file.readAsStringSync());
        if (!raw.hasMatch(source)) continue;
        if (allowed.containsKey(path)) {
          usedAllowances.add(path);
          continue;
        }
        final int line =
            '\n'
                .allMatches(source.substring(0, raw.firstMatch(source)!.start))
                .length +
            1;
        offenders.add('$path:$line');
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'Use adaptiveSegmentedButton (M3E capsule / iOS segmented) or '
            'FushiSegmentedButton (M3E connected button group) instead of a raw '
            'SegmentedButton:\n${offenders.join('\n')}',
      );
      expect(
        usedAllowances,
        allowed.keys.toSet(),
        reason:
            'stale allowance: the file no longer builds a raw SegmentedButton',
      );
    },
  );
}
