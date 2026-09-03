// BUG-1883 源码守卫：Windows 安装包必须带上「缺了 app 就起不来」的核心运行时。
//
// 用户侧症状是 `Failed to load dynamic library 'fushidicts_ffi.dll'`（Win32 错误
// 126），app 卡在 main.dart 的 initError 屏。126 在这里的含义是「它不在正在运行的
// exe 旁边」——不是文件损坏，也不是依赖缺失。
//
// 为什么守的是**打包输入**而不是构建退出码：Inno 的 `[Files]` 是
// `Source: "{#SourceDir}\*"` 整目录递归，少什么就少什么，它自己永远不会报错。
// CMake 的 `install(TARGETS fushidicts_ffi ...)` 正常时当然会拷，但改名、改
// INSTALL_BUNDLE_LIB_DIR、或某次 install 中途中断，都会让一个少了词典引擎的目录
// 被整包发出去。本仓已经改过一次名（hoshidicts_ffi.dll → fushidicts_ffi.dll），
// 正是最容易漏的那类改动。
//
// 这条守卫钉两件事：
//   ① CI 在 ISCC 之前真的有这道门，且它是硬失败（throw）而不是 warning；
//   ② 门禁里的 DLL 名与 Dart 侧 `DynamicLibrary.open` 的实参**逐字一致**——
//      两处各自硬编码同一个字符串，这正是改名时会漂的地方。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

void main() {
  final File workflowFile = File('../.github/workflows/release-desktop.yml');
  final File bindingsFile = File(
    '../packages/fushi_dictionary/lib/src/ffi/fushidicts_ffi_bindings.dart',
  );

  test('release-desktop.yml 在 ISCC 之前硬校验核心运行时', () {
    expect(workflowFile.existsSync(), isTrue,
        reason: '找不到 ${workflowFile.path}；守卫的扫描面失效了');
    final String workflow = workflowFile.readAsStringSync();

    final int gate =
        workflow.indexOf('Verify Windows installer payload has the core runtime');
    final int iscc = workflow.indexOf('Compile installer (Inno Setup)');
    expect(gate, greaterThanOrEqualTo(0),
        reason: '打包前的核心运行时校验步骤不见了');
    expect(iscc, greaterThan(gate),
        reason: '校验必须在 ISCC 打包之前——之后再查，包已经出去了');

    final String gateBody = workflow.substring(gate, iscc);
    // 断言必须钉住**缺文件那一条**在 throw，不能只查 gateBody 里有没有 `throw `：
    // 同一步骤开头还有一句 `throw "Missing Windows release bundle directory"`，
    // 松判据会被它满足，于是把缺文件分支降级成 Write-Warning 也照样绿
    // （变异实测 M2 当场证过这条假绿）。
    expect(
      gateBody.contains(
        'throw ("Windows installer payload is missing core runtime file(s): "',
      ),
      isTrue,
      reason: '缺核心文件必须硬失败。warning 会被无人值守的发布流程直接跑过去，'
          '等于没有这道门',
    );
  });

  test('CI 门禁里的 DLL 名与 Dart 侧 DynamicLibrary.open 实参逐字一致', () {
    expect(bindingsFile.existsSync(), isTrue,
        reason: '找不到 ${bindingsFile.path}；守卫的扫描面失效了');

    // 从生产代码里把 Windows 分支真正传给 DynamicLibrary.open 的字面量抠出来，
    // 不在测试里硬编码它——否则改名时测试会跟着一起「对」，两边一起漂。
    final String bindings = maskComments(bindingsFile.readAsStringSync());
    final RegExp windowsOpen = RegExp(
      r"Platform\.isWindows\)\s*return\s+DynamicLibrary\.open\('([^']+)'\)",
    );
    final RegExpMatch? match = windowsOpen.firstMatch(bindings);
    expect(match, isNotNull,
        reason: 'Windows 分支的 DynamicLibrary.open 调用形态变了，'
            '这条守卫读不到真相源了');
    final String dllName = match!.group(1)!;
    expect(dllName.endsWith('.dll'), isTrue,
        reason: 'Windows 侧应当加载 .dll，取到的是 $dllName');

    final String workflow = workflowFile.readAsStringSync();
    final int gate =
        workflow.indexOf('Verify Windows installer payload has the core runtime');
    final int iscc = workflow.indexOf('Compile installer (Inno Setup)');
    expect(gate, greaterThanOrEqualTo(0));
    expect(iscc, greaterThan(gate));
    final String gateBody = workflow.substring(gate, iscc);

    expect(
      gateBody.contains("'$dllName'"),
      isTrue,
      reason: '打包门禁没有校验 $dllName。两处各自硬编码这个名字，'
          '改了一处不改另一处就会静默发出一个起不来的包'
          '（hoshidicts_ffi.dll → fushidicts_ffi.dll 那次就是这个形状）',
    );
  });
}
