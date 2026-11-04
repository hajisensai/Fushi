// 反馈 uCPhpeCM35：eggrolls 卡组复习时不播单词音频（编辑笔记页能播）。
//
// 根因：导入的 Anki 模板按 Anki reviewer 的 DOM 契约写脚本，Fushi 卡面外壳不满足——
// - eggrolls 背面把单词音频放在 `#qa` 直属的 `<div class="VocabAudio !hidden">` 里，由
//   `audioStylePatch()` 按 `#qa > .VocabAudio` 挪进标题行并去掉 `!hidden`；外壳没有 `#qa`，
//   正文还被 `<div lang>` 包了一层，挪不动 → 单词音频一直 display:none，按 BUG-3983 的
//   「只播看得见的」不进自动播放，卡面上也没有键可点；
// - `forcePlayback()` 找 `.VocabAudio .replay-button` 去点（Anki 给 `[sound:]` 的类名），
//   Fushi 的播放键只有 `fushi-srs-sound`，找不到。
//
// 在真实 headless Chrome 里跑生产外壳 + 真实模板里的音频脚本（摘自用户库的
// eggrolls-JLPT10k-v3 背面，原样），断言契约成立。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/node_runtime.dart';

/// eggrolls-JLPT10k-v3「日-中」背面渲染后的音频相关骨架（`{{FrontSide}}` 已展开），
/// 脚本函数原样摘自模板。
const String _eggrollsBack = '''
<main id="FrontSide" class="CardSide">
  <header class="Question">
    <h1 class="VocabKanji"><span lang="ja">単語</span></h1>
    <div class="VocabAudio"></div>
  </header>
  <ul class="SentenceList"><li class="Sentence"><h3 class="SentKanji">例文。</h3></li></ul>
</main>
<div class="VocabAudio !hidden">[sound:word.mp3]</div>
<main id="BackSide" class="CardSide">
  <ul class="SentenceList">
    <li class="Sentence">
      <div class="SentGroup"><h3 class="SentFurigana">例文。</h3></div>
      <div class="SentAudio">[sound:sent.mp3]</div>
    </li>
  </ul>
</main>
<script>
  function CONFIG() { return { settings: { playback: 'force' } } }
  function forcePlayback() {
    if (CONFIG().settings.playback !== 'force') return
    const el = document.querySelector('.VocabAudio .replay-button')
    if (el) el.click()
  }
  function hideFrontElements() {
    document.querySelector('#FrontSide ul').style.display = 'none'
  }
  function audioStylePatch() {
    const target = document.querySelector('#FrontSide .VocabAudio')
    const source = document.querySelector('#qa > .VocabAudio')
    if (source && target && !target.innerHTML.trim()) {
      source.classList.remove('!hidden')
      target.replaceWith(source)
    }
  }
  audioStylePatch()
  hideFrontElements()
  typeof onShownHook !== 'undefined' ? onShownHook.push(forcePlayback) : forcePlayback()
</script>
''';

const String _eggrollsCss = r'''
.\!hidden { display: none !important; }
.VocabAudio, .SentAudio { display: flex; justify-content: center; align-items: center; }
.SentAudio:empty { display: none; }
''';

SrsCardFaceDocument _doc({required bool autoplay}) => SrsCardFaceDocument.of(
  SrsCardFace(
    cardId: 'egg',
    showingAnswer: true,
    bodyHtml: _eggrollsBack,
    css: _eggrollsCss,
    languageCode: 'ja',
    onBridgeKey: (_) {},
    autoplayMedia: autoplay,
  ),
  dark: false,
  background: const Color(0xFFFFFFFF),
  foreground: const Color(0xFF000000),
  accent: const Color(0xFF6750A4),
  onAccent: const Color(0xFFFFFFFF),
  mediaUrlPrefix: 'https://srs.local/media/',
  themedScrollbar: false,
);

void main() {
  final NodeTestRuntime browserRuntime = NodeTestRuntime.probe(
    needsChrome: true,
  );

  test('正文是外壳 #qa 的直接子节点、lang 挂在 #qa 上；[sound:] 键带 replay-button', () {
    final SrsCardFaceDocument d = _doc(autoplay: true);
    expect(d.shellHtml, contains('<div id="qa"></div>'));
    expect(d.bodyHtml, isNot(startsWith('<div lang=')));
    expect(d.lang, 'ja');
    expect(d.bodyHtml, contains('replay-button soundLink'));
  });

  test(
    '真实 Chrome：eggrolls 单词音频挪进标题行、上报可见、强制播放点得到；句子键可点',
    () async {
      final String node = browserRuntime.requireNode();
      final SrsCardFaceDocument on = _doc(autoplay: true);
      final SrsCardFaceDocument off = _doc(autoplay: false);
      final Directory temp = Directory.systemTemp.createTempSync('srs-qa-');
      try {
        final File payload = File('${temp.path}/payload.json')
          ..writeAsStringSync(
            jsonEncode(<String, Object?>{
              'on': <String, String>{
                'shell': on.shellHtml,
                'calls': on.fullCardScript,
              },
              'off': <String, String>{
                'shell': off.shellHtml,
                'calls': off.fullCardScript,
              },
            }),
          );
        final ProcessResult result = await Process.run(node, <String>[
          'test/srs/srs_card_anki_dom_contract_harness.mjs',
          payload.path,
        ]).timeout(const Duration(seconds: 80));
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(result.stdout, contains('PASS 2 browser cases'));
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: browserRuntime.skipReason,
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
