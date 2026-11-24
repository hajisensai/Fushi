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
//
// HBK-AUDIT-006：只有会把 opacity 带到大于 0 的动画才算淡入。关键帧 opacity 始终为 0、只拿
// 动画移动隐藏容器的，以及反向 / 交替后不再回到可见值的动画，里面的发音键不报；真正会到达
// 可见值的反向 / 交替动画照报。（步进缓动把当前值钉在 0，判定时刻确定。）
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

/// 隐藏的发音容器只被动画移动、关键帧 opacity 始终为 0（无限循环 / 有限 + fill forwards）。
const String _zeroOpacityMotionBody = '''
<div class="shown">[sound:shown.mp3]</div>
<div class="loop">[sound:hidden_loop.mp3]</div>
<div class="held">[sound:hidden_held.mp3]</div>
''';

const String _zeroOpacityMotionCss = '''
.loop { animation: fushiTestSlide 3s linear infinite; }
.held { animation: fushiTestSlide 10s linear forwards; }
@keyframes fushiTestSlide {
  from { opacity: 0; transform: translateX(0); }
  to { opacity: 0; transform: translateX(40px); }
}
''';

/// 反向播放：一条朝可见值走（报），一条朝 opacity:0 那一端走、之后不再可见（不报）。
const String _reverseBody = '''
<div class="toward">[sound:reverse_visible.mp3]</div>
<div class="away">[sound:reverse_hidden.mp3]</div>
''';

const String _reverseCss = '''
.toward { animation: fushiTestRevIn 10s -2s linear reverse both; }
@keyframes fushiTestRevIn {
  0% { opacity: 1; animation-timing-function: step-start; }
  100% { opacity: 0; }
}
.away { animation: fushiTestRevOut 10s -2s linear reverse both; }
@keyframes fushiTestRevOut {
  0% { opacity: 0; animation-timing-function: step-end; }
  100% { opacity: 1; }
}
''';

/// 交替播放：无限交替会回到可见值（报）；两轮交替、正处于最后一轮回程（不报）。
const String _alternateBody = '''
<div class="loop">[sound:alternate_visible.mp3]</div>
<div class="last">[sound:alternate_hidden.mp3]</div>
''';

const String _alternateCss = '''
.loop { animation: fushiTestAlt 10s -2s linear infinite alternate; }
.last { animation: fushiTestAlt 10s -12s linear 2 alternate both; }
@keyframes fushiTestAlt {
  0% { opacity: 0; animation-timing-function: step-end; }
  100% { opacity: 1; }
}
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
    '真实 Chrome：淡入中的答案面发音键报成可见，静态隐藏 / 不会变可见的动画里的副本不报',
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
              'zeroOpacityMotion': _page(
                _doc('motion', _zeroOpacityMotionBody, _zeroOpacityMotionCss),
              ),
              'reverse': _page(_doc('reverse', _reverseBody, _reverseCss)),
              'alternate': _page(
                _doc('alternate', _alternateBody, _alternateCss),
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
        expect(result.stdout, contains('PASS 6 browser cases'));
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: browserRuntime.skipReason,
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
