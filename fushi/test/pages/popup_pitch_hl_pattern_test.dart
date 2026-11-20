import 'dart:io';

import 'package:test/test.dart';

/// BUG-5054（反馈 ax68AKUrex）：H/L 模式串音调（大辞泉+ / NHK-meta 的 "LHHHH"）在弹窗里
/// 只显示成文本、不画高低线，且没有换算成下降位，与同型数字位 [0] 分成两行；制卡字段
/// 也写成 [LHHHH]。
///
/// 两层守护：
/// ① 行为级——用 Node 真执行 popup.js（见同名 .js）。
/// ② 源码级——三份 popup.js 镜像都把 `normalizePitchPatterns` 接在弹窗与制卡两条路径的
///    `mergeIdenticalPitchGroups` 之前（制卡路径 `buildMinePayload` 依赖太多，行为测试够不着）。
void main() {
  const Map<String, String> jsMirrors = <String, String>{
    'app popup': 'assets/popup/popup.js',
    'extension vendor (assets)': 'assets/browser_extension/vendor/popup.js',
    'extension vendor (tools)': '../tools/browser-extension/vendor/popup.js',
  };

  test('H/L pitch patterns are drawn and normalized to downsteps '
      '(executes popup.js via node)', () async {
    final String? nodeExe = _resolveNode();
    if (nodeExe == null) {
      markTestSkipped('node not found on PATH; skipping JS behavior execution');
      return;
    }
    const String jsPath = 'test/pages/popup_pitch_hl_pattern_test.js';
    expect(File(jsPath).existsSync(), isTrue);
    final ProcessResult result = await Process.run(nodeExe, <String>[
      jsPath,
    ], workingDirectory: Directory.current.path);
    expect(
      result.exitCode,
      0,
      reason:
          'H/L pitch pattern JS behavior test failed.\n'
          'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
    );
    expect(result.stdout.toString(), contains('all assertions passed'));
  });

  jsMirrors.forEach((String name, String relPath) {
    test('[$name] both popup and mining paths normalize H/L patterns '
        'before merging', () {
      final File file = File(relPath);
      expect(file.existsSync(), isTrue, reason: '$relPath must exist');
      final String js = file.readAsStringSync();

      expect(
        js,
        contains(
          'mergeIdenticalPitchGroups(normalizePitchPatterns(pitches, reading))',
        ),
        reason: 'createPitchSection must normalize before merging',
      );

      final int mine = js.indexOf('async function buildMinePayload(');
      expect(mine, greaterThanOrEqualTo(0));
      final int normalize = js.indexOf(
        'normalizePitchPatterns(pitches || [], reading)',
        mine,
      );
      final int merge = js.indexOf(
        'mergeIdenticalPitchGroups(patternNormalizedPitches)',
        mine,
      );
      final int categories = js.indexOf(
        'constructPitchCategories(patternNormalizedPitches, reading, rules)',
        mine,
      );
      expect(normalize, greaterThan(mine));
      expect(merge, greaterThan(normalize));
      expect(categories, greaterThan(normalize));
    });
  });
}

/// Resolve a usable `node` executable, returning null when none is on PATH.
String? _resolveNode() {
  final List<String> candidates = Platform.isWindows
      ? <String>['node.exe', 'node']
      : <String>['node'];
  for (final String name in candidates) {
    try {
      final ProcessResult probe = Process.runSync(name, <String>['--version']);
      if (probe.exitCode == 0) {
        return name;
      }
    } on ProcessException {
      // Not found; try next candidate.
    }
  }
  return null;
}
