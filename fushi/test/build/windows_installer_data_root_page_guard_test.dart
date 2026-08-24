import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/storage/installer_data_root_bootstrap.dart';

import '../helpers/source_guard.dart';

/// 源码守卫：Windows 安装器「数据存储位置」页与 app 首启消费之间的契约。
///
/// 两侧靠一个文件名 + 一个位置（`{app}\data_root.bootstrap`）握手，任何一侧改了另一侧
/// 就静默失效（安装器写了没人读 / app 等一个永远不会出现的文件）——所以把握手点钉死：
///  - iss 里的常量与 Dart 常量同值；
///  - 页面只在全新安装、非静默时出现（`ShouldSkipPage` 走 `WizardSilent` + `IsFreshInstall`）；
///  - `IsFreshInstall` 的卸载键从 `[Setup] AppId` 派生（手抄会漏掉 `{{`→`{` 转义，
///    真值尾部是 `}}`），并兼看新旧两个平台 support 根；
///  - 下一步校验：可写预检 + 与安装目录不重合/不嵌套 + 目标下无既有 documents/support；
///  - `ssPostInstall` 写文件、`[UninstallDelete]` 收尾；
///  - app 侧在 `AppPaths.resolve()` **之前**消费。
///
/// `[Code]` 段按 `//` 注释掩码后再断言（[maskComments]），把断言字面量写进注释骗不过。
void main() {
  String readInstallerScript() {
    final File file = File('windows/installer/fushi.iss');
    expect(
      file.existsSync(),
      isTrue,
      reason: 'expected Inno Setup script at ${file.absolute.path}',
    );
    return file.readAsStringSync();
  }

  /// `[Code]` 段（`//` 注释已掩码）。Pascal 的 `{ }` 块注释里没有本文件断言的
  /// 任何代码字面量（它们都含 `(`/`:=`/引号），不另掩。
  String readCode() {
    final String iss = readInstallerScript();
    final int start = iss.indexOf('[Code]');
    expect(
      start,
      greaterThan(0),
      reason: 'fushi.iss must have a [Code] section',
    );
    return maskComments(iss.substring(start));
  }

  String block(String code, String head) {
    final RegExpMatch? match = RegExp(
      '${RegExp.escape(head)}[\\s\\S]*?^end;',
      multiLine: true,
    ).firstMatch(code);
    expect(match, isNotNull, reason: 'expected "$head" in [Code]');
    return match!.group(0)!;
  }

  test('bootstrap file name matches between installer and app', () {
    final String iss = readInstallerScript();
    final RegExpMatch? constant = RegExp(
      r"DataRootBootstrapFileName\s*=\s*'([^']+)'",
    ).firstMatch(iss);
    expect(
      constant,
      isNotNull,
      reason: 'fushi.iss must declare DataRootBootstrapFileName',
    );
    expect(constant!.group(1), installerDataRootBootstrapFileName);

    expect(
      readCode().contains(
        r"ExpandConstant('{app}\' + DataRootBootstrapFileName)",
      ),
      isTrue,
      reason:
          'bootstrap must be written next to the exe ({app}); the app '
          'locates it via Platform.resolvedExecutable',
    );
    final RegExpMatch? uninstallDelete = RegExp(
      r'^\[UninstallDelete\]([\s\S]*?)^\[',
      multiLine: true,
    ).firstMatch(iss);
    expect(uninstallDelete, isNotNull, reason: '[UninstallDelete] section');
    expect(
      uninstallDelete!
          .group(1)!
          .contains(
            'Type: files; Name: "{app}\\$installerDataRootBootstrapFileName"',
          ),
      isTrue,
      reason: '[UninstallDelete] must remove the bootstrap file',
    );
  });

  test('data root page exists and is only offered on a fresh, non-silent '
      'install', () {
    final String code = readCode();
    expect(
      code.contains('CreateInputDirPage(wpSelectDir'),
      isTrue,
      reason: 'the data root page must follow the install dir page',
    );

    final String skip = block(
      code,
      'function ShouldSkipPage(PageID: Integer): Boolean;',
    );
    expect(skip.contains('DataRootPage.ID'), isTrue);
    expect(
      skip.contains(
        'DataRootPageOffered := (not WizardSilent()) and IsFreshInstall()',
      ),
      isTrue,
      reason:
          'silent installs must skip the page (Inno aborts the whole '
          'install when a ClickThrough NextButtonClick returns False) and the '
          'decision must be remembered for ssPostInstall (the uninstall key '
          'exists by then)',
    );
  });

  test('uninstall key derives from [Setup] AppId and both support roots are '
      'probed', () {
    final String code = readCode();
    final String key = block(code, 'function FushiUninstallKey(): String;');
    expect(
      key.contains(
        r"ExpandConstant('{#SetupSetting("
        '"AppId"'
        r")}')",
      ),
      isTrue,
      reason:
          'AppId must come from [Setup] via ISPP + ExpandConstant ({{ → {); '
          'a hand-copied GUID misses the trailing "}}" of the real AppId and '
          'RegKeyExists never matches',
    );
    expect(key.contains(r"'_is1'"), isTrue);
    expect(
      RegExp(r'Uninstall\\\{[0-9A-Fa-f-]{36}').hasMatch(code),
      isFalse,
      reason: 'no hand-copied GUID anywhere in [Code]',
    );

    final String fresh = block(code, 'function IsFreshInstall(): Boolean;');
    expect(fresh.contains('RegKeyExists(HKCU, FushiUninstallKey())'), isTrue);
    expect(
      fresh.contains(r'{userappdata}\Fushi\Fushi'),
      isTrue,
      reason:
          'must detect a kept-data reinstall via the platform support root '
          '(%APPDATA%\\<CompanyName>\\<ProductName>)',
    );
    expect(
      fresh.contains(r'{userappdata}\Hibiki\Hibiki'),
      isTrue,
      reason:
          'legacy support root is migrated by migrateLegacySupportDir on '
          'first launch and then counts as an existing install — the wizard '
          'must not ask a question the app will discard',
    );
  });

  test('NextButtonClick validates the data root page', () {
    final String next = block(
      readCode(),
      'function NextButtonClick(CurPageID: Integer): Boolean;',
    );
    final int dataRootBranch = next.indexOf('CurPageID = DataRootPage.ID');
    expect(dataRootBranch, greaterThan(0));
    final String branch = next.substring(dataRootBranch);
    expect(
      branch.contains('IsSameOrAncestorDir(DataRoot, WizardDirValue)'),
      isTrue,
    );
    expect(
      branch.contains('IsSameOrAncestorDir(WizardDirValue, DataRoot)'),
      isTrue,
    );
    expect(
      branch.contains("DirExists(AddBackslash(DataRoot) + 'documents')"),
      isTrue,
      reason:
          'pre-existing documents/ subtree must be rejected (targetNotEmpty)',
    );
    expect(
      branch.contains("DirExists(AddBackslash(DataRoot) + 'support')"),
      isTrue,
    );
    expect(
      branch.contains('InstallDirWritable(DataRoot)'),
      isTrue,
      reason: 'same writability preflight as the install dir (BUG-1483)',
    );
  });

  test('ssPostInstall writes the bootstrap only when the page was offered', () {
    final String code = readCode();
    final String write = block(code, 'procedure WriteDataRootBootstrap();');
    expect(write.contains('if not DataRootPageOffered then'), isTrue);
    expect(
      write.contains('SaveStringsToUTF8File('),
      isTrue,
      reason: 'paths may contain non-ASCII; SaveStringToFile writes ANSI',
    );

    final String step = block(
      code,
      'procedure CurStepChanged(CurStep: TSetupStep);',
    );
    expect(step.contains('WriteDataRootBootstrap();'), isTrue);
  });

  test('app consumes the bootstrap before AppPaths.resolve()', () {
    final String appModel = maskComments(
      File('lib/src/models/app_model.dart').readAsStringSync(),
    );
    final int consume = appModel.indexOf(
      'await consumeInstallerDataRootBootstrap();',
    );
    final int resolve = appModel.indexOf(
      '_appPaths = await AppPaths.resolve();',
    );
    expect(consume, greaterThan(0));
    expect(
      resolve,
      greaterThan(consume),
      reason: 'resolve() reads the data_root pref the bootstrap writes',
    );
  });
}
