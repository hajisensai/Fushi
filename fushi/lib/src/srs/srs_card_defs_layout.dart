/// 复习页混合渲染的释义页排版：主词典通栏在上、其他词典分列（与查词弹窗同一套最短列
/// 瀑布流），展开规则也与查词弹窗同一套（列数 / 自动展开行数 / 折叠词典显示 / 词典管理里
/// 逐本的三态：显式展开 > 显式折叠 > 继承）。
///
/// 只作用于 Fushi 卡片混合渲染里单独进 WebView 的释义页（根节点 `.fc-defs-only`）；Anki
/// 模板本身不动——原生渲染按「笔记类型 CSS 与内置模板逐字一致」判定，改模板会让库里已有
/// 的 Fushi 卡片退回整面 WebView。模板脚本先把释义收成 `details.fc-dict` 分组
/// （`groupGlossary`），这里在它之后重排。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/popup_settings_injection.dart'
    show popupCollapsedDictionaryNames, popupExpandedDictionaryNames;

/// 释义页的排版参数（来自查词设置）。
@immutable
class SrsDefsLayoutConfig {
  const SrsDefsLayoutConfig({
    required this.columns,
    required this.autoExpandRows,
    required this.collapseDictionaries,
    required this.collapsedDictionaryNames,
    this.expandedDictionaryNames = const <String>[],
    required this.mainLabel,
    required this.othersLabel,
    required this.uiLanguageTag,
  });

  /// 其他词典的最大列数（查词「词典最大列数」）；栏宽不够每列 [kSrsDefsMinColumnWidth]
  /// 时自动少列。
  final int columns;

  /// 自动展开的行数（查词「自动展开行数」）：主词典占第一行，其余行按列数展开其他词典。
  final int autoExpandRows;

  /// 查词「折叠词典显示」：关 = 其他词典全部展开。
  final bool collapseDictionaries;

  /// 词典管理里逐本设成折叠的词典：始终收起，优先于自动展开（与 popup.js BUG-1264 同序）。
  final List<String> collapsedDictionaryNames;

  /// 词典管理里逐本设成展开的词典：始终展开，优先级最高——压过逐本折叠、自动展开行数与
  /// 全局折叠开关（与 popup.js `expandedDictionaryNames`、BUG-2158 同序）。
  final List<String> expandedDictionaryNames;

  final String mainLabel;
  final String othersLabel;

  /// 界面语言（BCP 47）：标题 / 标记是界面文字，标上 `lang` 才走模板里对应语言的字体链
  /// （否则落在日文字体链上，简体「词」等字回落到别的字体、粗细对不上）。
  final String uiLanguageTag;
}

/// 当前查词设置生成的释义页宿主 CSS（字符串判等：设置没变就不重建卡面）。
///
/// AppModel 还没初始化完（偏好 / 词典仓库未就绪）时按默认参数，与
/// `AppModel.srsCardAppearance` 在偏好缺席时取默认外观同一约定。
final Provider<String> srsDefsLayoutCssProvider = Provider<String>(
  (Ref ref) => ref.watch(
    appProvider.select((AppModel app) {
      final bool ready = app.isInitialised;
      return srsDefsLayoutCss(
        SrsDefsLayoutConfig(
          columns: ready ? app.popupDictionaryColumns : 1,
          autoExpandRows: ready ? app.popupAutoExpandDictionaries : 1,
          collapseDictionaries: !ready || app.collapseDictionaries,
          collapsedDictionaryNames: ready
              ? popupCollapsedDictionaryNames(app)
              : const <String>[],
          expandedDictionaryNames: ready
              ? popupExpandedDictionaryNames(app)
              : const <String>[],
          mainLabel: t.srs_card_label_main_dictionary,
          othersLabel: t.srs_card_label_other_dictionaries,
          uiLanguageTag: LocaleSettings.currentLocale.languageTag,
        ),
      );
    }),
  ),
);

/// 每列最小宽度（CSS px），与查词弹窗 `DICT_COLUMN_MIN_WIDTH` 同值（触屏同样放宽到 1.5 倍）：
/// 窄于它就少一列。
const int kSrsDefsMinColumnWidth = 170;

/// CSS 字符串字面量（转义反斜杠、引号与换行）。
String _cssString(String s) =>
    '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll('\n', r'\A ')}"';

/// 释义页的宿主 CSS：参数变量 + 分列 / 主词典标记 / 分区标题样式。
String srsDefsLayoutCss(SrsDefsLayoutConfig c) {
  final int cols = c.columns.clamp(1, 4);
  final StringBuffer out = StringBuffer()
    ..write(':root{--fushi-srs-dict-cols:$cols;')
    ..write('--fushi-srs-dict-rows:${c.autoExpandRows.clamp(0, 6)};')
    ..write('--fushi-srs-dict-collapse:${c.collapseDictionaries ? 1 : 0};')
    ..write('--fushi-srs-label-main:${_cssString(c.mainLabel)};')
    ..write('--fushi-srs-label-others:${_cssString(c.othersLabel)};')
    ..write('--fushi-srs-ui-lang:${_cssString(c.uiLanguageTag)};}')
    // 其他词典：分区标题（不可折叠），下面分列。
    ..write(
      '.fushi-srs-defs-grid .fc-more>summary{pointer-events:none;'
      'min-height:0;padding:4px 4px 0;border:0;background:none;}',
    )
    ..write('.fushi-srs-defs-grid .fc-more>summary::after{display:none;}')
    ..write(
      '.fushi-srs-defs-grid .fc-more-title::before'
      '{content:var(--fushi-srs-label-others);}',
    )
    ..write(
      '.fushi-srs-defs-grid .fc-more{display:flex;flex-direction:column;gap:8px;}',
    )
    ..write('.fushi-srs-more--lead>summary{display:none;}')
    // 其他词典的多列排法与查词弹窗同一套（popup.js layoutMasonry）：脚本按顺序把每本放进
    // 当前最短的一列、绝对定位；一列（或脚本没跑）时按模板原样纵向分段堆叠。
    ..write(
      '.fushi-srs-defs-grid .fc-gloss--all .fc-dicts[data-fushi-srs-cols]'
      '{display:block;position:relative;}',
    )
    ..write(
      '.fushi-srs-defs-grid .fc-gloss--all .fc-dicts[data-fushi-srs-cols]>.fc-dict'
      '{position:absolute;left:0;top:0;box-sizing:border-box;'
      'border-radius:var(--fc-radius);}',
    )
    // 主词典标记。
    ..write(
      '.fushi-srs-main-badge{flex:0 0 auto;padding:1px 8px;border-radius:999px;'
      'background:var(--fc-accent-container);color:var(--fc-on-accent-container);'
      'font-size:11px;line-height:16px;font-weight:600;}',
    )
    ..write(
      '.fushi-srs-main-badge::before{content:var(--fushi-srs-label-main);}',
    );
  for (final String name in c.collapsedDictionaryNames) {
    out.write(
      '.fc-dict[data-fc-dict=${_cssString(name)}]{--fushi-srs-dict-folded:1;}',
    );
  }
  for (final String name in c.expandedDictionaryNames) {
    out.write(
      '.fc-dict[data-fc-dict=${_cssString(name)}]{--fushi-srs-dict-unfolded:1;}',
    );
  }
  return out.toString();
}

/// 释义页的宿主脚本（定义 `window.__fushiSrsHostLayout`，外壳在卡片脚本跑完、换主题后调）。
/// 内容固定；参数从 [srsDefsLayoutCss] 的 CSS 变量读。只在参数 / 列数 / 模板折叠状态变了
/// 时重排展开状态，用户手动开合过的不被覆盖；每次都按当前高度重新分列。
///
/// 模板脚本（back.html `applyLayout`）在布局键（全部释义默认展开 × 宽 / 窄）变化时会把
/// 分组一律重设开合；它与本脚本都挂在 window `resize` 上，而本脚本随主题先于卡片脚本执行、
/// 监听器先注册先跑。所以排版前先让模板把自己的布局键算到最新（`__fcApplyLayout`，键没变
/// 时它不动开合），再读释义页根节点（`.fc-back`）上的 `__fcLayoutKey` 并入本脚本的键：
/// 无论两边谁先跑，模板改过开合之后本脚本一定按自己的规则重排一次。
///
/// 高度监听是全页单例（`window.__fushiSrsDefsObserver`）：脚本重新执行时先断开旧的，
/// 每次排版先 `disconnect` 再只观察当前卡的分组，换卡后旧节点不再被持有。
const String kSrsDefsLayoutScript = r'''
(function(){
  // 与 popup.js 同值：列间距 / 收起卡下方的行距 / 每列最小宽度（kSrsDefsMinColumnWidth）。
  var GAP = 6, COLLAPSED_GAP = 4, MIN_COL = 170;
  // 主题变化会重跑本脚本：断开上一次留下的观察器（它的回调绑着旧闭包）。
  if (window.__fushiSrsDefsObserver) window.__fushiSrsDefsObserver.disconnect();
  window.__fushiSrsDefsObserver = null;
  function observer(){
    if (typeof ResizeObserver !== 'function') return null;
    if (!window.__fushiSrsDefsObserver) {
      // 开合 / 图片载入改变卡片高度时重排（同 popup.js masonryObserver：高度没变不重排）。
      window.__fushiSrsDefsObserver = new ResizeObserver(function(entries){
        for (var e = 0; e < entries.length; e++) {
          var t = entries[e].target;
          // 分列容器自己的宽度变了（排版后内容变高 / 变矮让纵向滚动条出现或消失，
          // 栏宽随之差一条滚动条，但这不会触发 window resize）：卡片宽度是排版时量出来的
          // 像素值，不重排就和通栏的主词典差一条滚动条宽（右缘对不齐）。
          if (t.__fushiSrsWidth !== undefined) {
            if (t.__fushiSrsWidth !== t.clientWidth) {
              if (window.__fushiSrsHostLayout) window.__fushiSrsHostLayout();
              return;
            }
            continue;
          }
          if (t.__fushiSrsHeight !== t.offsetHeight) {
            if (window.__fushiSrsHostLayout) window.__fushiSrsHostLayout();
            return;
          }
        }
      });
    }
    return window.__fushiSrsDefsObserver;
  }
  function coarse(){
    try { return !!(window.matchMedia && window.matchMedia('(pointer: coarse)').matches); }
    catch (e) { return false; }
  }
  // 有效列数 = min(设置列数, 栏宽装得下的列数, 本数)，同 popup.js effectiveDictColumns +
  // layoutMasonry 的 Math.min(configured, items.length)。
  function columnsFor(list, configured, count){
    var floor = coarse() ? MIN_COL * 1.5 : MIN_COL;
    var fit = Math.max(1, Math.floor(list.clientWidth / floor));
    return Math.max(1, Math.min(configured, fit, count));
  }
  function reset(list, items){
    delete list.dataset.fushiSrsCols;
    list.style.height = '';
    list.__fushiSrsWidth = list.clientWidth;
    for (var i = 0; i < items.length; i++) {
      items[i].style.width = '';
      items[i].style.transform = '';
      // 记下高度：否则观察器把每次回调都当成高度变了，一列时无限重排。
      items[i].__fushiSrsHeight = items[i].offsetHeight;
    }
  }
  // 最短列打包（popup.js layoutMasonry 相 2–4）：按顺序把每本放进当前最短的一列。
  // lead = 没有主释义时第一本通栏当主词典，其余从它下方开始分列。
  function pack(list, items, cols, lead){
    if (cols <= 1) { reset(list, items); return; }
    list.dataset.fushiSrsCols = String(cols);
    var full = list.clientWidth;
    list.__fushiSrsWidth = full;
    var width = (full - (cols - 1) * GAP) / cols;
    var start = 0, top = 0;
    if (lead && items.length) {
      items[0].style.width = full + 'px';
      start = 1;
    }
    for (var i = start; i < items.length; i++) items[i].style.width = width + 'px';
    var heights = [];
    for (var j = 0; j < items.length; j++) heights.push(items[j].offsetHeight);
    if (start) {
      items[0].style.transform = 'translate(0px, 0px)';
      items[0].__fushiSrsHeight = heights[0];
      top = heights[0] + (items[0].open ? GAP : COLLAPSED_GAP);
    }
    var col = [], last = [];
    for (var c = 0; c < cols; c++) { col.push(top); last.push(0); }
    for (var k = start; k < items.length; k++) {
      var best = 0;
      for (var m = 1; m < cols; m++) if (col[m] < col[best]) best = m;
      items[k].style.transform = 'translate(' + best * (width + GAP) + 'px, ' + col[best] + 'px)';
      items[k].__fushiSrsHeight = heights[k];
      var gap = items[k].open ? GAP : COLLAPSED_GAP;
      col[best] += heights[k] + gap;
      last[best] = gap;
    }
    var bottom = 0;
    for (var n = 0; n < cols; n++) bottom = Math.max(bottom, col[n] - last[n]);
    list.style.height = bottom + 'px';
  }
  function apply(){
    var obs = observer();
    if (obs) obs.disconnect();
    var root = document.getElementById('fushi-card-root');
    var fc = root && root.querySelector('.fc-defs-only');
    if (!fc) return;
    // 先让模板把布局键与它的开合更新到最新（键没变时是空操作），见上方说明。
    if (typeof window.__fcApplyLayout === 'function') {
      try { window.__fcApplyLayout(); } catch (err) { if (window.console) console.error(err); }
    }
    var cs = getComputedStyle(document.documentElement);
    function num(name, d){
      var v = parseFloat(cs.getPropertyValue(name));
      return isNaN(v) ? d : v;
    }
    var rows = num('--fushi-srs-dict-rows', 1);
    var configured = num('--fushi-srs-dict-cols', 1);
    var lang = cs.getPropertyValue('--fushi-srs-ui-lang').trim().replace(/^"|"$/g, '');
    var collapse = num('--fushi-srs-dict-collapse', 1) > 0;
    fc.classList.add('fushi-srs-defs-grid');
    var main = fc.querySelector('.fc-gloss--main');
    if (main) {
      var label = main.querySelector('.fc-dict-label');
      if (label && !label.querySelector('.fushi-srs-main-badge')) {
        var badge = document.createElement('span');
        badge.className = 'fushi-srs-main-badge';
        if (lang) badge.lang = lang;
        label.appendChild(badge);
      }
    }
    var more = fc.querySelector('.fc-more');
    if (!more) return;
    more.classList.toggle('fushi-srs-more--lead', !main);
    var title = more.querySelector('.fc-more-title');
    if (title && lang) title.lang = lang;
    if (!more.open) more.open = true;
    var list = more.querySelector('.fc-dicts');
    if (!list) return;
    var groups = list.querySelectorAll(':scope > .fc-dict');
    var lead = !main && groups.length > 1;
    var cols = columnsFor(list, configured, groups.length - (lead ? 1 : 0));
    // 逐本三态（u = 显式展开、f = 显式折叠、- = 继承），并入键：词典管理里改了逐本设置也重排。
    var states = '';
    for (var s = 0; s < groups.length; s++) {
      var gs = getComputedStyle(groups[s]);
      states += gs.getPropertyValue('--fushi-srs-dict-unfolded').trim() === '1' ? 'u'
        : gs.getPropertyValue('--fushi-srs-dict-folded').trim() === '1' ? 'f' : '-';
    }
    var key = rows + '|' + collapse + '|' + cols + '|' + states + '|' + (fc.__fcLayoutKey || '');
    if (more.__fushiSrsLayoutKey !== key) {
      more.__fushiSrsLayoutKey = key;
      // 自动展开按「行」计：主词典占第一行；没有主释义时第一本（通栏）同样占一行。
      var budget = !collapse ? Infinity : main ? (rows - 1) * cols : 1 + (rows - 1) * cols;
      // 与 popup.js createGlossarySection 同序：显式展开 > 显式折叠 > 自动展开 / 全局开关。
      for (var i = 0; i < groups.length; i++) {
        groups[i].open = states[i] === 'u' || (states[i] !== 'f' && i < budget);
      }
    }
    pack(list, groups, cols, lead);
    if (obs) {
      for (var o = 0; o < groups.length; o++) obs.observe(groups[o]);
      obs.observe(list);
    }
  }
  window.__fushiSrsHostLayout = apply;
  if (!window.__fushiSrsHostLayoutListen) {
    window.__fushiSrsHostLayoutListen = true;
    window.addEventListener('resize', function(){
      if (window.__fushiSrsHostLayout) window.__fushiSrsHostLayout();
    });
  }
})();
''';
