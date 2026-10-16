import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫：Windows 安装器的 [Code] 不拉起任何子进程。
///
/// 根因（2026-10-16）：Kaspersky 把签名有效的 `fushi-2.10.0-debug.19353-windows-setup.exe`
/// 判成 `PDM:Trojan.Win32.Generic`（行为分析）。应用内更新时，这个刚下载进
/// `%APPDATA%\...\updates` 的 exe 被静默拉起，随后自己再拉起隐藏 PowerShell
/// （`Get-Process | Stop-Process -Force`）与 `taskkill /F` —— 与木马 dropper 的行为画像
/// 逐项重合。这些动作现在全部在 `process_control.iss` 里用 Win32 API 原生完成。
///
/// 只扫 [Code]（以及它 #include 的文件），且先剥掉注释再判：注释里正需要写清
/// 「为什么不再用 taskkill / PowerShell」，按整份文件扫会假红。字符串字面量保留，
/// 因为 `Exec('...\taskkill.exe', ...)` 的危险恰恰在字符串里。
void main() {
  const String installerDir = 'windows/installer';

  /// Pascal Script 词法：去掉 `{ }` / `(* *)` / `//` 三种注释，保留 `'...'` 字符串。
  String stripPascalComments(String source) {
    final StringBuffer out = StringBuffer();
    int i = 0;
    while (i < source.length) {
      final String c = source[i];
      final String next = i + 1 < source.length ? source[i + 1] : '';
      if (c == "'") {
        final int close = source.indexOf("'", i + 1);
        final int stop = close < 0 ? source.length : close + 1;
        out.write(source.substring(i, stop));
        i = stop;
      } else if (c == '{') {
        final int close = source.indexOf('}', i + 1);
        i = close < 0 ? source.length : close + 1;
        out.write(' ');
      } else if (c == '(' && next == '*') {
        final int close = source.indexOf('*)', i + 2);
        i = close < 0 ? source.length : close + 2;
        out.write(' ');
      } else if (c == '/' && next == '/') {
        final int close = source.indexOf('\n', i);
        i = close < 0 ? source.length : close;
      } else {
        out.write(c);
        i++;
      }
    }
    return out.toString();
  }

  /// fushi.iss 的 [Code] 段 + 它 #include 的每个文件（递归一层足够：include 不再嵌套）。
  Map<String, String> collectCode() {
    final String iss = File('$installerDir/fushi.iss').readAsStringSync();
    final int codeAt = iss.indexOf('\n[Code]');
    expect(codeAt, greaterThan(0), reason: 'fushi.iss 必须有 [Code] 段');
    final Map<String, String> code = <String, String>{
      'fushi.iss [Code]': iss.substring(codeAt),
    };
    for (final RegExpMatch m in RegExp(
      r'^#include "([^"]+)"',
      multiLine: true,
    ).allMatches(iss)) {
      final String name = m.group(1)!;
      final File file = File('$installerDir/$name');
      expect(file.existsSync(), isTrue, reason: '#include 的 $name 不存在');
      code[name] = file.readAsStringSync();
    }
    expect(
      code.keys,
      contains('process_control.iss'),
      reason: '进程控制必须由 process_control.iss 提供并被 fushi.iss 引入',
    );
    return code;
  }

  test('剥注释的词法器本身可信（防空壳）', () {
    final String stripped = stripPascalComments(
      '{ taskkill } (* powershell *) // Exec(\n'
      "x := 'it''s {app}'; Exec('taskkill.exe');",
    );
    expect(stripped, isNot(contains('powershell')));
    expect(stripped, contains("'it''s {app}'"));
    expect(stripped, contains("Exec('taskkill.exe')"));
  });

  test('[Code] 里没有任何拉起子进程的调用', () {
    final List<RegExp> forbidden = <RegExp>[
      RegExp(r'\bExec\s*\(', caseSensitive: false),
      RegExp(r'\bExecAsOriginalUser\s*\(', caseSensitive: false),
      RegExp(r'\bShellExec(AsOriginalUser)?\s*\(', caseSensitive: false),
      RegExp(r'CreateProcess', caseSensitive: false),
      RegExp(r'WinExec', caseSensitive: false),
      RegExp(r'taskkill', caseSensitive: false),
      RegExp(r'powershell', caseSensitive: false),
      RegExp(r'cmd\.exe', caseSensitive: false),
      RegExp(r'wmic', caseSensitive: false),
    ];
    final Map<String, String> code = collectCode();
    for (final MapEntry<String, String> entry in code.entries) {
      final String stripped = stripPascalComments(entry.value);
      for (final RegExp pattern in forbidden) {
        final RegExpMatch? hit = pattern.firstMatch(stripped);
        final String context = hit == null
            ? ''
            : stripped.substring(
                (hit.start - 60).clamp(0, stripped.length),
                (hit.end + 60).clamp(0, stripped.length),
              );
        expect(
          hit,
          isNull,
          reason:
              '${entry.key} 的代码里出现了 ${pattern.pattern}：\n$context\n'
              '安装器拉起子进程（尤其 taskkill / 隐藏 PowerShell）会被杀软行为引擎'
              '判成木马（Kaspersky PDM:Trojan.Win32.Generic）。用 process_control.iss '
              '里的 Win32 API 原生实现。',
        );
      }
    }
  });

  test('原生进程控制确实接在两个时机上', () {
    final String iss = File('$installerDir/fushi.iss').readAsStringSync();
    final int init = iss.indexOf('function InitializeSetup(): Boolean;');
    final int prepare = iss.indexOf(
      'function PrepareToInstall(var NeedsRestart: Boolean): String;',
    );
    expect(init, greaterThan(0));
    expect(prepare, greaterThan(0));
    final String initBody = iss.substring(init, iss.indexOf('\nend;', init));
    final String prepareBody = iss.substring(
      prepare,
      iss.indexOf('\nend;', prepare),
    );
    expect(initBody, contains('FushiCloseAppWindows();'));
    expect(initBody, contains('FushiTerminateAppProcessTree();'));
    expect(
      initBody.indexOf('FushiCloseAppWindows();'),
      lessThan(initBody.indexOf('FushiTerminateAppProcessTree();')),
      reason: '先 WM_CLOSE 让 app 自己落盘退出，仍不走才强杀',
    );
    expect(
      prepareBody,
      contains("KillProcessesUnderDir(ExpandConstant('{app}'));"),
    );
    // include 必须出现在第一个调用者之前（Pascal Script 不支持前向引用）。
    expect(
      iss.indexOf('#include "process_control.iss"'),
      lessThan(init < prepare ? init : prepare),
    );
  });
}
