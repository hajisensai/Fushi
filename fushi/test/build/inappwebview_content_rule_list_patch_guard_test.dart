import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/web_adblock/web_content_rule_list.dart';

import '../helpers/source_guard.dart';

/// BUG-4013：iOS 虚拟地址空间耗尽闪退（浏览器那一项）。
///
/// 上游 flutter_inappwebview_ios / _macos 1.1.2 每建一个 WebView（以及每次 `setSettings`）都把
/// `contentBlockers` 约 5 万条规则在主线程反序列化，再用固定 identifier 重新
/// `compileContentRuleList`、不缓存。修复是 `ci/patches/hosted/flutter_inappwebview_{ios,macos}-1.1.2/`
/// 的整文件覆盖补丁 + Dart 侧只传 identifier 引用（`web_content_rule_list.dart`）。Swift 不在任何
/// Dart 测试的编译面上，这里用源码扫描钉住：
///   1. 锁定版本与补丁目录同号，且 `ci/apply-patches.sh` 会覆盖 `patches/hosted/*`（版本一漂，
///      apply-patches.sh 只告警跳过，修复静默失效）；
///   2. 补丁注册了 Dart 用的同名通道、同一组前缀，按 identifier lookUp → compile、清理旧表；
///   3. 初始化与 setSettings 两条路径都先认引用，认出来就不走上游的逐 WebView 编译；
///   4. Dart 侧不再逐条映射 / 下发规则。
void main() {
  /// 测试 cwd 恒为 `fushi/`，仓库根是它的父目录。
  final Directory repoRoot = Directory.current.parent;
  const String version = '1.1.2';

  String read(String relative) => File(
    '${repoRoot.path}/$relative',
  ).readAsStringSync().replaceAll('\r\n', '\n');

  /// (包名, 平台目录)
  const List<(String, String)> targets = <(String, String)>[
    ('flutter_inappwebview_ios', 'ios'),
    ('flutter_inappwebview_macos', 'macos'),
  ];

  String patchDir(String pkg) => 'ci/patches/hosted/$pkg-$version';

  test(
    'apply-patches.sh overlays every hosted patch dir onto the pub cache',
    () {
      final String script = read('ci/apply-patches.sh');
      expect(script, contains(r'for pkg_dir in "$PATCHES_DIR/hosted"/*/; do'));
      expect(
        script,
        contains(r'target_dir="$PUB_CACHE_DIR/hosted/pub.dev/$pkg_name"'),
      );
      expect(script, contains(r'cp -r "$pkg_dir"* "$target_dir/"'));
    },
  );

  for (final (String pkg, String platform) in targets) {
    group(pkg, () {
      final String classes = '${patchDir(pkg)}/$platform/Classes';

      test('pubspec.lock pins the patched version', () {
        final RegExpMatch? m = RegExp(
          '$pkg:\\n(?:\\s{4}.*\\n)*?\\s{4}version: "([^"]+)"',
        ).firstMatch(read('pubspec.lock'));
        expect(m, isNotNull, reason: '$pkg must stay in the root pubspec.lock');
        expect(
          m!.group(1),
          version,
          reason:
              '锁定版本变了：把 ci/patches/hosted/$pkg-* 移到新版本号并核对上游，'
              '否则补丁被跳过、每个 WebView 又重新编译 5 万条规则（BUG-4013）',
        );
      });

      test('helper registers the Dart channel and compiles once per id', () {
        final String helper = read(
          '$classes/InAppWebView/FushiContentRuleLists.swift',
        );
        expect(helper, contains('"$kContentRuleListChannelName"'));
        expect(helper, contains('"$kContentRuleListIdentifierPrefix"'));
        expect(helper, contains('"$kContentRuleListReferencePrefix"'));
        expect(
          helper,
          contains('lookUpContentRuleList(forIdentifier: identifier)'),
        );
        expect(helper, contains('compileContentRuleList('));
        expect(helper, contains('forIdentifier: identifier,'));
        expect(helper, contains('getAvailableContentRuleListIdentifiers'));
        expect(helper, contains('removeContentRuleList(forIdentifier: stale)'));
        expect(helper, contains('"ContentBlockingRules"'));
        expect(helper, contains('case "activate":'));
        expect(helper, contains('case "compile":'));
        // 同一 WebView 引用未变时不动规则表。
        expect(
          helper,
          contains('if fushiContentRuleListIdentifier == identifier {'),
        );
      });

      // `WKContentRuleListStore.default()` 在 Swift 里是隐式解包可选值（IUO）：
      // `let store = ...default()` 推成 `WKContentRuleListStore?`，再点成员编译失败
      // （PR #2834 的 ios / macos job 真红）；直接 `.default().xxx` 能编过但 nil 时
      // 强解包崩溃。代码行里每次取 store 都必须是 `guard let`。
      test('default store is always unwrapped with guard let', () {
        final String helper = read(
          '$classes/InAppWebView/FushiContentRuleLists.swift',
        );
        final List<String> uses = maskComments(helper)
            .split('\n')
            .where(
              (String line) =>
                  line.contains('WKContentRuleListStore.default()'),
            )
            .toList();
        expect(uses, isNotEmpty);
        final RegExp guarded = RegExp(
          r'^\s*guard let \w+ = WKContentRuleListStore\.default\(\) else \{',
        );
        for (final String line in uses) {
          expect(
            guarded.hasMatch(line),
            isTrue,
            reason: 'default() 必须 guard let 解包：$line',
          );
        }
      });

      // 上游的两条回退编译路径（初始加载 / setSettings）原本直接
      // `WKContentRuleListStore.default().compileContentRuleList(...)` 并
      // `add(contentRuleList!)`：store 或编译结果为 nil 时强解包崩溃。它们也必须
      // 经 `FushiContentRuleLists.defaultStore()` 取 store、可选绑定编译结果。
      test('upstream compile paths never force-unwrap store or list', () {
        for (final String file in <String>[
          'InAppWebView.swift',
          'FlutterWebViewController.swift',
        ]) {
          final List<String> code = maskComments(
            read('$classes/InAppWebView/$file'),
          ).split('\n');
          final String joined = code.join('\n');
          expect(
            joined,
            isNot(contains('WKContentRuleListStore.default()')),
            reason: '$file 必须经 FushiContentRuleLists.defaultStore() 取 store',
          );
          expect(
            joined,
            contains('let store = FushiContentRuleLists.defaultStore()'),
            reason: file,
          );
          expect(joined, contains('store.compileContentRuleList('));
          expect(joined, isNot(contains('contentRuleList!')), reason: file);
          expect(
            joined,
            contains('if let contentRuleList = contentRuleList {'),
            reason: file,
          );
        }
        final String helper = read(
          '$classes/InAppWebView/FushiContentRuleLists.swift',
        );
        expect(
          helper,
          contains('    static func defaultStore() -> WKContentRuleListStore?'),
          reason: 'defaultStore() 要对上游文件可见（非 private）',
        );
      });

      test('plugin registers the channel', () {
        final String plugin = read(
          platform == 'ios'
              ? '$classes/SwiftFlutterPlugin.swift'
              : '$classes/InAppWebViewFlutterPlugin.swift',
        );
        expect(plugin, contains('FushiContentRuleListChannel(messenger:'));
      });

      test('initial load takes the shared list before upstream compile', () {
        final String source = read(
          '$classes/InAppWebView/FlutterWebViewController.swift',
        );
        final int ref = source.indexOf('webView.applyFushiContentRuleList(');
        final int upstream = source.indexOf('compileContentRuleList(');
        expect(ref, isNot(-1));
        expect(upstream, greaterThan(ref));
      });

      test('setSettings takes the shared list before upstream compile', () {
        final String source = read('$classes/InAppWebView/InAppWebView.swift');
        expect(source, contains('var fushiContentRuleListIdentifier: String?'));
        final String body = source.substring(
          source.indexOf('func setSettings('),
        );
        final int ref = body.indexOf(
          '!applyFushiContentRuleList(newSettings.contentBlockers',
        );
        final int upstream = body.indexOf('compileContentRuleList(');
        expect(ref, isNot(-1));
        expect(upstream, greaterThan(ref));
      });
    });
  }

  test('Dart no longer maps or ships rules one by one', () {
    final String wiring = read(
      'fushi/lib/src/web_adblock/web_adblock_wiring.dart',
    );
    expect(wiring, isNot(contains('contentBlockersFromRules')));
    expect(wiring, contains('contentRuleListReference('));
    final String service = read(
      'fushi/lib/src/web_adblock/web_adblock_service.dart',
    );
    expect(service, isNot(contains('_decodeRules')));
    expect(service, contains('if (id == _contentRuleListId) return;'));
  });
}
