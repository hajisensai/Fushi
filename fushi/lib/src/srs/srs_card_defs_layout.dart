/// 复习页混合渲染的释义页排版：主词典通栏在上、其他词典分列成网格，展开规则与查词弹窗
/// 同一套（列数 / 自动展开行数 / 折叠词典显示 / 词典管理里逐本的折叠）。
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
    show popupCollapsedDictionaryNames;

/// 释义页的排版参数（来自查词设置）。
@immutable
class SrsDefsLayoutConfig {
  const SrsDefsLayoutConfig({
    required this.columns,
    required this.autoExpandRows,
    required this.collapseDictionaries,
    required this.collapsedDictionaryNames,
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
          mainLabel: t.srs_card_label_main_dictionary,
          othersLabel: t.srs_card_label_other_dictionaries,
          uiLanguageTag: LocaleSettings.currentLocale.languageTag,
        ),
      );
    }),
  ),
);

/// 每列最小宽度（CSS px）：窄于它就少一列，手机上自然退成一列。
const int kSrsDefsMinColumnWidth = 280;

/// CSS 字符串字面量（转义反斜杠、引号与换行）。
String _cssString(String s) =>
    '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll('\n', r'\A ')}"';

/// 释义页的宿主 CSS：参数变量 + 网格 / 主词典标记 / 分区标题样式。
String srsDefsLayoutCss(SrsDefsLayoutConfig c) {
  final int cols = c.columns.clamp(1, 4);
  final StringBuffer out = StringBuffer()
    ..write(':root{--fushi-srs-dict-cols:$cols;')
    ..write('--fushi-srs-dict-rows:${c.autoExpandRows.clamp(0, 6)};')
    ..write('--fushi-srs-dict-collapse:${c.collapseDictionaries ? 1 : 0};')
    ..write('--fushi-srs-label-main:${_cssString(c.mainLabel)};')
    ..write('--fushi-srs-label-others:${_cssString(c.othersLabel)};')
    ..write('--fushi-srs-ui-lang:${_cssString(c.uiLanguageTag)};}')
    // 其他词典：分区标题（不可折叠），下面是网格。
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
    ..write(
      '.fushi-srs-defs-grid .fc-gloss--all .fc-dicts{display:grid;gap:8px;'
      'align-items:start;grid-template-columns:repeat(auto-fill,minmax(max('
      '${kSrsDefsMinColumnWidth}px,calc((100% - (var(--fushi-srs-dict-cols) - 1)'
      ' * 8px) / var(--fushi-srs-dict-cols))),1fr));}',
    )
    // 网格里每本是独立卡片（不再是分段卡的首尾大圆角）。
    ..write(
      '.fushi-srs-defs-grid .fc-gloss--all .fc-dicts>.fc-dict'
      '{border-radius:var(--fc-radius);}',
    )
    // 没有主释义：第一本当主词典通栏。
    ..write(
      '.fushi-srs-more--lead .fc-dicts>.fc-dict:first-child{grid-column:1/-1;}',
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
  return out.toString();
}

/// 释义页的宿主脚本（定义 `window.__fushiSrsHostLayout`，外壳在卡片脚本跑完、换主题后调）。
/// 内容固定；参数从 [srsDefsLayoutCss] 的 CSS 变量读。只在参数 / 列数 / 模板折叠状态变了
/// 时重排展开状态，用户手动开合过的不被覆盖。
const String kSrsDefsLayoutScript = r'''
(function(){
  function apply(){
    var root = document.getElementById('fushi-card-root');
    var fc = root && root.querySelector('.fc-defs-only');
    if (!fc) return;
    var cs = getComputedStyle(document.documentElement);
    function num(name, d){
      var v = parseFloat(cs.getPropertyValue(name));
      return isNaN(v) ? d : v;
    }
    var rows = num('--fushi-srs-dict-rows', 1);
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
    var groups = more.querySelectorAll('.fc-dicts > .fc-dict');
    var grid = more.querySelector('.fc-dicts');
    var cols = 1;
    if (grid) {
      var tracks = getComputedStyle(grid).gridTemplateColumns.split(' ').filter(Boolean);
      cols = Math.max(1, Math.min(tracks.length, groups.length));
    }
    var key = rows + '|' + collapse + '|' + cols + '|' + groups.length + '|' + (root.__fcLayoutKey || '');
    if (more.__fushiSrsLayoutKey === key) return;
    more.__fushiSrsLayoutKey = key;
    // 主词典占第一行；没有主释义时第一本（通栏）同样占一行、算在额度里。
    var budget = !collapse ? Infinity : main ? (rows - 1) * cols : 1 + (rows - 1) * cols;
    for (var i = 0; i < groups.length; i++) {
      var g = groups[i];
      var folded = getComputedStyle(g).getPropertyValue('--fushi-srs-dict-folded').trim() === '1';
      g.open = !folded && i < budget;
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
