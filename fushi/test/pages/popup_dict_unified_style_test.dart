import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/popup_theme_css.dart';
import 'package:material_ui/material_ui.dart';

/// 词典样式统一（M3E，默认开）：导入词典的 styles.css / 结构化内容 inline style 自带的
/// 颜色按语义换成当前 ColorScheme 令牌；开关关掉退回词典原样式。
///
/// 三层守护：
/// ① 行为级——node 真执行 popup.js（popup_dict_unified_style_test.js）：默认开、按语义
///    分类、量样式时作用域类已摘、关掉就地还原、再开重新分类。无 node 时 skip。
/// ② CSS 级——popup.css 的统一层只用 ColorScheme 派生的 `--md-sys-color-*` 令牌上色，
///    选择器全部零特异度（`:where`），且都挂在 `.fushi-dict-unified` 作用域下（关掉即失效）；
///    浏览器扩展的 content.css 镜像同步。
/// ③ 接线级——偏好默认 true、注入体下发 `window.__fushiDictUnifiedStyle`、设置页有开关。
void main() {
  test(
    'popup.js unifies dictionary colours by semantics (executes via node)',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
          'node not found on PATH; skipping JS behavior execution',
        );
        return;
      }
      final ProcessResult result = await Process.run(nodeExe, <String>[
        'test/pages/popup_dict_unified_style_test.js',
      ], workingDirectory: Directory.current.path);
      expect(
        result.exitCode,
        0,
        reason:
            'popup dict unified style JS test failed.\n'
            'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(result.stdout.toString(), contains('all assertions passed'));
    },
  );

  group('popup.css unified layer', () {
    final String css = File('assets/popup/popup.css').readAsStringSync();
    final List<({String selector, String body})> rules = _unifiedRules(css);

    test('exists and covers every semantic tag the classifier emits', () {
      expect(rules, isNotEmpty);
      final String selectors = rules.map((r) => r.selector).join('\n');
      for (final String tag in <String>[
        'chip',
        'chip-outline',
        'block',
        'panel',
        'accent',
        'muted',
        'plain',
        'flat',
      ]) {
        expect(
          selectors,
          contains('[data-fushi-dt="$tag"]'),
          reason:
              'popup.js emits data-fushi-dt="$tag"; popup.css must style it',
        );
      }
      expect(selectors, contains('[data-fushi-dt-before="chip"]'));
      expect(selectors, contains('[data-fushi-dt-after="chip"]'));
    });

    test('every rule is zero-specificity and gated on .fushi-dict-unified', () {
      for (final ({String selector, String body}) rule in rules) {
        for (final String part in rule.selector.split(
          RegExp(r',\s*(?=:where)'),
        )) {
          expect(
            part.trim(),
            startsWith(':where('),
            reason:
                'unified rules must stay zero-specificity so user '
                '!important dictionary styles still win: ${rule.selector}',
          );
          expect(
            part,
            contains('fushi-dict-unified'),
            reason:
                'turning the preference off removes the scope class; a '
                'rule outside it would leak into "keep original" mode',
          );
        }
      }
    });

    test('colours come only from ColorScheme tokens, never literals', () {
      final RegExp colorDecl = RegExp(
        r'(?:^|;|\s)(color|background-color|border-color|text-decoration-color|'
        r'text-emphasis-color|-webkit-text-fill-color)\s*:\s*([^;]+?)\s*!important',
      );
      int checked = 0;
      for (final ({String selector, String body}) rule in rules) {
        for (final RegExpMatch m in colorDecl.allMatches(rule.body)) {
          final String value = m.group(2)!.trim();
          final bool ok =
              value.startsWith('var(--md-sys-color-') ||
              const <String>{
                'inherit',
                'transparent',
                'currentColor',
              }.contains(value);
          expect(
            ok,
            isTrue,
            reason:
                '${m.group(1)}: $value in ${rule.selector} must be a '
                '--md-sys-color-* token (or inherit/transparent/currentColor)',
          );
          checked++;
        }
        expect(
          rule.body,
          isNot(matches(RegExp(r'#[0-9a-fA-F]{3,8}\b|rgba?\('))),
          reason: 'no literal colours in the unified layer: ${rule.selector}',
        );
      }
      expect(checked, greaterThan(10));
    });

    test('chip / block / accent map to the specified M3E roles', () {
      String bodyOf(String tag) => rules
          .where(
            (r) =>
                r.selector.contains('[data-fushi-dt="$tag"])') &&
                r.body.contains('color:'),
          )
          .map((r) => r.body)
          .join('\n');
      expect(
        bodyOf('chip'),
        contains('background-color: var(--md-sys-color-secondary-container)'),
      );
      expect(
        bodyOf('chip'),
        contains('color: var(--md-sys-color-on-secondary-container)'),
      );
      expect(
        bodyOf('block'),
        contains('background-color: var(--md-sys-color-primary-container)'),
      );
      expect(
        bodyOf('block'),
        contains('color: var(--md-sys-color-on-primary-container)'),
      );
      expect(bodyOf('accent'), contains('color: var(--md-sys-color-primary)'));
      expect(
        bodyOf('muted'),
        contains('color: var(--md-sys-color-on-surface-variant)'),
      );
    });

    test('the legacy dark re-tone rule stands down in unified mode', () {
      expect(
        css,
        contains(
          ':where(.glossary-content:not(.fushi-dict-unified, '
          '.fushi-dict-unify-measuring)) '
          '[class^="gloss-sc-"][style*="background"]',
        ),
        reason:
            'its (0,3,1) specificity would flatten unified chips to grey, '
            'and while popup.js measures original colours it would turn every '
            'pale dictionary fill grey (mis-classified as a primary block)',
      );
    });

    test('extension content.css mirrors carry the unified layer', () {
      for (final String path in const <String>[
        'assets/browser_extension/vendor/content.css',
        '../tools/browser-extension/vendor/content.css',
      ]) {
        final String content = File(path).readAsStringSync();
        expect(
          content,
          contains('[data-fushi-dt="chip"]'),
          reason:
              '$path is stale — re-run node '
              'tools/browser-extension/scripts/generate-content-css.mjs',
        );
      }
    });
  });

  test(
    '--md-* roles the unified layer reads are emitted from the ColorScheme',
    () {
      for (final Brightness brightness in Brightness.values) {
        final ColorScheme scheme = ColorScheme.fromSeed(
          seedColor: const Color(0xFF8E24AA),
          brightness: brightness,
        );
        final Map<String, String> vars = buildPopupThemeCssVars(
          scheme: scheme,
          backgroundColor: scheme.surface,
          surfaceContainerHigh: scheme.surfaceContainerHigh,
          dictionaryColumns: 1,
        );
        expect(vars['--md-primary'], cssRgb(scheme.primary));
        expect(vars['--md-primary-container'], cssRgb(scheme.primaryContainer));
        expect(
          vars['--md-on-primary-container'],
          cssRgb(scheme.onPrimaryContainer),
        );
        expect(
          vars['--md-secondary-container'],
          cssRgb(scheme.secondaryContainer),
        );
        expect(
          vars['--md-on-secondary-container'],
          cssRgb(scheme.onSecondaryContainer),
        );
        expect(vars['--md-outline-variant'], cssRgb(scheme.outlineVariant));
        expect(
          vars['--md-on-surface-variant'],
          cssRgb(scheme.onSurfaceVariant),
        );
      }
      // 令牌层把 --md-* 接成 --md-sys-color-*（统一层读的是后者）。
      final String css = File('assets/popup/popup.css').readAsStringSync();
      for (final String role in <String>[
        'primary',
        'primary-container',
        'on-primary-container',
        'secondary-container',
        'on-secondary-container',
        'outline-variant',
        'on-surface-variant',
      ]) {
        expect(css, contains('--md-sys-color-$role: var(--md-$role'));
      }
    },
  );

  group('wiring', () {
    test('preference defaults to on and is a known key', () {
      final String repo = File(
        'lib/src/models/preferences_repository.dart',
      ).readAsStringSync();
      expect(
        repo,
        contains(
          "getPref('popup_dictionary_unified_style', defaultValue: true)",
        ),
      );
      final String keys = File(
        'lib/src/models/preference_keys.dart',
      ).readAsStringSync();
      expect(keys, contains("'popup_dictionary_unified_style',"));
    });

    test('injection forwards the flag and re-applies only on change', () {
      final String inj = File(
        'lib/src/pages/implementations/popup_settings_injection.dart',
      ).readAsStringSync();
      expect(
        inj,
        contains(
          'window.__fushiDictUnifiedStyle = \${appModel.dictionaryUnifiedStyle};',
        ),
      );
      expect(inj, contains('window.__fushiApplyDictUnifiedStyle?.();'));
      expect(
        inj,
        contains(
          'cached.dictionaryUnifiedStyle == appModel.dictionaryUnifiedStyle',
        ),
        reason:
            'the static-settings memo must invalidate when the switch flips',
      );
    });

    test('lookup settings expose the switch', () {
      final String schema = File(
        'lib/src/settings/settings_schema_lookup.dart',
      ).readAsStringSync();
      expect(schema, contains("id: 'lookup.dictionary_unified_style',"));
      expect(schema, contains('appModel.toggleDictionaryUnifiedStyle()'));
    });

    test('popup.js treats a missing host flag as on (browser extension)', () {
      final String js = File('assets/popup/popup.js').readAsStringSync();
      expect(js, contains('window.__fushiDictUnifiedStyle !== false'));
    });
  });
}

/// popup.css 里「词典样式统一」区块（`.fushi-dict-unified` 相关）的全部规则。
List<({String selector, String body})> _unifiedRules(String css) {
  final String masked = css.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  final List<({String selector, String body})> out =
      <({String selector, String body})>[];
  for (final RegExpMatch m in RegExp(
    r'([^{}]+)\{([^{}]*)\}',
  ).allMatches(masked)) {
    final String selector = m.group(1)!.trim();
    if (!selector.contains('fushi-dict-unified')) continue;
    if (!selector.startsWith(':where(')) {
      // 唯一允许的非 :where 规则：退回原样式时才生效的旧暗色调色（用 :not 排除统一）。
      // （在 group 体里被调用，不能用 expect——那会在测试外抛 OutsideTestException。）
      if (!selector.contains(':not(.fushi-dict-unified')) {
        throw StateError('unified rule must be zero-specificity: $selector');
      }
      continue;
    }
    out.add((selector: selector, body: m.group(2)!));
  }
  return out;
}

String? _resolveNode() {
  final List<String> candidates = Platform.isWindows
      ? <String>['node.exe', 'node']
      : <String>['node'];
  for (final String name in candidates) {
    try {
      final ProcessResult probe = Process.runSync(name, <String>['--version']);
      if (probe.exitCode == 0) return name;
    } on ProcessException {
      // 不在 PATH 上，试下一个。
    }
  }
  return null;
}
