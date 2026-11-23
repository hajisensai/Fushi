import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// 反馈 iTMx1pCb2V：`{pitch-accent-positions}` 是 `<ul>` 列表，多音调的词在卡片上
/// 一调一行。新增单行变体 `{pitch-accent-positions-inline}`（条目间「・」连接，不包
/// 列表）；默认 marker 不变，Lapis 的 `#pitch-tags ul` 归一样式照旧生效（BUG-2151）。
///
/// 三层：① 行为级——node 真执行 popup.js 的构造函数；② popup.js 制卡 payload 带上
/// `pitchPositionsInline`（三镜像）；③ Dart 侧 marker → payload 字段 → 渲染 / 选项 /
/// 远端制卡白名单全链路。
const String _inline =
    '<span style="display:inline;"><span>[</span><span>0</span><span>]</span></span>'
    '・'
    '<span style="display:inline;"><span>[</span><span>2</span><span>]</span></span>';

void main() {
  test('constructPitchPositionInlineHtml joins entries on one line '
      '(executes popup.js via node)', () async {
    final String? nodeExe = _resolveNode();
    if (nodeExe == null) {
      markTestSkipped('node not found on PATH; skipping JS behavior execution');
      return;
    }
    const String jsPath = 'test/pages/popup_pitch_positions_inline_test.js';
    expect(File(jsPath).existsSync(), isTrue);
    final ProcessResult result = await Process.run(nodeExe, <String>[
      jsPath,
    ], workingDirectory: Directory.current.path);
    expect(
      result.exitCode,
      0,
      reason:
          'pitch positions inline JS behavior test failed.\n'
          'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
    );
    expect(result.stdout.toString(), contains('all assertions passed'));
  });

  const Map<String, String> jsMirrors = <String, String>{
    'app popup': 'assets/popup/popup.js',
    'extension vendor (assets)': 'assets/browser_extension/vendor/popup.js',
    'extension vendor (tools)': '../tools/browser-extension/vendor/popup.js',
  };
  jsMirrors.forEach((String name, String relPath) {
    test('[$name] buildMinePayload ships pitchPositionsInline', () {
      final String js = File(relPath).readAsStringSync();
      final int mine = js.indexOf('async function buildMinePayload(');
      expect(mine, greaterThanOrEqualTo(0));
      expect(
        js.indexOf('constructPitchPositionInlineHtml(normalizedPitches)', mine),
        greaterThan(mine),
        reason: '单行变体必须吃与默认字段同一份归一化后的 pitches',
      );
      expect(
        js.indexOf('\n        pitchPositionsInline,', mine),
        greaterThan(mine),
        reason: 'payload 对象里缺 pitchPositionsInline',
      );
    });
  });

  test('marker renders payload.pitchPositionsInline', () {
    const AnkiMiningPayload payload = AnkiMiningPayload(
      expression: '橋',
      pitchPositions: '<ul><li>a</li></ul>',
      pitchPositionsInline: _inline,
    );
    const AnkiMiningContext context = AnkiMiningContext(sentence: '');
    expect(
      AnkiHandlebarRenderer.render(
        '{pitch-accent-positions-inline}',
        payload,
        context,
      ),
      _inline,
    );
    expect(
      AnkiHandlebarRenderer.render(
        '{pitch-accent-positions}',
        payload,
        context,
      ),
      '<ul><li>a</li></ul>',
      reason: '默认 marker 不受影响',
    );
  });

  test(
    'fromJson reads pitchPositionsInline; missing key falls back to empty',
    () {
      expect(
        AnkiMiningPayload.fromJson(<String, dynamic>{
          'expression': '橋',
          'pitchPositionsInline': _inline,
        }).pitchPositionsInline,
        _inline,
      );
      expect(
        AnkiMiningPayload.fromJson(<String, dynamic>{
          'expression': '橋',
        }).pitchPositionsInline,
        '',
      );
    },
  );

  test('mapping UI offers the marker right after {pitch-accent-positions}', () {
    final List<String> options = AnkiHandlebarOptions.coreOptions;
    final int base = options.indexOf('{pitch-accent-positions}');
    expect(base, greaterThanOrEqualTo(0));
    expect(options[base + 1], '{pitch-accent-positions-inline}');
  });

  test('settings page labels the marker', () {
    final String src = File(
      'lib/src/pages/implementations/anki_settings_page.dart',
    ).readAsStringSync();
    expect(
      src,
      contains(
        "case '{pitch-accent-positions-inline}':\n"
        '      return t.handlebar_pitch_accent_positions_inline;',
      ),
    );
  });

  test('payload copies keep pitchPositionsInline (防字段漂移)', () {
    for (final String path in <String>[
      'lib/src/anki/ankimobile_repository.dart',
      '../packages/fushi_anki/lib/src/anki_note_composer.dart',
    ]) {
      expect(
        File(path).readAsStringSync(),
        contains('pitchPositionsInline: payload.pitchPositionsInline,'),
        reason: '$path 复制 payload 时丢了 pitchPositionsInline',
      );
    }
    expect(
      File('lib/src/sync/game_stream_mining.dart').readAsStringSync(),
      contains("  'pitchPositionsInline',\n"),
      reason: '远端（串流副屏）制卡白名单缺 pitchPositionsInline',
    );
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
