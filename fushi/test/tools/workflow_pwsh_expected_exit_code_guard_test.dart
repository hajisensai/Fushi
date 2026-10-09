import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫：PowerShell 步骤里**有意期待非零退出码**的原生命令，步骤末尾必须显式 `exit 0`。
///
/// ## 起因
///
/// `release-desktop.yml` 的「Build and bundle fushi_cli」冒烟检查 `fushi_cli status`
/// 在 app 没跑时应返回 69，于是写了 `if ($LASTEXITCODE -ne 69) { throw ... }`。检查本身
/// 通过了，可整步仍以 `exit code 1` 变红、日志里一个报错字都没有，Windows 安装包从此
/// 再没发出来（10-06 起每次 develop push 都红）。
///
/// 根因在 Actions 的 pwsh 包装：脚本被写成临时文件、末尾追加
/// `if ((Test-Path -LiteralPath variable:\LASTEXITCODE)) { exit $LASTEXITCODE }`，再用
/// `pwsh -command ". '{0}'"` **点源**执行。点源脚本里的 `exit 69` 不会把 69 当进程退出码，
/// pwsh 只按「最后一条失败」给出 1——所以最后一条原生命令只要以非零结束（哪怕是预期内的
/// 非零），整步就无声失败。本机 pwsh 7.6 用同一包装复现：不加 `exit 0` 进程退出码 1，
/// 加了 0，检查不通过时照样 throw 出明确报错。
void main() {
  final Directory workflows = Directory('../.github/workflows');

  test('前置：workflow 目录在', () {
    expect(
      workflows.existsSync(),
      isTrue,
      reason: 'expected ${workflows.absolute.path}',
    );
  });

  test('解析器自检：识别期待非零码的 run 块与其末行', () {
    const String sample = '''
jobs:
  x:
    steps:
      - name: ok
        shell: pwsh
        run: |
          & foo status | Out-Null
          if (\$LASTEXITCODE -ne 69) { throw "bad" }
          # comment
          exit 0
      - name: bad
        shell: pwsh
        run: |
          & foo status | Out-Null
          if (\$LASTEXITCODE -ne 69) { throw "bad" }
      - name: unrelated
        run: |
          & foo --help
          if (\$LASTEXITCODE -ne 0) { throw "bad" }
''';
    final List<_RunBlock> blocks = _runBlocks(sample);
    expect(blocks, hasLength(3));
    expect(blocks.map(_expectsNonZeroExit).toList(), <bool>[true, true, false]);
    expect(blocks.map(_endsWithExitZero).toList(), <bool>[true, false, false]);
  });

  test('期待非零退出码的 PowerShell run 块以显式 exit 0 收尾', () {
    final List<String> offenders = <String>[];
    int checked = 0;
    for (final FileSystemEntity entity in workflows.listSync()) {
      if (entity is! File) continue;
      if (!entity.path.endsWith('.yml') && !entity.path.endsWith('.yaml')) {
        continue;
      }
      final String name = entity.uri.pathSegments.last;
      for (final _RunBlock block in _runBlocks(entity.readAsStringSync())) {
        if (!_expectsNonZeroExit(block)) continue;
        checked++;
        if (!_endsWithExitZero(block)) {
          offenders.add('$name:${block.startLine}');
        }
      }
    }
    expect(
      checked,
      greaterThan(0),
      reason:
          'release-desktop.yml 的 fushi_cli 冒烟（期待 status 返回 69）不见了？'
          '本守卫失去锚点，先确认那一步还在再修守卫。',
    );
    expect(
      offenders,
      isEmpty,
      reason:
          '这些 run 块核对了预期内的非零 \$LASTEXITCODE，却没在末尾显式 `exit 0`。'
          'Actions 的 pwsh 包装点源执行并追加 `exit \$LASTEXITCODE`，'
          '整步会以 exit code 1 无声变红。在步骤末尾加一行 `exit 0`。',
    );
  });
}

class _RunBlock {
  const _RunBlock(this.startLine, this.lines);

  final int startLine;
  final List<String> lines;
}

final RegExp _runHeader = RegExp(r'^(\s*)(?:-\s+)?run:\s*[|>][-+]?\s*$');

/// 抽出所有块标量形式的 `run:` 脚本（按缩进截取，行号 1 起）。
List<_RunBlock> _runBlocks(String yaml) {
  final List<String> lines = yaml.split(RegExp(r'\r?\n'));
  final List<_RunBlock> blocks = <_RunBlock>[];
  for (int i = 0; i < lines.length; i++) {
    final RegExpMatch? header = _runHeader.firstMatch(lines[i]);
    if (header == null) continue;
    final int indent = header.group(1)!.length;
    final List<String> body = <String>[];
    int j = i + 1;
    for (; j < lines.length; j++) {
      final String line = lines[j];
      if (line.trim().isEmpty) {
        body.add(line);
        continue;
      }
      final int lineIndent = line.length - line.trimLeft().length;
      if (lineIndent <= indent) break;
      body.add(line);
    }
    blocks.add(_RunBlock(i + 1, body));
    i = j - 1;
  }
  return blocks;
}

final RegExp _nonZeroExpectation = RegExp(
  r'\$LASTEXITCODE\s+-(?:ne|eq)\s+([0-9]+)',
  caseSensitive: false,
);

bool _expectsNonZeroExit(_RunBlock block) {
  for (final String line in block.lines) {
    for (final RegExpMatch m in _nonZeroExpectation.allMatches(line)) {
      if (int.parse(m.group(1)!) != 0) return true;
    }
  }
  return false;
}

bool _endsWithExitZero(_RunBlock block) {
  for (final String line in block.lines.reversed) {
    final String trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    return RegExp(r'^exit\s+0$', caseSensitive: false).hasMatch(trimmed);
  }
  return false;
}
