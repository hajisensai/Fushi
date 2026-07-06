// 守卫：release-desktop.yml 的 Windows job 必须把 VC++ CRT 运行库打进安装包。
//
// 背景（BUG-570 / TODO-1242，P0）：hibiki 的 C++ 模块用较新的 MSVC 工具链 /MD
// 动态链接 CRT，并引用较新的 STL/EH 符号（VCRUNTIME140_1 的 __CxxFrameHandler4）。
// 安装包原本不打包 CRT，于是系统 VC++ Redistributable 停在 2019 旧版（14.24）的
// 机器缺这些导出符号，hibiki.exe 一启动就以 MSVCP140.dll / c0000005 访问违例崩溃。
// 修复（标准 Flutter Windows 分发做法）：CI 打包前把 VS 的 redist CRT DLL 拷进
// build/windows/x64/runner/Release/（app 目录 DLL 载入优先于 System32，无需提权），
// 再由 hibiki.iss 的 `Source: {#SourceDir}\*` 自动打进安装包。
//
// 本守卫锁定：该拷贝步骤及其目标 DLL 名不得被删，且必须排在编译安装包之前
// （否则 ISCC 打包时 DLL 还没落地，等于没修）。纯 dart:io，不依赖 Flutter 运行时。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 从当前 cwd 向上找含 .github/workflows/release-desktop.yml 的仓库根。
Directory _repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (File('${dir.path}/.github/workflows/release-desktop.yml')
        .existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail(
    '找不到含 .github/workflows/release-desktop.yml 的仓库根'
    '（从 ${Directory.current.path} 向上）',
  );
}

void main() {
  final root = _repoRoot();
  final workflow = File('${root.path}/.github/workflows/release-desktop.yml');
  final String content =
      workflow.existsSync() ? workflow.readAsStringSync() : '';

  const String crtStepName = 'Bundle VC++ CRT runtime into Windows bundle';
  const String isccStepName = 'Compile installer (Inno Setup)';

  test('release-desktop.yml 存在', () {
    expect(workflow.existsSync(), isTrue, reason: '缺 ${workflow.path}');
  });

  test('Windows job 含「打包 VC++ CRT 运行库」步骤', () {
    expect(
      content.contains(crtStepName),
      isTrue,
      reason: '缺 "$crtStepName" 步骤：安装包不打包 CRT，旧 redist 机器会以 '
          'MSVCP140.dll / c0000005 启动崩溃（BUG-570 / TODO-1242）。',
    );
  });

  test('CRT 步骤拷贝根因所需的三个 DLL（msvcp140 + vcruntime140 + vcruntime140_1）', () {
    for (final dll in const [
      'msvcp140.dll',
      'vcruntime140.dll',
      'vcruntime140_1.dll',
    ]) {
      expect(
        content.contains(dll),
        isTrue,
        reason: '缺 $dll：vcruntime140_1 提供旧 14.24 redist 缺失的 '
            '__CxxFrameHandler4 EH 导出，三者缺一仍会崩（BUG-570）。',
      );
    }
  });

  test('CRT 步骤用 vswhere 稳健定位 VS redist（不硬编码版本号）', () {
    expect(
      content.contains('vswhere'),
      isTrue,
      reason: 'CRT redist 路径应经 vswhere 定位并对版本目录通配，'
          '避免硬编码具体 VS/CRT 版本号（BUG-570）。',
    );
  });

  test('CRT 拷贝步骤必须排在编译安装包（ISCC）之前', () {
    final crtIdx = content.indexOf(crtStepName);
    final isccIdx = content.indexOf(isccStepName);
    expect(crtIdx, greaterThanOrEqualTo(0), reason: '缺 CRT 步骤');
    expect(isccIdx, greaterThanOrEqualTo(0), reason: '缺 ISCC 步骤');
    expect(
      crtIdx < isccIdx,
      isTrue,
      reason: 'CRT DLL 必须在 ISCC 打包（Source: {#SourceDir}\*）之前落进 Release '
          '目录，否则打进安装包时 DLL 还不存在，等于没修（BUG-570）。',
    );
  });
}
