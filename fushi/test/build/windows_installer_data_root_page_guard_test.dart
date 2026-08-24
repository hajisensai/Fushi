import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/storage/installer_data_root_bootstrap.dart';

/// 源码守卫：Windows 安装器「数据存储位置」页与 app 首启消费之间的契约。
///
/// 两侧靠一个文件名 + 一个位置（`{app}\data_root.bootstrap`）握手，任何一侧改了另一侧
/// 就静默失效（安装器写了没人读 / app 等一个永远不会出现的文件）——所以把握手点钉死：
///  - iss 里的常量与 Dart 常量同值；
///  - 页面只在全新安装出现（`ShouldSkipPage` 走 `IsFreshInstall`），升级/重装不得再问；
///  - `IsFreshInstall` 查的卸载键 GUID 必须等于 `[Setup] AppId`；
///  - 下一步校验：可写预检 + 与安装目录不重合/不嵌套；
///  - `ssPostInstall` 写文件、`[UninstallDelete]` 收尾；
///  - app 侧在 `AppPaths.resolve()` **之前**消费。
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
      iss.contains(r"ExpandConstant('{app}\' + DataRootBootstrapFileName)"),
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

  test('data root page exists and is only offered on a fresh install', () {
    final String iss = readInstallerScript();
    expect(
      iss.contains('CreateInputDirPage(wpSelectDir'),
      isTrue,
      reason: 'the data root page must follow the install dir page',
    );

    final RegExpMatch? skip = RegExp(
      r'function ShouldSkipPage\(PageID: Integer\): Boolean;[\s\S]*?^end;',
      multiLine: true,
    ).firstMatch(iss);
    expect(skip, isNotNull, reason: 'ShouldSkipPage must exist');
    final String skipBody = skip!.group(0)!;
    expect(skipBody.contains('DataRootPage.ID'), isTrue);
    expect(
      skipBody.contains('DataRootPageOffered := IsFreshInstall()'),
      isTrue,
      reason:
          'the page is gated by IsFreshInstall and the decision is '
          'remembered for ssPostInstall (the uninstall key exists by then)',
    );
  });

  test('IsFreshInstall checks the real uninstall key and the support root', () {
    final String iss = readInstallerScript();
    final RegExpMatch? appId = RegExp(
      r'^AppId=\{\{([0-9A-Fa-f-]+)\}\}?',
      multiLine: true,
    ).firstMatch(iss);
    expect(appId, isNotNull, reason: '[Setup] AppId must be a GUID');
    final String guid = appId!.group(1)!;

    final RegExpMatch? key = RegExp(
      r"FushiUninstallKey\s*=\s*'([^']+)'",
    ).firstMatch(iss);
    expect(key, isNotNull);
    expect(
      key!.group(1),
      r'Software\Microsoft\Windows\CurrentVersion\Uninstall\{'
      '$guid}_is1',
      reason:
          'uninstall key GUID must equal [Setup] AppId (Pascal literals '
          'cannot expand it, so it is copied by hand)',
    );

    final RegExpMatch? fresh = RegExp(
      r'function IsFreshInstall\(\): Boolean;[\s\S]*?^end;',
      multiLine: true,
    ).firstMatch(iss);
    expect(fresh, isNotNull);
    final String body = fresh!.group(0)!;
    expect(body.contains('RegKeyExists(HKCU, FushiUninstallKey)'), isTrue);
    expect(
      body.contains(r'{userappdata}\Fushi\Fushi'),
      isTrue,
      reason:
          'must also detect a kept-data reinstall via the platform '
          'support root (%APPDATA%\\<CompanyName>\\<ProductName>)',
    );
  });

  test('NextButtonClick validates the data root page', () {
    final String iss = readInstallerScript();
    final RegExpMatch? next = RegExp(
      r'function NextButtonClick\(CurPageID: Integer\): Boolean;[\s\S]*?^end;',
      multiLine: true,
    ).firstMatch(iss);
    expect(next, isNotNull);
    final String body = next!.group(0)!;
    final int dataRootBranch = body.indexOf('CurPageID = DataRootPage.ID');
    expect(dataRootBranch, greaterThan(0));
    final String branch = body.substring(dataRootBranch);
    expect(
      branch.contains('IsSameOrAncestorDir(DataRoot, WizardDirValue)'),
      isTrue,
    );
    expect(
      branch.contains('IsSameOrAncestorDir(WizardDirValue, DataRoot)'),
      isTrue,
    );
    expect(
      branch.contains('InstallDirWritable(DataRoot)'),
      isTrue,
      reason: 'same writability preflight as the install dir (BUG-1483)',
    );
  });

  test('ssPostInstall writes the bootstrap only when the page was offered', () {
    final String iss = readInstallerScript();
    final RegExpMatch? write = RegExp(
      r'procedure WriteDataRootBootstrap\(\);[\s\S]*?^end;',
      multiLine: true,
    ).firstMatch(iss);
    expect(write, isNotNull);
    final String body = write!.group(0)!;
    expect(body.contains('if not DataRootPageOffered then'), isTrue);
    expect(
      body.contains('SaveStringsToUTF8File('),
      isTrue,
      reason: 'paths may contain non-ASCII; SaveStringToFile writes ANSI',
    );

    final RegExpMatch? step = RegExp(
      r'procedure CurStepChanged\(CurStep: TSetupStep\);[\s\S]*?^end;',
      multiLine: true,
    ).firstMatch(iss);
    expect(step, isNotNull);
    expect(step!.group(0)!.contains('WriteDataRootBootstrap();'), isTrue);
  });

  test('app consumes the bootstrap before AppPaths.resolve()', () {
    final String appModel = File(
      'lib/src/models/app_model.dart',
    ).readAsStringSync();
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
