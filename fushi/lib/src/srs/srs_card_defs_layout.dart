/// 复习页混合渲染的释义页排版：主词典通栏在上、其他词典分列（与查词弹窗同一套最短列
/// 瀑布流），展开规则也与查词弹窗同一套（列数 / 自动展开行数 / 折叠词典显示 / 词典管理里
/// 逐本的三态：显式展开 > 显式折叠 > 继承）；卡面外观「默认展开全部释义」开着时按
/// 「折叠词典显示」关处理（逐本折叠的照样收起）。「其他词典」标题行尾有一个全部展开 /
/// 全部收起按钮；主词典标题行尾有一个收起 / 展开主词典的按钮（释义很长时一键收起，后面的
/// 词典马上露出来）。两个按钮的开合都只在这张卡上有效、不写偏好——与「其他词典」逐本开合、
/// 全部展开 / 收起同一约定（换卡按设置重排）；要长期收起某本词典用词典管理里的逐本折叠。
///
/// 卡面外观里的「释义显示的词典」（[SrsCardAppearance.glossaryDictLimit]，对齐 Lapis 的
/// `{glossary-first-N}`）、释义对齐 / 首行缩进也在这里生效（[srsDefsAppearanceCss]）：
/// 只改显示，字段里的词典一本不少。
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
import 'package:fushi/src/srs/srs_card_appearance.dart';

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
    required this.expandAllLabel,
    required this.collapseAllLabel,
    required this.mainCollapseLabel,
    required this.mainExpandLabel,
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

  /// 「其他词典」行尾全部展开 / 全部收起按钮的无障碍名与提示。
  final String expandAllLabel;
  final String collapseAllLabel;

  /// 主词典标题行尾收起 / 展开按钮的无障碍名与提示。
  final String mainCollapseLabel;
  final String mainExpandLabel;

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
          expandAllLabel: t.srs_card_defs_expand_all,
          collapseAllLabel: t.srs_card_defs_collapse_all,
          mainCollapseLabel: t.srs_card_defs_main_collapse,
          mainExpandLabel: t.srs_card_defs_main_expand,
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
    ..write('--fushi-srs-label-expand-all:${_cssString(c.expandAllLabel)};')
    ..write('--fushi-srs-label-collapse-all:${_cssString(c.collapseAllLabel)};')
    ..write(
      '--fushi-srs-label-main-collapse:${_cssString(c.mainCollapseLabel)};',
    )
    ..write('--fushi-srs-label-main-expand:${_cssString(c.mainExpandLabel)};')
    ..write('--fushi-srs-ui-lang:${_cssString(c.uiLanguageTag)};}')
    // 其他词典：分区标题（不可折叠），下面分列。
    ..write(
      '.fushi-srs-defs-grid .fc-more>summary{pointer-events:none;'
      'min-height:0;padding:4px 4px 0;border:0;background:none;}',
    )
    ..write('.fushi-srs-defs-grid .fc-more>summary::after{display:none;}')
    // 标题行尾的全部展开 / 收起：箭头与词典卡头同形（未全展开朝右、全部展开朝下）。
    ..write(
      '.fushi-srs-more-toggle{pointer-events:auto;flex:0 0 auto;margin-left:auto;'
      'display:inline-flex;align-items:center;justify-content:center;'
      'width:40px;height:40px;padding:0;border:0;border-radius:999px;'
      'background:none;color:var(--fc-fg-muted);cursor:pointer;'
      '-webkit-tap-highlight-color:transparent;}',
    )
    ..write(
      '.fushi-srs-more-toggle::after{content:"";width:8px;height:8px;'
      'margin-left:-4px;border-right:2px solid currentColor;'
      'border-bottom:2px solid currentColor;transform:rotate(-45deg);'
      'transition:transform 200ms cubic-bezier(0.2,0,0,1);opacity:0.8;}',
    )
    ..write(
      '.fushi-srs-more-toggle--open::after{margin-left:0;margin-top:-4px;'
      'transform:rotate(45deg);}',
    )
    ..write(
      '@media (hover:hover){.fushi-srs-more-toggle:hover'
      '{background:var(--fc-surface-1);color:var(--fc-fg);}}',
    )
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
    )
    // 主词典收起 / 展开：标题行本身不可点（模板 pointer-events:none），按钮单独接收点按；
    // 带底色，比「其他词典」的纯箭头更显眼。箭头朝下 = 展开中、朝右 = 已收起。
    ..write(
      '.fushi-srs-main-toggle{pointer-events:auto;flex:0 0 auto;'
      'display:inline-flex;align-items:center;justify-content:center;'
      'width:40px;height:40px;margin:-3px -6px -3px 0;padding:0;border:0;'
      'border-radius:999px;background:var(--fc-surface-2);color:var(--fc-fg);'
      'cursor:pointer;-webkit-tap-highlight-color:transparent;}',
    )
    ..write(
      '.fushi-srs-main-toggle::after{content:"";width:8px;height:8px;'
      'margin-left:-4px;border-right:2px solid currentColor;'
      'border-bottom:2px solid currentColor;transform:rotate(-45deg);'
      'transition:transform 200ms cubic-bezier(0.2,0,0,1);}',
    )
    ..write(
      '.fushi-srs-main-toggle--open::after{margin-left:0;margin-top:-4px;'
      'transform:rotate(45deg);}',
    )
    ..write(
      '@media (hover:hover){.fushi-srs-main-toggle:hover'
      '{background:var(--fc-surface-3, var(--fc-surface-2));}}',
    )
    ..write(
      '@media (prefers-reduced-motion:reduce){.fushi-srs-main-toggle::after,'
      '.fushi-srs-more-toggle::after{transition:none;}}',
    )
    // 「释义显示的词典」截掉的分组：不显示、不参与分列与自动展开；整个分区都截掉时不出标题。
    ..write(
      '.fushi-srs-defs-grid .fc-dicts>.fc-dict.fushi-srs-dict-over'
      '{display:none;}',
    )
    ..write(
      '.fushi-srs-defs-grid .fc-more.fushi-srs-more--empty{display:none;}',
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

/// 卡面外观里作用于释义页的部分：显示前几本词典（脚本读 `--fushi-srs-gloss-dicts`）与释义的
/// 对齐 / 首行缩进。默认外观输出的规则全是空操作（`0` = 全部词典、不改对齐与缩进），
/// 旧用户外观不变。
String srsDefsAppearanceCss(SrsCardAppearance a) {
  final StringBuffer out = StringBuffer(
    ':root{--fushi-srs-gloss-dicts:${a.glossaryDictLimit};}',
  );
  // 词典释义块自带行内 `text-align:left`（制卡写进字段的 yomitan-glossary），要 !important。
  final String? align = switch (a.glossaryAlign) {
    SrsCardTextAlign.auto => null,
    SrsCardTextAlign.start => 'start',
    SrsCardTextAlign.center => 'center',
  };
  if (align != null) {
    out.write(
      '.fc-defs-only .fc-gloss .yomitan-glossary,'
      '.fc-defs-only .fc-gloss .fc-dict-items{text-align:$align !important;}',
    );
  }
  if (a.glossaryIndent > 0) {
    out.write(
      '.fc-defs-only .fc-gloss .fc-dict-items>li'
      '{text-indent:${a.glossaryIndent}em;}',
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
/// 「默认展开全部释义」（`.card.fushi-srs-gloss-expanded`）由模板换算进布局键首位
/// （`e` / `c`），本脚本读同一个键：开着时与「折叠词典显示」关同样全部展开。
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
  function cssLabel(cs, name){
    return cs.getPropertyValue(name).trim().replace(/^"|"$/g, '');
  }
  // 「释义显示的词典」截掉的分组不算（它们不显示）。
  var SHOWN = '.fc-dicts > .fc-dict:not(.fushi-srs-dict-over)';
  function allOpen(more){
    var groups = more.querySelectorAll(SHOWN);
    for (var i = 0; i < groups.length; i++) if (!groups[i].open) return false;
    return groups.length > 0;
  }
  // 「其他词典」标题行尾的全部展开 / 收起按钮：有一本没展开就全部展开，否则全部收起。
  function syncToggle(more){
    var btn = more.querySelector(':scope > summary > .fushi-srs-more-toggle');
    if (!btn) return;
    var all = allOpen(more);
    var text = cssLabel(getComputedStyle(document.documentElement),
      all ? '--fushi-srs-label-collapse-all' : '--fushi-srs-label-expand-all');
    btn.classList.toggle('fushi-srs-more-toggle--open', all);
    btn.setAttribute('aria-expanded', all ? 'true' : 'false');
    btn.setAttribute('aria-label', text);
    btn.title = text;
  }
  // 标题本身不可点（pointer-events:none），按钮单独接收点按；它在 summary 里，要拦掉
  // details 的默认开合。
  function ensureToggle(more, lang){
    var summary = more.querySelector(':scope > summary');
    if (!summary || summary.querySelector('.fushi-srs-more-toggle')) return;
    var btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'fushi-srs-more-toggle';
    if (lang) btn.lang = lang;
    btn.addEventListener('click', function(ev){
      ev.preventDefault();
      ev.stopPropagation();
      var open = !allOpen(more);
      var groups = more.querySelectorAll(SHOWN);
      for (var i = 0; i < groups.length; i++) groups[i].open = open;
      syncToggle(more);
    });
    summary.appendChild(btn);
    // 逐本开合后同步按钮状态（toggle 不冒泡，捕获阶段收得到）。
    more.addEventListener('toggle', function(){ syncToggle(more); }, true);
  }
  function mainOpen(main){
    var groups = main.querySelectorAll('.fc-dict');
    for (var i = 0; i < groups.length; i++) if (groups[i].open) return true;
    return false;
  }
  // 主词典标题行尾的收起 / 展开：一键开合主词典的全部分组（通常一本）。窄屏「展开全文」的
  // 截断按钮跟着重算（收起后不再显示，展开后按原规则判定）。
  function syncMainToggle(main, btn){
    var open = mainOpen(main);
    var text = cssLabel(getComputedStyle(document.documentElement),
      open ? '--fushi-srs-label-main-collapse' : '--fushi-srs-label-main-expand');
    btn.classList.toggle('fushi-srs-main-toggle--open', open);
    btn.setAttribute('aria-expanded', open ? 'true' : 'false');
    btn.setAttribute('aria-label', text);
    btn.title = text;
  }
  function ensureMainToggle(main, label, lang){
    var btn = label.querySelector('.fushi-srs-main-toggle');
    if (!btn) {
      btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'fushi-srs-main-toggle';
      if (lang) btn.lang = lang;
      btn.addEventListener('click', function(ev){
        ev.preventDefault();
        ev.stopPropagation();
        var open = !mainOpen(main);
        var groups = main.querySelectorAll('.fc-dict');
        for (var i = 0; i < groups.length; i++) groups[i].open = open;
        syncMainToggle(main, btn);
        if (typeof window.__fcApplyLayout === 'function') {
          try { window.__fcApplyLayout(); } catch (err) { if (window.console) console.error(err); }
        }
      });
      label.appendChild(btn);
    }
    syncMainToggle(main, btn);
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
    var lang = cssLabel(cs, '--fushi-srs-ui-lang');
    // 卡面外观「默认展开全部释义」开着 = 与「折叠词典显示」关同样全部展开。
    var collapse = num('--fushi-srs-dict-collapse', 1) > 0 &&
      String(fc.__fcLayoutKey || '').charAt(0) !== 'e';
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
      if (label) ensureMainToggle(main, label, lang);
    }
    var more = fc.querySelector('.fc-more');
    if (!more) return;
    // 「释义显示的词典」= 前 N 本（含主词典，0 = 全部）：主词典占掉的本数之外，「其他词典」
    // 只留前面几本，其余标成截掉（只是不显示，调回「全部」原样回来）。
    var limit = Math.max(0, Math.floor(num('--fushi-srs-gloss-dicts', 0)));
    var mainCount = main ? main.querySelectorAll('.fc-dict').length : 0;
    var keep = limit > 0 ? Math.max(0, limit - mainCount) : Infinity;
    var all = more.querySelectorAll('.fc-dicts > .fc-dict');
    for (var a = 0; a < all.length; a++) {
      var over = a >= keep;
      all[a].classList.toggle('fushi-srs-dict-over', over);
      // 截掉的不再参与分列：清掉上次排版留下的宽度 / 位移，放回来时从干净状态重排。
      if (over) { all[a].style.width = ''; all[a].style.transform = ''; }
    }
    more.classList.toggle('fushi-srs-more--empty', all.length > 0 && keep === 0);
    var count = more.querySelector('.fc-more-count');
    if (count) count.textContent = String(Math.min(all.length, keep));
    more.classList.toggle('fushi-srs-more--lead', !main);
    var title = more.querySelector('.fc-more-title');
    if (title && lang) title.lang = lang;
    if (!more.open) more.open = true;
    ensureToggle(more, lang);
    var list = more.querySelector('.fc-dicts');
    if (!list) return;
    var groups = list.querySelectorAll(':scope > .fc-dict:not(.fushi-srs-dict-over)');
    var lead = !main && groups.length > 1;
    var cols = columnsFor(list, configured, groups.length - (lead ? 1 : 0));
    // 逐本三态（u = 显式展开、f = 显式折叠、- = 继承），并入键：词典管理里改了逐本设置也重排。
    var states = '';
    for (var s = 0; s < groups.length; s++) {
      var gs = getComputedStyle(groups[s]);
      states += gs.getPropertyValue('--fushi-srs-dict-unfolded').trim() === '1' ? 'u'
        : gs.getPropertyValue('--fushi-srs-dict-folded').trim() === '1' ? 'f' : '-';
    }
    var key = rows + '|' + collapse + '|' + cols + '|' + limit + '|' + states + '|' +
      (fc.__fcLayoutKey || '');
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
    syncToggle(more);
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
