// BUG-5353 / 反馈 FJXqvneRRp：整面 WebView 卡面（模板带 <script> 的自定义笔记类型）答案面
// 淡入时，翻面经常不自动播单词 / 例句音频（Anki 正常）。
//
// 根因：页面判「哪些发音键看得见」（kSrsCardVisibleSoundsScript）是在换卡同一个任务里、
// 卡片脚本刚跑完就同步取的——此时页面一帧都还没画，模板的入场效果（CSS 关键帧淡入、
// 脚本下一拍加类名触发的 opacity 过渡）正停在第 0 帧 opacity:0，整块发音键被当成「看不见」，
// 宿主自动播放清单为空。
//
// 在真实 headless Chrome 里跑生产外壳 + 带入场淡入的卡面，断言淡入中的发音键被报成可见，
// 静态隐藏（display:none / 定住的 opacity:0）的副本仍不报（HrB0STYm3E 不回退）。
@Tags(<String>['chrome'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/node_runtime.dart';

/// 答案块用 CSS 关键帧从 opacity:0 淡入。
const String _cssFadeBody = '''
<div class="front">集まる</div>
<div class="answer">
  <div class="word">集まる [sound:word.mp3]</div>
  <div class="sent">駅前に人が集まっています。 [sound:sent.mp3]</div>
</div>
''';

const String _cssFadeCss = '''
.answer { animation: fushiTestFadeIn 0.6s ease both; }
@keyframes fushiTestFadeIn { from { opacity: 0; } to { opacity: 1; } }
''';

/// 答案块起始 opacity:0，卡片脚本下一拍加类名、经过渡淡入到 1。
const String _scriptTransitionBody = '''
<div class="front">集まる</div>
<div class="answer">
  <div class="word">集まる [sound:word.mp3]</div>
  <div class="sent">駅前に人が集まっています。 [sound:sent.mp3]</div>
</div>
<script>
  setTimeout(function(){
    document.querySelector('.answer').classList.add('in');
  }, 0);
</script>
''';

const String _scriptTransitionCss = '''
.answer { opacity: 0; transition: opacity 0.5s ease; }
.answer.in { opacity: 1; }
''';

/// 静态隐藏的音频容器副本：不能因为放宽淡入判定而漏进自动播放。
const String _staticHiddenBody = '''
<div class="shown">[sound:shown.mp3]</div>
<div class="none">[sound:none.mp3]</div>
<div class="clear">[sound:clear.mp3]</div>
''';

const String _staticHiddenCss = '''
.none { display: none; }
.clear { opacity: 0; }
''';

SrsCardFaceDocument _doc(String cardId, String body, String css) =>
    SrsCardFaceDocument.of(
      SrsCardFace(
        cardId: cardId,
        showingAnswer: true,
        bodyHtml: body,
        css: css,
        languageCode: 'ja',
        onBridgeKey: (_) {},
        autoplayMedia: true,
      ),
      dark: false,
      background: const Color(0xFFFFFFFF),
      foreground: const Color(0xFF000000),
      accent: const Color(0xFF6750A4),
      onAccent: const Color(0xFFFFFFFF),
      mediaUrlPrefix: 'https://srs.local/media/',
      themedScrollbar: false,
    );

Map<String, String> _page(SrsCardFaceDocument d) => <String, String>{
  'shell': d.shellHtml,
  'calls': d.fullCardScript,
};

void main() {
  final NodeTestRuntime browserRuntime = NodeTestRuntime.probe(
    needsChrome: true,
  );

  test(
    '真实 Chrome：淡入中的答案面发音键报成可见，静态隐藏的副本仍不报',
    () async {
      final String node = browserRuntime.requireNode();
      final Directory temp = Directory.systemTemp.createTempSync('srs-vis-');
      try {
        final File payload = File('${temp.path}/payload.json')
          ..writeAsStringSync(
            jsonEncode(<String, Object?>{
              'cssFade': _page(_doc('fade', _cssFadeBody, _cssFadeCss)),
              'scriptTransition': _page(
                _doc('transition', _scriptTransitionBody, _scriptTransitionCss),
              ),
              'staticHidden': _page(
                _doc('hidden', _staticHiddenBody, _staticHiddenCss),
              ),
            }),
          );
        final ProcessResult result = await Process.run(node, <String>[
          'test/srs/srs_card_visible_sounds_entrance_harness.mjs',
          payload.path,
        ]).timeout(const Duration(seconds: 80));
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(result.stdout, contains('PASS 3 browser cases'));
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: browserRuntime.skipReason,
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
