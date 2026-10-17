import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Flutter 3.47 把 Material / Cupertino 拆成 pub 包 `material_ui` /
/// `cupertino_ui`，本仓已整体迁移（`tool/migrate_design_widgets.sh`）。
///
/// SDK 内的 `package:flutter/material.dart` / `cupertino.dart` 与新包里的同名
/// 符号是**不同的类型**：一个文件混进旧 import，它造出来的 `ThemeData` /
/// `ColorScheme` / `Material` 对新树完全不可见（Theme.of 读不到、debug 下
/// 「No Material widget found」），而且编译能过，只能在运行时才发现。所以
/// `lib/` 下禁止再出现旧 import；并发分支带进来的旧 import 用迁移脚本重跑收尾：
///
///   bash tool/migrate_design_widgets.sh
///
/// 白名单只收「必须把旧 SDK 类型交给未迁移第三方包」的文件，并且它们只能用
/// `as legacy` 前缀导入（不会和新符号混名）。依赖迁移后从白名单删掉。
void main() {
  /// 文件 → 为什么必须引用旧 SDK Material / Cupertino。
  const Map<String, String> allowlist = <String, String>{
    'lib/src/utils/adaptive/legacy_design_compat.dart':
        '把新主题 / 本地化桥给未迁移第三方组件，需要旧 Material 祖先',
    'lib/src/pages/implementations/changelog_page.dart':
        'flutter_markdown 0.6 的 MarkdownStyleSheet.fromTheme 只收旧 ThemeData',
    'lib/src/utils/misc/update_checker.dart':
        'flutter_markdown 0.6 的 MarkdownStyleSheet.fromTheme 只收旧 ThemeData',
  };

  final RegExp legacyImport = RegExp(
    r"""^\s*(?:import|export)\s+['"]package:flutter/(material|cupertino)\.dart['"]([^;]*);""",
    multiLine: true,
  );
  final RegExp prefixed = RegExp(r'^\s+as\s+legacy\b');

  List<File> dartFilesUnder(String root) => Directory(root)
      .listSync(recursive: true)
      .whereType<File>()
      .where((File f) => f.path.endsWith('.dart'))
      .toList();

  String rel(File f) => f.path.replaceAll(r'\', '/');

  test('lib/ 不再 import SDK 内的 flutter/material.dart / cupertino.dart', () {
    final List<String> offenders = <String>[];
    for (final File f in dartFilesUnder('lib')) {
      final String path = rel(f);
      for (final RegExpMatch m in legacyImport.allMatches(
        f.readAsStringSync(),
      )) {
        final String tail = m.group(2)!;
        final bool allowed =
            allowlist.containsKey(path) && prefixed.hasMatch(tail);
        if (!allowed) {
          offenders.add('$path: ${m.group(0)!.trim()}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          '改用 package:material_ui/material_ui.dart / '
          'package:cupertino_ui/cupertino_ui.dart（跑 '
          'bash tool/migrate_design_widgets.sh 自动改）。确需把旧 SDK 类型交给'
          '未迁移第三方包时，用 `as legacy` 前缀导入并加进本测试白名单。\n'
          '${offenders.join('\n')}',
    );
  });

  test('白名单不过期：每个文件都存在且仍有 as legacy 旧 import', () {
    final List<String> stale = <String>[];
    for (final String path in allowlist.keys) {
      final File f = File(path);
      if (!f.existsSync()) {
        stale.add('$path（文件不存在）');
        continue;
      }
      final bool stillLegacy = legacyImport
          .allMatches(f.readAsStringSync())
          .any((RegExpMatch m) => prefixed.hasMatch(m.group(2)!));
      if (!stillLegacy) stale.add('$path（已无旧 import）');
    }
    expect(stale, isEmpty, reason: '从白名单删掉：\n${stale.join('\n')}');
  });
}
