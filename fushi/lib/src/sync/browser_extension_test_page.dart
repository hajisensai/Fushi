/// 浏览器扩展「试一试」页：新手引导装完扩展后，用户需要一个**真的能被内容脚本注入的
/// http 页面**来确认插件确实活着——`file://` 在 Chrome 下默认不给扩展权限，本地文件页
/// 因此证明不了任何事。这张页由 app 自己的 yomitan-api server 以 GET 提供
/// （`/onboarding/extension-test`），所以只要 app 在跑就一定打得开，也一定落在扩展的
/// `<all_urls>` 匹配面里。
///
/// 纯函数 + 纯数据，不依赖 Flutter / i18n / server：文案与例句由调用方注入，便于单测。
library;

import 'dart:convert' show htmlEscape;

/// 试用页文案（由 app 侧从 i18n 取好传进来，本层不认识 slang）。
class BrowserExtensionTestPageStrings {
  const BrowserExtensionTestPageStrings({
    required this.title,
    required this.intro,
    required this.probeChecking,
    required this.probeOk,
    required this.probeMissing,
    required this.stepPopupTitle,
    required this.stepPopupBody,
    required this.stepLookupTitle,
    required this.stepLookupBody,
    required this.sampleLabel,
  });

  final String title;
  final String intro;

  /// 自检三态：检测中 / 内容脚本已注入本页 / 一直没注入（扩展没装或没启用）。
  final String probeChecking;
  final String probeOk;
  final String probeMissing;

  final String stepPopupTitle;
  final String stepPopupBody;
  final String stepLookupTitle;
  final String stepLookupBody;
  final String sampleLabel;
}

/// 内容脚本注入后写在根节点上的标记属性（`tools/browser-extension/content.js` 第一行）。
/// 页面脚本轮询它 = 「这一页真的被扩展注入了」的唯一可测判据，不靠用户肉眼判断。
const String kBrowserExtensionContentScriptMarker = 'data-fushi-cs';

/// 试用页在 yomitan-api server 上的路径（GET，免鉴权：纯静态说明页，不含用户数据）。
const String kBrowserExtensionTestPagePath = '/onboarding/extension-test';

/// 生成自包含的试用页（无外链、无内联事件处理器）。
///
/// [sentence] 是练习句（按用户已装词典的词头语言挑，见 onboarding_sample_text.dart），
/// [languageTag] 写进 `lang=`，让浏览器按该语言断词与选字体。
String buildBrowserExtensionTestPage({
  required String sentence,
  required String languageTag,
  required BrowserExtensionTestPageStrings strings,
}) {
  String esc(String value) => htmlEscape.convert(value);
  final String lang = esc(languageTag);
  return '''
<!doctype html>
<html lang="$lang">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(strings.title)}</title>
<style>
  :root { color-scheme: light dark; }
  body {
    margin: 0; padding: 40px 24px;
    font: 15px/1.7 system-ui, "Hiragino Sans", "Yu Gothic UI", sans-serif;
    display: flex; justify-content: center;
    background: #f6f7f6; color: #16201a;
  }
  @media (prefers-color-scheme: dark) { body { background: #101512; color: #e6efe9; } }
  main { width: 100%; max-width: 680px; }
  h1 { font-size: 22px; margin: 0 0 8px; }
  p.intro { margin: 0 0 24px; opacity: 0.8; }
  .probe {
    display: flex; align-items: center; gap: 10px;
    padding: 12px 16px; border-radius: 12px; margin-bottom: 24px;
    border: 1px solid rgba(127, 127, 127, 0.35);
  }
  .probe.ok { border-color: #4caf7d; background: rgba(76, 175, 125, 0.12); }
  .probe.missing { border-color: #d9534f; background: rgba(217, 83, 79, 0.12); }
  .probe .dot { width: 10px; height: 10px; border-radius: 50%; background: #9aa4a0; flex: none; }
  .probe.ok .dot { background: #4caf7d; }
  .probe.missing .dot { background: #d9534f; }
  ol { padding-left: 20px; margin: 0 0 24px; }
  li { margin-bottom: 14px; }
  li b { display: block; }
  li span { opacity: 0.8; }
  .sample-label { font-size: 13px; opacity: 0.7; margin-bottom: 8px; }
  .sample {
    font-size: 28px; line-height: 1.9; padding: 24px;
    border-radius: 16px; border: 1px dashed rgba(127, 127, 127, 0.5);
  }
</style>
</head>
<body>
<main>
  <h1>${esc(strings.title)}</h1>
  <p class="intro">${esc(strings.intro)}</p>
  <div class="probe" id="probe"
       data-marker="${esc(kBrowserExtensionContentScriptMarker)}"
       data-ok="${esc(strings.probeOk)}"
       data-missing="${esc(strings.probeMissing)}"><span class="dot"></span><span id="probe-text">${esc(strings.probeChecking)}</span></div>
  <ol>
    <li><b>${esc(strings.stepPopupTitle)}</b><span>${esc(strings.stepPopupBody)}</span></li>
    <li><b>${esc(strings.stepLookupTitle)}</b><span>${esc(strings.stepLookupBody)}</span></li>
  </ol>
  <div class="sample-label">${esc(strings.sampleLabel)}</div>
  <div class="sample" lang="$lang">${esc(sentence)}</div>
</main>
<script>
// 内容脚本在 document_idle 注入，可能晚于本脚本 —— 轮询到超时才判「没注入」。
// 三态文案走 data-* 属性（生成时已 HTML 转义），脚本里不嵌任何动态字符串。
(function () {
  var box = document.getElementById('probe');
  var text = document.getElementById('probe-text');
  var deadline = Date.now() + 8000;
  function tick() {
    if (document.documentElement.hasAttribute(box.dataset.marker)) {
      box.className = 'probe ok';
      text.textContent = box.dataset.ok;
      return;
    }
    if (Date.now() > deadline) {
      box.className = 'probe missing';
      text.textContent = box.dataset.missing;
      return;
    }
    setTimeout(tick, 300);
  }
  tick();
})();
</script>
</body>
</html>
''';
}
