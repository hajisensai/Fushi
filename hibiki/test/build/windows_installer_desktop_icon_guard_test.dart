import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1014 回归守卫：Windows 安装器不得在更新时无条件重写桌面快捷方式。
///
/// 根因：`hibiki.iss` 的 `[Icons]` 旧版无条件创建 `{userdesktop}\Hibiki`，
/// 每次应用内静默更新（/VERYSILENT）都把已存在的 `Fushi.lnk` 重写一遍，
/// Explorer 把重写的快捷方式当作变更/新项，丢弃 `Shell\Bags` 里记住的坐标，
/// 桌面图标被重排回默认格子 → 用户观感「每次更新图标移位」。
///
/// 修复：桌面图标改为可选 `desktopicon` 任务（默认勾选，保持首装即有图标的旧行为），
/// 并加 `Check: ShouldCreateDesktopIcon` —— 仅在 `{userdesktop}\Fushi.lnk` 尚不
/// 存在时才创建，更新时跳过、不重写、位置保留。
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

  test('desktop icon entry is gated so updates never rewrite it', () {
    final String iss = readInstallerScript();

    // 找到 [Icons] 段里的桌面快捷方式行。
    final RegExp desktopIconLine = RegExp(
      r'^\s*Name:\s*"\{userdesktop\}\\Fushi".*$',
      multiLine: true,
    );
    final Iterable<RegExpMatch> matches = desktopIconLine.allMatches(iss);
    expect(
      matches.length,
      1,
      reason: 'expected exactly one {userdesktop}\\Fushi icon entry',
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
      r"ExpandConstant\s*\(\s*'\{userdesktop\}\\Fushi\.lnk'\s*\)\s*\)\s*;"
      r'.*?end\s*;',
      dotAll: true,
    );
    expect(
      fn.hasMatch(iss),
      isTrue,
      reason: 'ShouldCreateDesktopIcon must return '
          'not FileExists({userdesktop}\\Fushi.lnk) (BUG-1014).',
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

  // BUG-1014 后续回归守卫：ISCC 的 { } 块注释不支持嵌套，注释体内出现 Inno 常量
  // （形如 {userdesktop} / {app}）时，常量的第一个 `}` 会提前闭合整个块注释，其后
  // 的文字被当代码解析 -> "Column NN: Syntax error. Compile aborted."（原始事故：
  // 第 163 行 `{userdesktop}\Fushi.lnk` 提前闭合块注释）。仓库约定 [Code] 段注释
  // 一律用 `//` 行注释（见 commit 588f30177）。本守卫扫描 [Code] 段，逐字符跟踪
  // 字符串/行注释/块注释状态，断言任何 { } 块注释体内都不再出现会闭合它的内层 `{`。
  test('no [Code] block comment embeds an Inno constant that closes it early',
      () {
    final String iss = readInstallerScript();

    // 截出 [Code] 段（本文件里它是最后一段；仍稳妥地找下一个 [Section] 头收尾）。
    final int codeStart = iss.indexOf(RegExp(r'^\[Code\]', multiLine: true));
    expect(codeStart, greaterThanOrEqualTo(0),
        reason: 'installer script must contain a [Code] section');
    final String afterHeader = iss.substring(codeStart + '[Code]'.length);
    final RegExpMatch? nextSection =
        RegExp(r'^\[[A-Za-z]', multiLine: true).firstMatch(afterHeader);
    final String code = nextSection == null
        ? afterHeader
        : afterHeader.substring(0, nextSection.start);

    // 逐字符状态机：跳过单引号字符串与 // 行注释，只对裸 { } 块注释取「{ 到第一个 }」
    // 的注释体，若注释体内还含 `{` 说明有 Inno 常量的 `}` 被当成了注释终止符。
    final List<String> hazards = <String>[];
    final int n = code.length;
    int i = 0;
    while (i < n) {
      final String c = code[i];
      if (c == '/' && i + 1 < n && code[i + 1] == '/') {
        final int nl = code.indexOf('\n', i);
        i = nl < 0 ? n : nl + 1;
        continue;
      }
      if (c == "'") {
        int j = i + 1;
        while (j < n && code[j] != "'") {
          j++;
        }
        i = j + 1;
        continue;
      }
      if (c == '{') {
        final int close = code.indexOf('}', i + 1);
        final int end = close < 0 ? n : close;
        final String body = code.substring(i + 1, end);
        if (body.contains('{')) {
          hazards.add(code.substring(i, (end + 1) > n ? n : end + 1));
        }
        i = end + 1;
        continue;
      }
      i++;
    }

    expect(
      hazards,
      isEmpty,
      reason: '[Code] 段的 { } 块注释里嵌入了会提前闭合它的 Inno 常量（内层 {…}），'
          '会导致 ISCC 语法错误、编译中止。请把这些块注释改成逐行 // 注释。命中：'
          '$hazards',
    );
  });
}
