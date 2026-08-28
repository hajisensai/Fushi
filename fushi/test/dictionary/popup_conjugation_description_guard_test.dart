import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String js;
  late String css;
  late String html;

  setUpAll(() {
    js = File('assets/popup/popup.js').readAsStringSync();
    css = File('assets/popup/popup.css').readAsStringSync();
    html = File('assets/popup/popup.html').readAsStringSync();
  });

  test('变形说明使用正常查词卡片标题与表面', () {
    expect(html, contains('class="overlay-title"'));
    expect(
      js,
      contains("if (title) title.textContent = element.textContent || '';"),
      reason: '变形名称必须作为说明弹窗标题，不能只剩一块无标题正文',
    );

    final RegExpMatch? overlay = RegExp(
      r'\.overlay\s*\{([^}]*)\}',
    ).firstMatch(css);
    expect(overlay, isNotNull);
    final String rule = overlay!.group(1)!;
    expect(
      rule,
      contains('inset: 8px;'),
      reason: '说明弹窗应是四边留白的查词卡片，不能退回贴底整宽 bottom sheet',
    );
    expect(
      rule,
      contains('background: var(--background-color);'),
      reason: '说明弹窗必须使用正常查词的不透明主题表面',
    );
    expect(rule, contains('border-radius: 10px;'));
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
    expect(renderPreamble, contains('closeOverlay();'));
    expect(renderPreamble, contains('hideGrammarTooltip();'));

    final int reuseStart = js.indexOf(
      'window.__fushiPrepareRealmForReuse = () => {',
    );
    final int reuseEnd = js.indexOf('resetEntryStateChecks();', reuseStart);
    expect(reuseStart, greaterThanOrEqualTo(0));
    expect(reuseEnd, greaterThan(reuseStart));
    final String reusePreamble = js.substring(reuseStart, reuseEnd);
    expect(reusePreamble, contains('closeOverlay();'));
    expect(reusePreamble, contains('hideGrammarTooltip();'));

    final int closeStart = js.indexOf('function closeOverlay()');
    final int closeEnd = js.indexOf('/* 词形变化标签的语法说明浮层', closeStart);
    final String closeBody = js.substring(closeStart, closeEnd);
    expect(closeBody, contains("overlay.style.display = 'none';"));
    expect(closeBody, contains("if (title) title.textContent = '';"));
    expect(closeBody, contains("if (content) content.textContent = '';"));
  });
}
