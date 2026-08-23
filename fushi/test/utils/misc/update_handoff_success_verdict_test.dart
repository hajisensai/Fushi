import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/update_handoff.dart';

/// BUG-1786 ③：握手凭什么说「更新成功」。
///
/// 现场取到的真实值（用户机器 `updates\*.meta.json` + app 关于页）：
///   targetVersion  = '2.2.1-debug.12067'   （下载 meta 里的 version 字段）
///   currentVersion = '2.2.1'               （Windows 上 package_info 读 exe 版本资源，
///                                            语义版本，**不带** -debug.N 后缀）
/// 旧判据是 `currentVersion >= targetVersion` 的 SemVer 比较，而 SemVer 规定
/// 「正式版 > 同号预发布版」⇒ 2.2.1 > 2.2.1-debug.12067 ⇒ **恒为真**。
/// 也就是说 debug/beta 通道上这个判据从来不看装没装上，永远宣告成功。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fushi-handoff-verdict');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  File markerWith({
    required String targetVersion,
    required String innoLogPath,
  }) {
    final File marker = WindowsUpdateHandoff.markerFile(tempDir);
    marker.writeAsStringSync(
      jsonEncode(<String, dynamic>{
        'targetVersion': targetVersion,
        'installerPath': '${tempDir.path}\\setup.exe',
        'innoLogPath': innoLogPath,
        'startedAt': DateTime.now().toUtc().toIso8601String(),
        'installerLaunchSucceeded': true,
      }),
    );
    return marker;
  }

  File writeInnoLog(String name, String contents) {
    final File log = File('${tempDir.path}${Platform.pathSeparator}$name');
    log.writeAsStringSync(contents);
    return log;
  }

  test('中止回滚的安装不再被判成 installed（Inno 日志否决版本号）', () async {
    // 用户现场那次失败的日志尾巴。
    final File log = writeInnoLog('aborted.log', '''
2026-08-23 14:58:28.320   DeleteFile: The existing file appears to be in use (5). Retrying.
2026-08-23 14:58:32.352   User canceled the installation process.
2026-08-23 14:58:32.352   Rolling back changes.
2026-08-23 14:58:32.353   Uninstallation process succeeded.
''');
    final File marker = markerWith(
      targetVersion: '2.2.1-debug.12067',
      innoLogPath: log.path,
    );

    final WindowsUpdateHandoffResult? result =
        await WindowsUpdateHandoff.reconcile(
      markerFile: marker,
      currentVersion: '2.2.1',
    );

    expect(result, isNotNull);
    expect(
      result!.status,
      isNot(WindowsUpdateHandoffStatus.installed),
      reason: '整包回滚了，不能报成功——这正是用户「明明没更新成功却说成功」的那一下',
    );
  });

  test('真正装完的安装仍判 installed（没把成功的更新误报成失败）', () async {
    final File log = writeInnoLog('ok.log', '''
2026-08-23 15:00:01.000   Successfully installed the file.
2026-08-23 15:00:02.000   Installation process succeeded.
''');
    final File marker = markerWith(
      targetVersion: '2.2.1-debug.12067',
      innoLogPath: log.path,
    );

    final WindowsUpdateHandoffResult? result =
        await WindowsUpdateHandoff.reconcile(
      markerFile: marker,
      currentVersion: '2.2.1',
    );

    expect(result, isNotNull);
    expect(result!.status, WindowsUpdateHandoffStatus.installed);
  });

  test('日志根本不存在时不得报成功——那意味着安装压根没跑起来', () async {
    // 这是旧版本号判据最危险的残留面：Inno 没运行 / 日志写不出来时，
    // 「2.2.1 >= 2.2.1-debug.12067」恒真会把「什么都没发生」也说成更新成功。
    final File marker = markerWith(
      targetVersion: '2.2.1-debug.12067',
      innoLogPath: '${tempDir.path}${Platform.pathSeparator}missing.log',
    );

    final WindowsUpdateHandoffResult? result =
        await WindowsUpdateHandoff.reconcile(
      markerFile: marker,
      currentVersion: '2.2.1',
    );

    expect(result, isNotNull);
    expect(
      result!.status,
      isNot(WindowsUpdateHandoffStatus.installed),
      reason: '没有任何安装成功的证据时，默认不能是成功',
    );
  });
}
