import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-688: the lookup popup must RENDER the IPA `transcriptions` that
/// TODO-687 block3 wired into the popup JSON.
///
/// 背景：每个 pitch group 在 popup JSON 里带 `transcriptions` 字符串数组（如
/// `['neꜜko']`），普通音高词典为空，Yomitan `ipa`-mode 词典非空。TODO-687 已把数据
/// 贯通到 `popup.js` 接收的 entry，但 `popup.js` 之前没渲染它，用户看不到 IPA。
/// 本任务在 pitch group 内把每条 transcription 渲染成 `[ipa]` 小标签。
///
/// 两层守护：
/// ① 行为级——用 Node 真执行 popup.js 的 `createPitchSection`，断言：普通词典
///    （空 transcriptions）不渲染 transcriptions 列表；含 transcriptions 的词典
///    把 `[neꜜko]` 等渲染出来；纯 IPA 词典（pitchPositions 为空）在去重分支下
///    仍保留并渲染 transcriptions（不被空位置守卫丢掉）。无 node 时 skip。
/// ② 源码级——静态扫描 popup.js，保证 transcriptions 渲染路径在位（即便无 node
///    也能在 CI 守住回归），且非恒真——断言具体的渲染 helper、调用点、去重分支守卫。
void main() {
  test(
    'popup renders IPA transcriptions in the pitch group (executes createPitchSection via node)',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
            'node not found on PATH; skipping JS behavior execution');
        return;
      }

      final File jsTest = File(
        'test/pages/popup_pitch_transcriptions_test.js',
      );
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
        reason: 'popup IPA transcriptions JS behavior test failed.\n'
            'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(
        result.stdout.toString(),
        contains('all assertions passed'),
        reason: 'behavior harness must reach its success marker',
      );
    },
  );

  test('popup.js renders pitch-group transcriptions as IPA tags', () {
    final String js = File('assets/popup/popup.js').readAsStringSync();

    // The dedicated transcription builder must exist and emit a `[ipa]` tag.
    expect(
      js,
      contains('function createTranscriptionsHtml(transcriptions)'),
      reason: 'a transcriptions render helper must exist',
    );
    expect(
      js,
      contains('textContent: `[\${ipa}]`'),
      reason: 'each transcription must render as an `[ipa]` tag',
    );

    // createPitchGroup must actually call the builder and append it — non-tautological:
    // the builder existing alone does nothing if never invoked.
    final int builderDef = js.indexOf('function createTranscriptionsHtml');
    final int groupDef = js.indexOf('function createPitchGroup');
    expect(groupDef, greaterThanOrEqualTo(0));
    final int call = js.indexOf(
        'createTranscriptionsHtml(pitchData.transcriptions)', groupDef);
    expect(
      call,
      greaterThan(groupDef),
      reason:
          'createPitchGroup must build transcriptions from its pitch group data',
    );
    expect(builderDef, greaterThanOrEqualTo(0));
  });

  test('popup.js dedup branch keeps IPA-only pitch groups (empty positions)',
      () {
    final String js = File('assets/popup/popup.js').readAsStringSync();

    // The deduplicate-pitch-accents branch must not drop a group that has no
    // unique pitch positions but DOES have transcriptions, and it must forward
    // the transcriptions into createPitchGroup.
    final int dedup = js.indexOf('if (window.deduplicatePitchAccents)');
    expect(dedup, greaterThanOrEqualTo(0));
    final int hasTranscriptions =
        js.indexOf('pitch.transcriptions?.length', dedup);
    expect(
      hasTranscriptions,
      greaterThan(dedup),
      reason:
          'the dedup branch must keep IPA-only groups (transcriptions guard)',
    );
    final int forwarded =
        js.indexOf('transcriptions: pitch.transcriptions', dedup);
    expect(
      forwarded,
      greaterThan(dedup),
      reason:
          'the dedup branch must forward transcriptions into createPitchGroup',
    );
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
