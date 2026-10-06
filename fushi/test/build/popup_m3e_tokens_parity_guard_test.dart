import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 查词弹窗 M3 Expressive 设计令牌守卫（用户 2026-10-05：Material 一律 M3E）。
///
/// 钉住：
///  1. `assets/popup/m3e-tokens.css`（令牌唯一真源，扩展自有页面直接复用）与
///     popup.css 里 `@m3e-tokens:begin` ~ `@m3e-tokens:end` 区块逐字一致——弹窗 CSS 由
///     Dart 读成一整份内联，加载器只认 popup.css，所以令牌在那里有一份副本。
///  2. 令牌区块的颜色角色全部优先读 Dart 注入的 `--md-*`，且 Dart 真的注入了它们
///     （buildPopupThemeCssVars 生成、popup_settings_injection 逐条 setProperty、
///     浏览器扩展 theme map 下发）。
///  3. Dart 注入按设计系统 toggle `fushi-m3e`（Apple / 墨水屏不挂）与
///     `fushi-reduced-motion`；popup.css 有 `html.fushi-m3e` 视觉层，且它排在
///     eink 覆盖块之前（墨水屏规则必须最后生效）。
///  4. 视觉层不写 @media（扩展 content.css 生成器不处理嵌套 at-rule），并进了
///     生成的 content.css。
///
/// flutter test cwd 是 fushi 包根。
void main() {
  const String tokensPath = 'assets/popup/m3e-tokens.css';
  const String popupCssPath = 'assets/popup/popup.css';
  const String contentCssPath = 'assets/browser_extension/vendor/content.css';
  const String themeCssVarsPath = 'lib/src/utils/popup_theme_css.dart';
  const String injectionPath =
      'lib/src/pages/implementations/popup_settings_injection.dart';
  const String appModelPath = 'lib/src/models/app_model.dart';
  const String begin = '/* @m3e-tokens:begin */';
  const String end = '/* @m3e-tokens:end */';

  String read(String p) => File(p).readAsStringSync();

  String tokenBlock(String css, String path) {
    final int b = css.indexOf(begin);
    final int e = css.indexOf(end);
    expect(b, greaterThanOrEqualTo(0), reason: '$path 缺 $begin');
    expect(e, greaterThan(b), reason: '$path 缺 $end');
    expect(css.indexOf(begin, b + 1), -1, reason: '$path 只能有一个令牌区块');
    return css.substring(b, e + end.length);
  }

  /// 令牌区块里由 Dart 注入的颜色源（`var(--md-xxx,` 的 xxx）。
  final RegExp injectedRef = RegExp(r'var\(--md-([a-z-]+),');

  test('popup.css 的令牌区块与 m3e-tokens.css 逐字一致', () {
    final String fromTokens = tokenBlock(read(tokensPath), tokensPath);
    final String fromPopup = tokenBlock(read(popupCssPath), popupCssPath);
    expect(
      fromPopup,
      fromTokens,
      reason:
          '改令牌先改 $tokensPath，再把区块原样拷进 popup.css 并 cp 两份 vendor 镜像、'
          '重跑 generate-content-css.mjs',
    );
  });

  test('令牌覆盖色角色 / 形状 / 字阶 / 状态层 / 动效五类', () {
    final String block = tokenBlock(read(tokensPath), tokensPath);
    for (final String name in const <String>[
      '--md-sys-color-primary:',
      '--md-sys-color-primary-container:',
      '--md-sys-color-secondary-container:',
      '--md-sys-color-tertiary-container:',
      '--md-sys-color-surface-container:',
      '--md-sys-color-inverse-surface:',
      '--md-sys-shape-corner-extra-large: 28px;',
      '--md-sys-shape-corner-full:',
      '--md-sys-typescale-label-large-size:',
      '--md-sys-typescale-weight-emphasized:',
      '--md-sys-state-hover-opacity:',
      '--md-sys-motion-spring-fast-spatial:',
    ]) {
      expect(block, contains(name), reason: '令牌缺 $name');
    }
  });

  test('令牌引用的每个 --md-* 都由 Dart 生成、in-app 注入、扩展下发', () {
    final String block = tokenBlock(read(tokensPath), tokensPath);
    final String vars = read(themeCssVarsPath);
    final String injection = read(injectionPath);
    final String appModel = read(appModelPath);
    final Set<String> refs = injectedRef
        .allMatches(block)
        .map((RegExpMatch m) => '--md-${m.group(1)}')
        // --md-sys-* 是令牌自己互相引用，不是注入源。
        .where((String n) => !n.startsWith('--md-sys-'))
        .toSet();
    expect(refs, isNotEmpty);
    for (final String name in refs) {
      expect(
        vars,
        contains("'$name':"),
        reason: 'buildPopupThemeCssVars 没生成 $name',
      );
      expect(
        injection,
        contains("setProperty('$name'"),
        reason: 'popup_settings_injection 没注入 $name',
      );
      expect(
        appModel,
        contains("'$name': vars['$name']!"),
        reason: '浏览器扩展 theme map 没下发 $name',
      );
    }
  });

  test('注入按设计系统 toggle fushi-m3e 与 fushi-reduced-motion', () {
    final String injection = read(injectionPath);
    expect(injection, contains("classList.toggle('fushi-m3e', \$m3e)"));
    expect(
      injection,
      contains("classList.toggle('fushi-reduced-motion', \$reducedMotion)"),
    );
    expect(
      injection,
      contains(
        'final bool m3e = !eink && theme.extension<FushiAppleColors>() == null;',
      ),
      reason: 'M3E 视觉层只在 Material 设计系统、非墨水屏下挂',
    );
  });

  test('popup.css 有 M3E 视觉层，排在 eink 覆盖块之前、不写 @media', () {
    final String css = read(popupCssPath);
    final int layer = css.indexOf('html.fushi-m3e .glossary-group {');
    final int eink = css.indexOf('html.eink *,');
    expect(layer, greaterThan(0), reason: '缺 M3E 视觉层');
    expect(eink, greaterThan(layer), reason: 'eink 覆盖必须排在 M3E 层之后');
    expect(
      RegExp(r'^@media[ (]', multiLine: true).hasMatch(css),
      isFalse,
      reason: '扩展 content.css 生成器不处理嵌套 at-rule',
    );
    for (final String sel in const <String>[
      'html.fushi-m3e .inline-action-button:where(:not(:disabled)):where(:not(.header-buttons > *)):active {',
      'html.fushi-m3e .fushi-btn-tip {',
      'html.fushi-m3e .grammar-tooltip {',
      'html.fushi-m3e .fushi-audio-menu {',
      'html.fushi-m3e .no-results-icon {',
      'html.fushi-m3e.fushi-reduced-motion .inline-action-button,',
    ]) {
      expect(css, contains(sel), reason: 'M3E 视觉层缺 `$sel`');
    }
  });

  test('生成的扩展 content.css 带上令牌与 M3E 视觉层（重根到容器）', () {
    final String content = read(contentCssPath);
    expect(content, contains(begin));
    expect(
      content,
      contains(':where(#entries-container).fushi-m3e .glossary-group'),
    );
  });
}
