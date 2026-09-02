import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String js;
  late String css;

  setUpAll(() {
    js = File('assets/popup/popup.js').readAsStringSync();
    css = File('assets/popup/popup.css').readAsStringSync();
  });

  test('变形说明使用正常查词卡片标题与表面', () {
    // 浮层已不再是 popup.html 里的静态 `.overlay`，改由 popup.js 现建
    // （`.grammar-tooltip` + `-title` / `-body` 两个子节点）。判据跟着搬到 JS 与
    // 新的 CSS 规则上，语义不变：仍然要求「变形名当标题」+「不透明主题表面」+
    // 「不是贴底整宽 bottom sheet」。
    expect(
      js,
      contains("className: 'grammar-tooltip-title'"),
      reason: '浮层必须有独立标题节点，不能只剩一块无标题正文',
    );
    expect(
      js,
      contains(
        "if (titleEl) titleEl.textContent = pinned ? (element.textContent || '') : '';",
      ),
      reason: '变形名称必须作为钉住态说明的标题',
    );

    final RegExpMatch? tooltip = RegExp(
      r'\.grammar-tooltip\s*\{([^}]*)\}',
    ).firstMatch(css);
    expect(tooltip, isNotNull);
    final String rule = tooltip!.group(1)!;
    expect(
      rule,
      contains('background: var(--surface-container-high);'),
      reason: '说明浮层必须使用不透明主题表面（BUG-2037：半透明会透出底下正文）',
    );
    expect(rule, contains('border-radius: 8px;'));
    expect(
      rule,
      contains('position: fixed;'),
      reason: '浮层按锚点定位，不能退回贴底整宽 bottom sheet',
    );
    expect(rule, isNot(contains('bottom: 0;')));
    expect(rule, isNot(contains('width: 100%;')));
  });

  test('每轮新查询与 WebView realm 复用都会清掉旧变形说明', () {
    final int renderStart = js.indexOf('window.renderPopup = function()');
    final int renderBodyEnd = js.indexOf(
      '// Cancel not-yet-visible status probes',
      renderStart,
    );
    expect(renderStart, greaterThanOrEqualTo(0));
    expect(renderBodyEnd, greaterThan(renderStart));
    final String renderPreamble = js.substring(renderStart, renderBodyEnd);
    expect(renderPreamble, contains('hideGrammarTooltip();'));

    final int reuseStart = js.indexOf(
      'window.__fushiPrepareRealmForReuse = () => {',
    );
    final int reuseEnd = js.indexOf('resetEntryStateChecks();', reuseStart);
    expect(reuseStart, greaterThanOrEqualTo(0));
    expect(reuseEnd, greaterThan(reuseStart));
    final String reusePreamble = js.substring(reuseStart, reuseEnd);
    expect(reusePreamble, contains('hideGrammarTooltip();'));

    final int closeStart = js.indexOf('function hideGrammarTooltip()');
    expect(closeStart, greaterThanOrEqualTo(0));
    final int closeEnd = js.indexOf('function createFuriganaSegment', closeStart);
    expect(closeEnd, greaterThan(closeStart));
    final String closeBody = js.substring(closeStart, closeEnd);
    expect(closeBody, contains("tooltip.style.display = 'none';"));
    expect(closeBody, contains("if (titleEl) titleEl.textContent = '';"));
    expect(closeBody, contains("if (bodyEl) bodyEl.textContent = '';"));
    expect(
      closeBody,
      contains('_grammarPinnedAnchor = null;'),
      reason: '收起必须一并解除钉住锚点，否则下次点同一枚标签 toggle 判成「没钉住」',
    );
  });
}
