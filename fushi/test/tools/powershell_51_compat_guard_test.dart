// 守卫：被真正的 Windows PowerShell 5.1 执行的 .ps1 不得使用 PowerShell 7 /
// .NET Core 专属 API。
//
// 背景 BUG-1208：PR#528 给 native/galgame_hook/tools/build_distribution.ps1 加
// 「递归打包 x64 Unity 提取运行时」时用了 [IO.Path]::GetRelativePath —— 那是
// .NET Core / netstandard2.1+ 才有的 API。CI 的 windows runner 用
// `powershell -File` 调它，那是 Windows PowerShell 5.1（.NET Framework 4.x），
// 方法根本不存在，打包步骤当场 MethodNotFound 崩掉，develop 的
// 「Build Desktop and Apple Release Artifacts」整条发布链全红。C++ 全绿，
// 挂的是打包脚本 —— 单测和 CTest 都覆盖不到这一层，所以需要这条静态守卫。
//
// 受约束脚本集合是**从 workflow 反推**的，不是手工清单：凡被
// `powershell ... -File <path>` 调用的就按 5.1 约束；`pwsh` 调用的是 PS7，
// 不受此限（仓库里绝大多数 .ps1 走 pwsh，禁掉 PS7 语法会误伤）。新增一处
// `powershell -File` 调用，对应脚本自动进入守卫范围。
//
// 纯 dart:io，不依赖 Flutter 运行时；cwd 是 fushi/，所以跨出仓库根用 '../'。
//
// 受约束脚本集合是运行时从 yml 里解析出来的，源码里没有那些 .ps1 的路径字面量，
// 所以 `tool/tests_for_changes.dart` 的静态提取看不见它们 —— 这里显式声明触发面。
// tests-for-changes: **/*.ps1

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 从当前 cwd 向上找含 .github/workflows 的仓库根。
Directory _repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (Directory('${dir.path}/.github/workflows').existsSync()) return dir;
    final Directory parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail('找不到含 .github/workflows 的仓库根（从 ${Directory.current.path} 向上）');
}

/// 匹配 `powershell ... -File <path>`（真 5.1），不匹配 `pwsh ... -File <path>`。
/// 前置 (?<![\w-]) 防止匹配到某个以 powershell 结尾的别的词。
final RegExp _ps51Invocation = RegExp(
  r'(?<![\w.-])powershell(?:\.exe)?(?![\w.-])[^\r\n]*?-File\s+([^\s"]+)',
);

/// 5.1 上不存在 / 行为不同的写法。只收「不可能作为数据出现」的 API、参数和
/// 自动变量；`&&` / `||` 这类同时可能是别的 shell 的字面量的，靠下面的
/// 字符串剥离后再判。
const Map<String, String> _forbidden = <String, String>{
  r'::\s*GetRelativePath\s*\(':
      '[IO.Path]::GetRelativePath 是 .NET Core / netstandard2.1+ only，5.1 没有（BUG-1208 就是它）',
  r'::\s*GetFullPath\s*\([^)]*,':
      '[IO.Path]::GetFullPath 的双参数重载是 .NET Core only，5.1 只有单参数版',
  r'::\s*(TrimEndingDirectorySeparator|EndsInDirectorySeparator)\s*\(':
      '[IO.Path] 的该方法是 .NET Core only',
  r'::\s*HashData\s*\(': '::HashData 是 .NET 5+ only',
  r'\[System\.Text\.Json': 'System.Text.Json 不在 .NET Framework 4.x 里',
  r'-AsHashtable\b': 'ConvertFrom-Json -AsHashtable 是 PS 6+ only',
  r'\$Is(Windows|Linux|MacOS)\b':
      r'$IsWindows/$IsLinux/$IsMacOS 是 PS 6+ 自动变量，5.1 下恒为 $null',
  r'\$PSStyle\b': r'$PSStyle 是 PS 7.2+ only',
  r'-Parallel\b': 'ForEach-Object -Parallel 是 PS 7+ only',
  r'\bJoin-String\b': 'Join-String 是 PS 6.2+ only',
  r'\bTest-Json\b': 'Test-Json 是 PS 6+ only',
  r'\bStart-ThreadJob\b': 'Start-ThreadJob 5.1 需额外装模块，CI 上没有',
  r'-AsByteStream\b': '-AsByteStream 是 PS 6+ only（5.1 用 -Encoding Byte）',
  r'utf8NoBOM': '-Encoding utf8NoBOM 是 PS 6+ only',
  r'-SkipHttpErrorCheck\b': '-SkipHttpErrorCheck 是 PS 7+ only',
  r'-RelativeBasePath\b': 'Resolve-Path -RelativeBasePath 是 PS 7+ only',
  r'-LeafBase\b': 'Split-Path -LeafBase 是 PS 6+ only',
  r'\?\?': 'PS 7 的 null 合并 / null 条件运算符，5.1 是 parser error',
  r'(?<![\w&])&&(?!&)': 'pipeline chain 运算符 && 是 PS 7+ only，5.1 是 parser error',
  r'(?<![\w|])\|\|(?!\|)':
      'pipeline chain 运算符 || 是 PS 7+ only，5.1 是 parser error',
};

/// 剥掉引号内字面量和注释，只留可执行代码。
///
/// 顺序是关键：先剥字符串，这样 (a) 字符串里的 '#' 不会把后面的真代码误删；
/// (b) 作为**数据**传给 bash / GitHub Actions 表达式的 '&&' '||'（仓库里
/// tool/run_mac_itest.ps1、tool/check_release_policy.ps1 就有）不会误报。
String _codeOnly(String line) {
  String s = line
      .replaceAll(RegExp(r"'[^']*'"), "''")
      .replaceAll(RegExp(r'"[^"]*"'), '""');
  final int hash = s.indexOf('#');
  if (hash >= 0) s = s.substring(0, hash);
  return s;
}

void main() {
  final Directory root = _repoRoot();

  /// 从所有 workflow 反推「被 5.1 执行」的脚本相对路径。
  Set<String> ps51Scripts() {
    final Set<String> found = <String>{};
    final Directory dir = Directory('${root.path}/.github/workflows');
    for (final FileSystemEntity e in dir.listSync()) {
      if (e is! File || !e.path.endsWith('.yml')) continue;
      for (final RegExpMatch m
          in _ps51Invocation.allMatches(e.readAsStringSync())) {
        found.add(m.group(1)!.replaceAll(r'\', '/'));
      }
    }
    return found;
  }

  test('workflow 里确实存在 powershell -File 调用（守卫不能扫了个空）', () {
    final Set<String> scripts = ps51Scripts();
    // 自校验：如果调用形式变了导致一个脚本都没扫到，这条守卫就成了永远绿的
    // 摆设（BUG-1157 那一类「零执行伪装成通过」）。宁可在这里红。
    expect(
      scripts,
      isNotEmpty,
      reason: '没有从 workflow 里解析出任何 `powershell -File` 调用，'
          '守卫会扫空 —— 检查 _ps51Invocation 正则是否跟不上调用写法变化',
    );
    expect(
      scripts,
      contains('native/galgame_hook/tools/build_distribution.ps1'),
      reason: 'galgame helper 打包脚本必须仍由 5.1 执行并受本守卫覆盖（BUG-1208）',
    );
  });

  test('被 5.1 执行的 .ps1 不含 PowerShell 7 / .NET Core 专属写法', () {
    final List<String> offenders = <String>[];
    for (final String rel in ps51Scripts()) {
      final File f = File('${root.path}/$rel');
      expect(f.existsSync(), isTrue, reason: 'workflow 引用了不存在的脚本：$rel');
      final List<String> lines = f.readAsLinesSync();
      for (int i = 0; i < lines.length; i++) {
        final String code = _codeOnly(lines[i]);
        if (code.trim().isEmpty) continue;
        _forbidden.forEach((String pattern, String why) {
          if (RegExp(pattern).hasMatch(code)) {
            offenders.add('$rel:${i + 1}: $why\n    ${lines[i].trim()}');
          }
        });
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: '以下写法在 Windows PowerShell 5.1 上不可用，而 CI 正是用 '
          '`powershell -File` 跑这些脚本：\n${offenders.join('\n')}',
    );
  });
}
