import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1014 回归守卫：Windows 安装器不得在更新时无条件重写桌面快捷方式。
///
/// 根因：`hibiki.iss` 的 `[Icons]` 旧版无条件创建 `{userdesktop}\Hibiki`，
/// 每次应用内静默更新（/VERYSILENT）都把已存在的 `Hibiki.lnk` 重写一遍，
/// Explorer 把重写的快捷方式当作变更/新项，丢弃 `Shell\Bags` 里记住的坐标，
/// 桌面图标被重排回默认格子 → 用户观感「每次更新图标移位」。
///
/// 修复：桌面图标改为可选 `desktopicon` 任务（默认勾选，保持首装即有图标的旧行为），
/// 并加 `Check: ShouldCreateDesktopIcon` —— 仅在 `{userdesktop}\Hibiki.lnk` 尚不
/// 存在时才创建，更新时跳过、不重写、位置保留。
void main() {
  String readInstallerScript() {
    final File file = File('windows/installer/hibiki.iss');
    expect(
      file.existsSync(),
      isTrue,
      reason: 'expected Inno Setup script at ${file.absolute.path}',
    );
    return file.readAsStringSync();
  }

  test('desktop icon entry is gated so updates never rewrite it', () {
    final String iss = readInstallerScript();

    // 找到 [Icons] 段里的桌面快捷方式行。
    final RegExp desktopIconLine = RegExp(
      r'^\s*Name:\s*"\{userdesktop\}\\Hibiki".*$',
      multiLine: true,
    );
    final Iterable<RegExpMatch> matches = desktopIconLine.allMatches(iss);
    expect(
      matches.length,
      1,
      reason: 'expected exactly one {userdesktop}\\Hibiki icon entry',
    );
    final String line = matches.first.group(0)!;

    // 必须挂 Check 守卫（避免更新时重写 .lnk）+ 归到可选 desktopicon 任务。
    expect(
      line.contains('Check: ShouldCreateDesktopIcon'),
      isTrue,
      reason: 'desktop icon must be guarded by Check: ShouldCreateDesktopIcon '
          'so an update does not rewrite the shortcut (BUG-1014). Line: $line',
    );
    expect(
      line.contains('Tasks: desktopicon'),
      isTrue,
      reason: 'desktop icon must be an optional "desktopicon" task. '
          'Line: $line',
    );
  });

  test('ShouldCreateDesktopIcon skips creation when the shortcut exists', () {
    final String iss = readInstallerScript();

    // 守卫函数必须存在，且逻辑是「快捷方式已存在 → 不创建」。
    final RegExp fn = RegExp(
      r'function\s+ShouldCreateDesktopIcon\s*\(\s*\)\s*:\s*Boolean\s*;'
      r'.*?Result\s*:=\s*not\s+FileExists\s*\(\s*'
      r"ExpandConstant\s*\(\s*'\{userdesktop\}\\Hibiki\.lnk'\s*\)\s*\)\s*;"
      r'.*?end\s*;',
      dotAll: true,
    );
    expect(
      fn.hasMatch(iss),
      isTrue,
      reason: 'ShouldCreateDesktopIcon must return '
          'not FileExists({userdesktop}\\Hibiki.lnk) (BUG-1014).',
    );
  });

  test('desktopicon task is declared and defaults to checked', () {
    final String iss = readInstallerScript();

    final RegExp taskLine = RegExp(
      r'^\s*Name:\s*"desktopicon".*$',
      multiLine: true,
    );
    final RegExpMatch? match = taskLine.firstMatch(iss);
    expect(
      match,
      isNotNull,
      reason: 'expected a [Tasks] entry Name: "desktopicon"',
    );
    // 默认勾选：保持旧行为（首装桌面即有图标）。不得带 unchecked 标志。
    expect(
      match!.group(0)!.toLowerCase().contains('unchecked'),
      isFalse,
      reason: 'desktopicon must default to checked to preserve the '
          'existing first-install behaviour (icon on desktop).',
    );
  });
}
