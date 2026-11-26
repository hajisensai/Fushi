import 'dart:io';

import 'package:test/test.dart';

/// BUG-5529 守卫：应用内更新不能因为 launcher 映射着随包 CRT 而装不上。
///
/// 现场：更新到 3.4.0 时 `{app}\msvcp140.dll` 换不掉（DeleteFile code 5），整包回滚。
/// 持有者是 /MD 编译的 `fushi_update_launcher.exe`——安装器刻意不杀的那个进程；机器没装
/// VC++ 运行库时它从（继承来的当前目录 =）安装目录加载了随包的 CRT。
///
/// 两层各钉一条：
///   ① launcher 静态链接 CRT（新版起根本不碰 `{app}` 里的 DLL）；
///   ② 安装器给杀不得的外部持有者映射着的根目录 DLL 改名让路，失败时放回原位
///      （给仍在跑旧 /MD launcher 的存量用户）。
void main() {
  String read(String path) {
    final File file = File(path);
    expect(file.existsSync(), isTrue, reason: 'missing ${file.absolute.path}');
    return file.readAsStringSync();
  }

  test('fushi_update_launcher 在独立目录里改成静态 CRT（/MT）', () {
    final String launcherCmake = read('windows/update_launcher/CMakeLists.txt');
    expect(
      launcherCmake,
      contains('add_executable(fushi_update_launcher WIN32'),
    );
    expect(
      launcherCmake,
      contains('string(REGEX REPLACE "/MD" "/MT"'),
      reason: '/MD 的 launcher 会导入 MSVCP140/VCRUNTIME140，从安装目录映射随包 CRT',
    );
    for (final String flag in <String>[
      'CMAKE_CXX_FLAGS_RELEASE',
      'CMAKE_CXX_FLAGS_PROFILE',
      'CMAKE_CXX_FLAGS_DEBUG',
    ]) {
      expect(launcherCmake, contains(flag), reason: '$flag 也要换成静态 CRT');
    }

    final String rootCmake = read('windows/CMakeLists.txt');
    expect(rootCmake, contains('add_subdirectory("update_launcher")'));

    // 运行库开关只能按目录改：留在 runner/ 里就会和 fushi.exe 共用 /MD。
    final String runnerCmake = read('windows/runner/CMakeLists.txt');
    expect(
      runnerCmake,
      isNot(contains('add_executable(fushi_update_launcher')),
      reason: 'launcher 必须在 windows/update_launcher/ 里定义',
    );
  });

  test('安装器给被外部进程映射着的根目录 DLL 改名让路，失败时放回', () {
    final String iss = read('windows/installer/fushi.iss');

    expect(iss, contains('procedure MakeWayForLockedRootDlls('));
    final int prepareAt = iss.indexOf('function PrepareToInstall(');
    expect(prepareAt, greaterThan(0));
    final String prepare = iss.substring(prepareAt);
    final int sweepAt = prepare.indexOf(
      'KillProcessesUnderDir(ExpandConstant(',
    );
    final int makeWayAt = prepare.indexOf(
      'MakeWayForLockedRootDlls(ExpandConstant(',
    );
    expect(sweepAt, greaterThanOrEqualTo(0));
    expect(
      makeWayAt,
      greaterThan(sweepAt),
      reason: '先杀能杀的（安装目录里的自家进程），只给杀不得的外部持有者让路',
    );

    // 让路之后安装没走完（回滚 / 中止 / 取消），必须把原件放回：回滚会删掉新建的文件，
    // 不放回 app 就缺 CRT 起不来。
    expect(iss, contains('procedure RestoreSetAsideDllsIfInstallFailed('));
    final int postAt = iss.indexOf('procedure CurStepChanged(');
    expect(postAt, greaterThan(0));
    expect(
      iss.substring(postAt),
      contains('FushiInstallReachedPostInstall := True;'),
      reason: '只有走到 ssPostInstall 才算装完，不再放回',
    );
    final String layout = read('windows/installer/md3_layout.iss');
    final int deinitAt = layout.indexOf('procedure DeinitializeSetup();');
    expect(deinitAt, greaterThanOrEqualTo(0));
    expect(
      layout.substring(deinitAt),
      contains('RestoreSetAsideDllsIfInstallFailed();'),
    );

    // 让路残留：装完清、卸载清。
    expect(iss, contains("FindFirst(ExpandConstant('{app}\\*.dll.*.old')"));
    expect(iss, contains(r'Type: files; Name: "{app}\*.dll.*.old"'));
  });
}
