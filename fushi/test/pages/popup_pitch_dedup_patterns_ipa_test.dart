import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-2397：「音调去重」对 pattern 式音调与 IPA 完全不生效，且在浏览器扩展里
/// **从来没生效过**。
///
/// 用户报告：设置里 Deduplicate pitch accents 开着，音高区照样出现一模一样的重复行。
///
/// 两条独立根因：
/// ① `createPitchSection` 的去重分支只把**数字位置**收进 seen，`patterns`
///    （"heiban" 等 pattern 式音调）与 `transcriptions`（IPA）一概不参与；保活守卫
///    又用「原始字段非空」，于是第二本词典一个字都不新也照样整行渲染。上游的
///    `mergeIdenticalPitchGroups` 只接得住「整份 payload 全等」那一种，两本词典
///    只要差一个字段（一本带 IPA、一本不带）就合并不了，重复全落到去重这一步。
/// ② 浏览器扩展里 `window.deduplicatePitchAccents` **从未有人赋值**：这个偏好没被
///    放进 app 下发给扩展的 theme 通道，扩展 content.js 也没有消费它，于是恒
///    undefined = falsy，去重分支恒不执行——用户在 app 里怎么设都没用。
///
/// 三层守护：
/// ① 行为级——用 Node 真执行 popup.js 的 `createPitchSection`（见同名 .js）。
/// ② 源码级——扫描**三份 popup.js 镜像**，钉住三类可见条目各自入 seen、保活判据
///    用去重后的结果。无 node 时也能守住回归。
/// ③ 接线级——钉住 app 侧下发 `--fushi-dedup-pitch` 与**两份** content.js 消费它，
///    否则根因②会悄悄回来（那条链路上没有任何行为测试能覆盖）。
void main() {
  const Map<String, String> jsMirrors = <String, String>{
    'app popup': 'assets/popup/popup.js',
    'extension vendor (assets)': 'assets/browser_extension/vendor/popup.js',
    'extension vendor (tools)': '../tools/browser-extension/vendor/popup.js',
  };
  const Map<String, String> contentMirrors = <String, String>{
    'extension content (assets)': 'assets/browser_extension/content.js',
    'extension content (tools)': '../tools/browser-extension/content.js',
  };

  test(
    'pattern accents and IPA transcriptions are deduplicated across dictionaries '
    '(executes createPitchSection via node)',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
            'node not found on PATH; skipping JS behavior execution');
        return;
      }

      final File jsTest =
          File('test/pages/popup_pitch_dedup_patterns_ipa_test.js');
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
        reason: 'pitch dedup (patterns / IPA) JS behavior test failed.\n'
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
    test('[$name] pitch dedup covers positions, patterns AND transcriptions',
        () {
      final File file = File(relPath);
      expect(file.existsSync(), isTrue, reason: '$relPath must exist');
      final String js = file.readAsStringSync();

      final int dedup = js.indexOf('if (window.deduplicatePitchAccents)');
      expect(dedup, greaterThanOrEqualTo(0),
          reason: 'the dedup branch must exist');

      // 三类可见条目各有自己的 seen。少一个 = 那一类永远不去重（本 bug 的原状）。
      for (final String seen in <String>[
        'const seenPositions = new Set();',
        'const seenPatterns = new Set();',
        'const seenTranscriptions = new Set();',
      ]) {
        expect(
          js.indexOf(seen, dedup),
          greaterThan(dedup),
          reason: 'the dedup branch must keep a dedicated set: $seen',
        );
      }

      // 非恒真：三个 Set 建了却没人过滤等于没改。三类都必须真的按 seen 过滤。
      for (final String filter in <String>[
        '.filter(pos => !seenPositions.has(pos))',
        '.filter(p => !seenPatterns.has(p))',
        '.filter(ipa => !seenTranscriptions.has(ipa))',
      ]) {
        expect(
          js.indexOf(filter, dedup),
          greaterThan(dedup),
          reason: 'each class of visible entry must be filtered: $filter',
        );
      }

      // 保活判据必须是「去重后还剩东西」。写成原始字段非空（`group.patterns?.length`）
      // 的那一刻，一整行已经显示过的 pattern / IPA 又会被画第二遍。
      final int guard = js.indexOf(
        'if (unique.length > 0 || uniquePatterns.length > 0 || '
        'uniqueTranscriptions.length > 0)',
        dedup,
      );
      expect(
        guard,
        greaterThan(dedup),
        reason: 'the keep-alive guard must test the DEDUPED entries, not the '
            'raw fields — testing the raw fields is exactly BUG-2397',
      );
    });
  });

  test('the pitch dedup preference is wired through to the browser extension',
      () {
    // 根因②的守卫。app 侧把偏好放进查词响应的 theme 字典（非 CSS 变量、仅 JS 消费，
    // 与 --fushi-instant-scroll 同法），扩展 content.js 据此设 popup.js 读的全局。
    final String appModel =
        File('lib/src/models/app_model.dart').readAsStringSync();
    expect(
      appModel,
      contains("'--fushi-dedup-pitch': deduplicatePitchAccents ? '1' : '0',"),
      reason:
          'app_model must send the pitch-dedup preference to the extension; '
          'without it window.deduplicatePitchAccents is undefined in the '
          'browser and the dedup branch never runs',
    );

    contentMirrors.forEach((String name, String relPath) {
      final File file = File(relPath);
      expect(file.existsSync(), isTrue, reason: '$relPath must exist');
      expect(
        file.readAsStringSync(),
        contains(
            "window.deduplicatePitchAccents = theme['--fushi-dedup-pitch'] === '1';"),
        reason: '[$name] content.js must publish the preference on the shared '
            'window that popup.js reads',
      );
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
