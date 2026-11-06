/// 卡面「例句翻译模糊、点按显示」（[SrsCardAppearance.blurTranslation]）的**模板卡面**一腿。
///
/// 原生 Fushi 卡片视图（`SrsFushiCardView._translation`）与这里是同一套规则：
/// - 默认模糊、不可取词（悬停 / 点按都不查词）；
/// - 模糊时点一下 = 显示（这一下不查词，也不算点空白）；
/// - 显示后点在字上 = 照常查词，点在这一行的字外空白 = 再次模糊（也不算点空白）；
/// - 换卡 / 翻面复位为模糊（卡面根 innerHTML 重建，状态类随旧节点一起丢掉）；换主题 / 外观保留；
/// - 键盘：这一行可聚焦，Enter / 空格切换（复习页把 Enter / 空格桥给宿主做翻面 / 评分时，
///   与模板里其它可聚焦按钮一样由桥优先）；
/// - 过渡时长与原生 [FushiMotion.short] 一致；系统「减弱动态效果」（`prefers-reduced-motion`）
///   与墨水屏（宿主类 [kSrsCardNoMotionClass]）下瞬间到位。
///
/// **覆盖范围**：只认 Fushi 卡片模板（packages/fushi_anki/templates/fushi_card/back.html）给
/// `SentenceTranslation` 字段包的 `.fc-translation`。外观设置本来就只注入 Fushi 卡片类型
/// （Lapis / Anki 导入 / 用户自建类型拿不到 `fushi-srs-*` 类名，见 srsCardFaceDocumentFor），
/// 用户改过的 Fushi 卡片模板只要保留 `.fc-translation` 也照样生效。样式与脚本都由宿主注入，
/// 不依赖模板版本（整面 WebView 渲染的恰恰是改过模板的卡，样式表可能是旧副本）。
library;

import 'package:fushi/src/utils/components/fushi_motion_tokens.dart'
    show FushiMotion;

/// 开关开着（且显示翻译）时挂在 body / 卡面根节点上的宿主类名。
const String kSrsCardBlurTranslationClass = 'fushi-srs-blur-translation';

/// 已点开的翻译行上的状态类（页内脚本切换）。
const String kSrsCardTranslationRevealedClass =
    'fushi-srs-translation-revealed';

/// 墨水屏主题下挂在卡面上的宿主类名：卡面注入的过渡一律瞬间到位（与 fushiMotionDuration 同口径）。
const String kSrsCardNoMotionClass = 'fushi-srs-no-motion';

/// 模板里例句翻译的选择器（Fushi 卡片模板 back.html）。
const String kSrsCardTranslationSelector = '.fc-translation';

/// 模糊半径：与原生 `ImageFiltered` 的 sigma 6 对齐。`text-shadow` 的模糊半径是标准差的两倍。
const int _kBlurShadowPx = 12;

/// 注入到外观样式里的规则（只在开关开着时下发）。只模糊字形（`color: transparent` +
/// 同色 `text-shadow`），不模糊模板给这一行画的分隔线 / 底色，与原生只模糊文字一致。
final String kSrsCardTranslationBlurCss = () {
  const String on =
      '.$kSrsCardBlurTranslationClass $kSrsCardTranslationSelector';
  const String blurred = '$on:not(.$kSrsCardTranslationRevealedClass)';
  final int ms = FushiMotion.short.inMilliseconds;
  return '$on,$on *{transition:color ${ms}ms cubic-bezier(0.2,0,0,1),'
      'text-shadow ${ms}ms cubic-bezier(0.2,0,0,1);}'
      '$blurred,$blurred *{color:transparent!important;'
      'text-shadow:0 0 ${_kBlurShadowPx}px '
      'var(--fc-fg-muted,var(--fushi-srs-fg-muted,#808080))!important;'
      '-webkit-user-select:none;user-select:none;}'
      // 只在模糊时是「按钮」手势：显示后页内取词脚本要能在这行上照常取词（它跳过
      // cursor:pointer / role=button 的元素）。
      '$blurred{cursor:pointer;}'
      '$on:focus-visible{outline:2px solid var(--fushi-srs-accent,#3b82f6);'
      'outline-offset:2px;border-radius:2px;}'
      '@media (prefers-reduced-motion: reduce){$on,$on *{transition:none!important;}}'
      '.$kSrsCardNoMotionClass $kSrsCardTranslationSelector,'
      '.$kSrsCardNoMotionClass $kSrsCardTranslationSelector *{transition:none!important;}';
}();

/// 页内脚本（随主题下发，幂等）。
///
/// - `window.__fushiSrsTranslationBlur()`：外壳在换卡（卡片脚本与钩子跑完后）与换主题后调用，
///   按 body 上有没有 [kSrsCardBlurTranslationClass] 给翻译行加 / 撤可聚焦与无障碍属性。
/// - `window.__fushiSrsTranslationBlocksLookup(x, y)`：这个点落在**模糊中**的翻译上时为 true；
///   页内取词脚本（点按 / 悬停）与宿主侧取词（弹窗 barrier 上的点按、macOS 宿主悬停）据此不取词。
/// - 点按识别挂在 window **捕获**阶段（DOM 派发的第一站，先于取词脚本挂在 document 冒泡阶段的
///   监听）：这一下归翻译（显示 / 再模糊）时写 `window.__fushiSrsTapConsumed = true`，取词脚本
///   同一次抬起读到就不取词、不报点空白。位移门与取词脚本相同（12px）。
const String kSrsCardTranslationBlurScript =
    '''
(function(){
  if (window.__fushiSrsTranslationBlur) return;
  var ON = '$kSrsCardBlurTranslationClass';
  var SHOWN = '$kSrsCardTranslationRevealedClass';
  var SEL = '$kSrsCardTranslationSelector';
  var MARK = 'data-fushi-blur-translation';
  function active(){ return !!document.body && document.body.classList.contains(ON); }
  function lineAt(x, y){
    if (!active()) return null;
    var el = document.elementFromPoint(x, y);
    return el && el.closest ? el.closest(SEL) : null;
  }
  function shown(tr){ return tr.classList.contains(SHOWN); }
  function decorate(tr){
    var open = shown(tr);
    tr.setAttribute(MARK, '');
    if (tr.tabIndex < 0) tr.tabIndex = 0;
    tr.setAttribute('aria-expanded', open ? 'true' : 'false');
    // 模糊时整行是按钮（取词脚本也据此跳过它）；显示后是可取词的正文。
    if (open) tr.removeAttribute('role'); else tr.setAttribute('role', 'button');
  }
  function undecorate(tr){
    tr.removeAttribute(MARK);
    tr.removeAttribute('tabindex');
    tr.removeAttribute('aria-expanded');
    tr.removeAttribute('role');
    tr.classList.remove(SHOWN);
  }
  function set(tr, open){
    if (open) tr.classList.add(SHOWN); else tr.classList.remove(SHOWN);
    decorate(tr);
  }
  // 点在字形上（任一非空白文字节点的行盒片段内），而不是这一行的字外空白。
  function onText(tr, x, y){
    var walker = document.createTreeWalker(tr, NodeFilter.SHOW_TEXT);
    var range = document.createRange();
    for (var n = walker.nextNode(); n; n = walker.nextNode()) {
      if (!/\\S/.test(n.nodeValue)) continue;
      range.selectNodeContents(n);
      var rects = range.getClientRects();
      for (var i = 0; i < rects.length; i++) {
        var r = rects[i];
        if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) return true;
      }
    }
    return false;
  }
  // 一次点按：true = 这一下归翻译（显示 / 再模糊），取词不再处理。
  function tap(x, y){
    var tr = lineAt(x, y);
    if (!tr) return false;
    if (!shown(tr)) { set(tr, true); return true; }
    if (onText(tr, x, y)) return false;
    set(tr, false);
    return true;
  }
  window.__fushiSrsTranslationBlur = function(){
    var on = active();
    var list = document.querySelectorAll(SEL);
    for (var i = 0; i < list.length; i++) {
      if (on) decorate(list[i]);
      else if (list[i].hasAttribute(MARK)) undecorate(list[i]);
    }
  };
  window.__fushiSrsTranslationBlocksLookup = function(x, y){
    var tr = lineAt(x, y);
    return !!tr && !shown(tr);
  };
  window.__fushiSrsTapConsumed = false;
  var sx = 0, sy = 0, moved = false, has = false;
  function start(x, y){
    sx = x; sy = y; moved = false; has = true;
    window.__fushiSrsTapConsumed = false;
  }
  function move(x, y){
    if (!has) return;
    if (Math.abs(x - sx) > 12 || Math.abs(y - sy) > 12) moved = true;
  }
  function end(x, y){
    if (!has) return;
    has = false;
    if (moved) return;
    var sel = window.getSelection ? window.getSelection() : null;
    if (sel && !sel.isCollapsed && String(sel).length > 0) return;
    window.__fushiSrsTapConsumed = tap(x, y);
  }
  var opts = {capture: true, passive: true};
  window.addEventListener('touchstart', function(e){
    if (e.touches.length !== 1) { has = false; return; }
    var t = e.touches[0]; start(t.clientX, t.clientY);
  }, opts);
  window.addEventListener('touchmove', function(e){
    var t = e.touches[0]; if (t) move(t.clientX, t.clientY);
  }, opts);
  window.addEventListener('touchend', function(e){
    var t = e.changedTouches[0]; if (t) end(t.clientX, t.clientY);
  }, opts);
  window.addEventListener('touchcancel', function(){ has = false; }, opts);
  window.addEventListener('pointerdown', function(e){
    if (e.pointerType === 'touch' || e.button !== 0) return;
    start(e.clientX, e.clientY);
  }, opts);
  window.addEventListener('pointermove', function(e){
    if (e.pointerType === 'touch') return;
    move(e.clientX, e.clientY);
  }, opts);
  window.addEventListener('pointerup', function(e){
    if (e.pointerType === 'touch' || e.button !== 0) return;
    end(e.clientX, e.clientY);
  }, opts);
  document.addEventListener('keydown', function(e){
    if (e.defaultPrevented || e.isComposing || !active()) return;
    if (e.key !== 'Enter' && e.key !== ' ') return;
    var tr = e.target;
    if (!tr || !tr.matches || !tr.matches(SEL)) return;
    e.preventDefault();
    set(tr, !shown(tr));
  });
})();
''';
