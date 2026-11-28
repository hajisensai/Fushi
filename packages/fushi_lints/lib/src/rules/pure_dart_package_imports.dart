import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/error/error.dart';

import '../ratchet.dart';

/// 无头服务端闭包里的包不得碰 Flutter、method-channel 插件或反向 import app。
///
/// `packages/fushi_engine` 与 `packages/fushi_server` 会被 `dart build cli` 打成
/// 不含 Flutter 的 CLI bundle，`fushi_core` / `fushi_audio` 整包零 Flutter
/// （2026-09-30）。闭包里任何 `package:flutter/…`（含 foundation.dart，它传递
/// import `dart:ui`）、`dart:ui`、插件、或 `package:fushi/…` 都会让服务端编不过，
/// 但那要等 CI 的 Linux job 才炸，这条规则在 analyze 时就拦下。
///
/// 两层判据：
/// 1. 直接 import / export 命中 [forbiddenPrefixes]（含三个内部包的全 barrel：
///    引擎只准用 `fushi_audio_core` / `fushi_anki_core` / `fushi_dictionary_core`
///    这三个纯 Dart 子 barrel）；
/// 2. 按 element 模型沿 import / export 走完整个传递闭包，到达 `dart:ui` 或
///    `package:flutter/` 就报，并给出路径链。旧文本守卫只沿相对路径走子 barrel，
///    经 `package:` 进入别的包后就看不见，这里没有这个洞。
///
/// 设计：docs/specs/2026-09-08-fushi-server-headless-design.md §3.1。
class PureDartPackageImports extends RatchetedRule {
  PureDartPackageImports()
    : super(name: ruleName, description: '无头服务端闭包的 import 纯度');

  static const String ruleName = 'fushi_pure_dart_package_imports';

  static const LintCode code = LintCode(
    ruleName,
    'Headless-server code must not depend on {0}: {1}',
    correctionMessage:
        'Keep packages/fushi_engine, fushi_server, fushi_core and fushi_audio '
        'free of Flutter, plugins and package:fushi; import the pure-Dart '
        '*_core barrels instead of the full ones.',
    severity: DiagnosticSeverity.WARNING,
  );

  static const LintCode stale = LintCode(
    '${ruleName}_stale_allowance',
    'fushi_lints allows {1} {0} import(s) in this file but found {2}.',
    correctionMessage:
        'Lower or delete the Allowance in '
        'packages/fushi_lints/lib/src/rules/pure_dart_package_imports.dart.',
    severity: DiagnosticSeverity.WARNING,
  );

  /// 受约束的包（`packages/<名字>`），整包 `lib/` 与 `bin/`。
  static const Set<String> pureDartPackages = <String>{
    'fushi_engine',
    'fushi_server',
    'fushi_core',
    'fushi_audio',
  };

  static const List<String> forbiddenPrefixes = <String>[
    'package:flutter/',
    'package:flutter_riverpod/',
    'package:riverpod/',
    'package:fushi/',
    'package:path_provider/',
    'package:shared_preferences/',
    'package:flutter_onnxruntime/',
    'package:ffmpeg_kit_next_flutter',
    'package:bonsoir/',
    'package:file_picker/',
    'package:share_plus/',
    'package:url_launcher/',
    'package:flutter_charset_detector/',
    'package:package_info_plus/',
    'package:device_info_plus/',
    'package:permission_handler/',
    'package:media_kit',
    'package:flutter_inappwebview',
    'package:just_audio',
    'package:audio_session/',
    'package:flutter_archive/',
    'package:win32/',
    'package:sqlite3_flutter_libs/',
    'package:fushi_audio/fushi_audio.dart',
    'package:fushi_anki/fushi_anki.dart',
    'package:fushi_dictionary/fushi_dictionary.dart',
  ];

  @override
  LintCode get violationCode => code;

  @override
  LintCode get staleCode => stale;

  @override
  List<Allowance> get allowances => const <Allowance>[];

  @override
  bool appliesTo(String repoPath) {
    final List<String> parts = repoPath.split('/');
    return parts.length > 3 &&
        parts[0] == 'packages' &&
        pureDartPackages.contains(parts[1]) &&
        (parts[2] == 'lib' || parts[2] == 'bin');
  }

  @override
  List<RuleSite> collect(CompilationUnit unit, RuleContext context) {
    final List<RuleSite> sites = <RuleSite>[];
    final Map<LibraryElement, List<Uri>?> memo = <LibraryElement, List<Uri>?>{};
    for (final Directive d in unit.directives) {
      if (d is! NamespaceDirective) continue;
      final String? uri = d.uri.stringValue;
      if (uri == null) continue;
      final String? direct = _directHit(uri);
      if (direct != null) {
        sites.add(RuleSite(d, direct, uri));
        continue;
      }
      final LibraryElement? target = switch (d) {
        ImportDirective() => d.libraryImport?.importedLibrary,
        ExportDirective() => d.libraryExport?.exportedLibrary,
      };
      if (target == null) continue;
      final List<Uri>? chain = flutterChain(target, memo);
      if (chain != null) {
        sites.add(
          RuleSite(
            d,
            chain.last.toString(),
            chain.map((Uri u) => '$u').join(' -> '),
          ),
        );
      }
    }
    return sites;
  }

  static String? _directHit(String uri) {
    if (uri == 'dart:ui' || uri.startsWith('dart:ui/')) return 'dart:ui';
    for (final String prefix in forbiddenPrefixes) {
      if (uri.startsWith(prefix)) return prefix;
    }
    return null;
  }

  static bool _isFlutter(Uri uri) =>
      (uri.isScheme('dart') && uri.path == 'ui') ||
      (uri.isScheme('package') && uri.path.startsWith('flutter/'));

  /// 从 [library] 出发沿 import / export 能到达 Flutter 时，返回一条
  /// `library -> … -> dart:ui|package:flutter/…` 的链；到不了返回 null。
  ///
  /// [memo] 记住本编译单元里已经算过的库（null = 干净），每个库只展开一次。
  static List<Uri>? flutterChain(
    LibraryElement library,
    Map<LibraryElement, List<Uri>?> memo,
  ) {
    if (memo.containsKey(library)) return memo[library];
    if (_isFlutter(library.uri)) {
      return memo[library] = <Uri>[library.uri];
    }
    // SDK 里除 dart:ui 外都不会走到 Flutter，不必展开。
    if (library.uri.isScheme('dart')) return memo[library] = null;
    memo[library] = null; // 环上的回边按干净处理，真正的路径另有一条边可达。
    for (final LibraryFragment fragment in library.fragments) {
      final Iterable<LibraryElement?> next = <LibraryElement?>[
        for (final LibraryImport i in fragment.libraryImports)
          i.importedLibrary,
        for (final LibraryExport e in fragment.libraryExports)
          e.exportedLibrary,
      ];
      for (final LibraryElement? n in next) {
        if (n == null) continue;
        final List<Uri>? tail = flutterChain(n, memo);
        if (tail != null) {
          return memo[library] = <Uri>[library.uri, ...tail];
        }
      }
    }
    return null;
  }
}
