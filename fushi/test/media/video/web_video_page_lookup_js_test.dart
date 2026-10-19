import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `assets/web_video/web_video_page_lookup.js` 的纯逻辑（取光标所在的那一句 + 句内字形下标），
/// 在 node 里跑。没有 node 就跳过。
void main() {
  final bool hasNode = () {
    try {
      return Process.runSync('node', <String>['--version']).exitCode == 0;
    } on ProcessException {
      return false;
    }
  }();

  Future<Object?> run(String expr) async {
    final String script = File(
      'assets/web_video/web_video_page_lookup.js',
    ).readAsStringSync();
    final String harness =
        '''
globalThis.window = globalThis;
globalThis.document = { addEventListener: function () {} };
$script
const p = window.__fushiPageLookup._pure;
console.log(JSON.stringify($expr));
''';
    final Directory dir = await Directory.systemTemp.createTemp('page_lookup');
    try {
      final File f = File('${dir.path}/h.js')..writeAsStringSync(harness);
      final ProcessResult r = await Process.run(
        'node',
        <String>[f.path],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      expect(r.exitCode, 0, reason: '${r.stderr}');
      return jsonDecode((r.stdout as String).trim());
    } finally {
      await dir.delete(recursive: true);
    }
  }

  test('取光标所在的那一句，下标按句内字形算', () async {
    const String text = '今日はいい天気。散歩に行きましょう！また明日。';
    final int offset = text.indexOf('散歩') + 1;
    expect(
      await run('p.sentenceAt(${jsonEncode(text)}, $offset)'),
      <String, Object>{'sentence': '散歩に行きましょう！', 'index': 1},
    );
  }, skip: !hasNode);

  test('英文句号后跟空白才断句；前导空白不算下标', () async {
    const String text = 'Hello there. 日本語 です';
    final int offset = text.indexOf('語');
    expect(
      await run('p.sentenceAt(${jsonEncode(text)}, $offset)'),
      <String, Object>{'sentence': '日本語 です', 'index': 2},
    );
  }, skip: !hasNode);

  test('落在空白上 / 越界不查', () async {
    expect(await run('p.sentenceAt("a b", 1)'), isNull);
    expect(await run('p.sentenceAt("abc", 5)'), isNull);
  }, skip: !hasNode);

  test('表情等多码元字形算一个', () async {
    const String text = '😀猫です';
    final int offset = text.indexOf('猫');
    expect(await run('p.sentenceAt(${jsonEncode(text)}, $offset).index'), 1);
  }, skip: !hasNode);
}
