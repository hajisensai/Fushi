import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-2122：音高区里同一个音调型被多本词典各占一行。
///
/// 用户报告（官网首页 demo 弹窗查「ギター」）：音高区连出五行一模一样的
/// `￣ギター [1]`，只有前面的来源药丸不同。Yomitan 的 `getGroupedPronunciations`
/// 把相同发音合并成一条、后面挂全部来源；popup.js 之前是一本词典一行。
///
/// 修法：渲染前加一道纯变换 `mergeIdenticalPitchGroups` —— 整份 payload 全等
/// （pitchPositions / patterns / transcriptions 三者）的词典合并成一行，
/// `dictionaries` 带上全部来源名。它跑在 `deduplicatePitchAccents` 分支**之后**：
/// 去重打开（app 默认）时各存活组的位置互斥、合并对位置组恒为 no-op，默认外观
/// 一字不变；去重关闭（官网 demo 就是这一档）时才塌行。
///
/// 两层守护：
/// ① 行为级——用 Node 真执行 popup.js 的 `createPitchSection`，断言五本同型词典
///    塌成 1 行 5 枚药丸、音调型不同的不合并、去重打开时行为与改动前逐字一致。
///    无 node 时 skip。
/// ② 源码级——静态扫描**三份镜像副本**（app / 扩展 assets / 扩展 tools），保证合并
///    helper、调用点、多药丸渲染和 CSS 换行在位；即便无 node 也能守住回归，且三份
///    副本不会漂移。
void main() {
  const Map<String, String> jsMirrors = <String, String>{
    'app popup': 'assets/popup/popup.js',
    'extension vendor (assets)': 'assets/browser_extension/vendor/popup.js',
    'extension vendor (tools)': '../tools/browser-extension/vendor/popup.js',
  };
  const Map<String, String> cssMirrors = <String, String>{
    'app popup': 'assets/popup/popup.css',
    'extension vendor (assets)': 'assets/browser_extension/vendor/popup.css',
    'extension vendor (tools)': '../tools/browser-extension/vendor/popup.css',
  };

  test(
    'identical pitch accents from several dictionaries merge into one row '
    '(executes createPitchSection via node)',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
            'node not found on PATH; skipping JS behavior execution');
        return;
      }

      final File jsTest =
          File('test/pages/popup_pitch_merge_identical_test.js');
      expect(
        jsTest.existsSync(),
        isTrue,
        reason: 'behavior harness ${jsTest.path} must exist',
      );

      final ProcessResult result = await Process.run(
        nodeExe,
        <String>[jsTest.path],
        workingDirectory: Directory.current.path,
      );

      expect(
        result.exitCode,
        0,
        reason: 'popup pitch merge JS behavior test failed.\n'
            'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(
        result.stdout.toString(),
        contains('all assertions passed'),
        reason: 'behavior harness must reach its success marker',
      );
    },
  );

  jsMirrors.forEach((String name, String relPath) {
    test('[$name] popup.js merges identical pitch groups before rendering', () {
      final File file = File(relPath);
      expect(file.existsSync(), isTrue, reason: '$relPath must exist');
      final String js = file.readAsStringSync();

      // 合并 helper 必须存在，且判据是整份 payload（三者全等），不是只看位置。
      final int helper =
          js.indexOf('function mergeIdenticalPitchGroups(groups)');
      expect(
        helper,
        greaterThanOrEqualTo(0),
        reason: 'the pitch merge helper must exist',
      );
      for (final String field in <String>[
        'group.pitchPositions || []',
        'group.patterns || []',
        'group.transcriptions || []',
      ]) {
        expect(
          js.indexOf(field, helper),
          greaterThan(helper),
          reason: 'the merge key must cover $field — merging on a partial '
              'payload would fuse dictionaries that disagree',
        );
      }

      // 非恒真：helper 存在但没人调用等于没改。调用点必须在 createPitchSection 内，
      // 且在去重分支之后（去重先跑，合并是最后一道变换）。
      final int section =
          js.indexOf('function createPitchSection(pitches, reading)');
      expect(section, greaterThanOrEqualTo(0));
      final int dedup =
          js.indexOf('if (window.deduplicatePitchAccents)', section);
      expect(dedup, greaterThan(section));
      final int call =
          js.indexOf('mergeIdenticalPitchGroups(groups).forEach(', section);
      expect(
        call,
        greaterThan(dedup),
        reason: 'createPitchSection must run the merge AFTER the dedup branch, '
            'so dedup ON keeps the pre-change default look',
      );

      // 去重分支不得再直接 append，必须先攒进 groups 交给合并。
      expect(
        js.substring(dedup, call),
        isNot(contains('pitchContainer.appendChild(createPitchGroup(')),
        reason: 'the dedup branch must collect groups instead of appending '
            'rows directly, or merging never sees them',
      );

      // createPitchGroup 每本来源渲染一枚药丸。
      final int group =
          js.indexOf('function createPitchGroup(pitchData, reading)');
      expect(group, greaterThanOrEqualTo(0));
      expect(
        js.indexOf(
            'const dictionaries = pitchData.dictionaries || [pitchData.dictionary];',
            group),
        greaterThan(group),
        reason: 'createPitchGroup must accept a dictionary LIST (single-source '
            'groups degrade to a one-element list)',
      );
      final int labelLoop =
          js.indexOf('dictionaries.forEach((dictionary) => {', group);
      expect(
        labelLoop,
        greaterThan(group),
        reason: 'every merged source must get its own .pitch-dict-label pill',
      );
      expect(
        js.indexOf("className: 'pitch-dict-label', textContent: dictionary",
            labelLoop),
        greaterThan(labelLoop),
        reason: 'the pill loop must render the per-dictionary label',
      );
    });
  });

  cssMirrors.forEach((String name, String relPath) {
    test('[$name] popup.css lets a merged pitch row wrap its source pills', () {
      final File file = File(relPath);
      expect(file.existsSync(), isTrue, reason: '$relPath must exist');
      final String css = file.readAsStringSync();

      final int rule = css.indexOf('.pitch-group {');
      expect(rule, greaterThanOrEqualTo(0),
          reason: '.pitch-group rule must exist');
      final int end = css.indexOf('}', rule);
      expect(end, greaterThan(rule));
      final String body = css.substring(rule, end);
      expect(
        body,
        contains('flex-wrap: wrap'),
        reason: 'a merged row can carry several source pills; without wrapping '
            'they push the reading past the popup edge',
      );
      // 换行只在 flex 容器上有意义——顺带钉住这条规则仍是 flex。
      expect(body, contains('display: flex'));
    });
  });
}

/// Resolve a usable `node` executable, returning null when none is on PATH.
String? _resolveNode() {
  final List<String> candidates =
      Platform.isWindows ? <String>['node.exe', 'node'] : <String>['node'];
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
