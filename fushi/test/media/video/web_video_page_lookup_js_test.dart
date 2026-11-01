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

  // 极简假 DOM：元素 {tagName, display, children}，文本 {data}；TreeWalker 按文档序
  // 只吐文本节点（与 NodeFilter.SHOW_TEXT 一致），getComputedStyle 读 display。
  const String fakeDom = r'''
function E(tag, display, children) {
  const e = { nodeType: 1, tagName: tag, display: display, children: children, parentElement: null };
  children.forEach((c) => { c.parentElement = e; });
  return e;
}
function T(data) { return { nodeType: 3, data: data, parentElement: null }; }
globalThis.getComputedStyle = (el) => ({ display: el.display });
document.body = E('BODY', 'block', []);
document.createTreeWalker = (root) => {
  const out = [];
  (function walk(n) { if (n.nodeType === 3) out.push(n); else n.children.forEach(walk); })(root);
  let i = 0;
  return { nextNode: () => (i < out.length ? out[i++] : null) };
};
const hit = T('字');
const rtHit = T('かん');
const block = E('DIV', 'block', [
  T('今日は'),
  E('RUBY', 'ruby', [T('漢'), E('RT', 'ruby-text', [rtHit]), hit, E('RT', 'ruby-text', [T('じ')])]),
  T('を読む。次の文。'),
]);
block.parentElement = document.body;
const d = window.__fushiPageLookup._dom;
''';

  test('ruby 注音不进取词文本：句子跨 <ruby> 拼正文、剔除 <rt>（反馈 flt5vvT-5X）', () async {
    final Object? flat = await run(
      '(function(){$fakeDom return d.blockText(hit, 0); })()',
    );
    expect(flat, <String, Object>{'text': '今日は漢字を読む。次の文。', 'offset': 4});
    expect(
      await run(
        '(function(){$fakeDom const f = d.blockText(hit, 0); '
        'return p.sentenceAt(f.text, f.offset); })()',
      ),
      <String, Object>{'sentence': '今日は漢字を読む。', 'index': 4},
    );
  }, skip: !hasNode);

  test('光标落在 <rt> 注音上不查', () async {
    expect(
      await run('(function(){$fakeDom return d.blockText(rtHit, 0); })()'),
      isNull,
    );
  }, skip: !hasNode);

  test('表情等多码元字形算一个', () async {
    const String text = '😀猫です';
    final int offset = text.indexOf('猫');
    expect(await run('p.sentenceAt(${jsonEncode(text)}, $offset).index'), 1);
  }, skip: !hasNode);
}
