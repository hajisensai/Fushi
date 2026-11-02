import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:path/path.dart' as p;

/// 4w_veZGiQ7：macOS（去沙盒后）/ Windows / Linux 上，错误日志、崩溃面包屑、闪退待报状态
/// 等诊断文件直落用户 `~/Documents` 根，与 Fushi 自己的 `<Documents>/Fushi/data` 分家。
/// 现在统一走 [AppPaths.diagnosticsDirectory]，旧位置的残留在首次解析时搬过去——搬迁
/// 发生在 `ErrorLogService.init` 读面包屑之前，上次的崩溃现场照样能恢复。
void main() {
  late Directory tmp;
  late Directory legacy;
  late Directory target;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fushi_diag_dir_test');
    legacy = Directory(p.join(tmp.path, 'Documents'))..createSync();
    target = Directory(p.join(tmp.path, 'support', 'logs'))
      ..createSync(recursive: true);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('只搬 Fushi 的诊断文件，用户文档原地不动', () async {
    File(p.join(legacy.path, 'error_log.txt')).writeAsStringSync('old log');
    File(
      p.join(legacy.path, 'crash_report_state.json'),
    ).writeAsStringSync('{}');
    File(
      p.join(legacy.path, 'activity_sync_breadcrumb.json'),
    ).writeAsStringSync('x');
    File(p.join(legacy.path, 'resume.docx')).writeAsStringSync('user file');
    Directory(p.join(legacy.path, 'Fushi', 'data')).createSync(recursive: true);

    final List<String> failures = await AppPaths.migrateLegacyDiagnostics(
      from: legacy,
      to: target,
    );

    expect(failures, isEmpty);
    expect(
      File(p.join(target.path, 'error_log.txt')).readAsStringSync(),
      'old log',
    );
    expect(
      File(p.join(target.path, 'crash_report_state.json')).existsSync(),
      isTrue,
    );
    expect(
      File(p.join(target.path, 'activity_sync_breadcrumb.json')).existsSync(),
      isTrue,
    );
    expect(File(p.join(legacy.path, 'error_log.txt')).existsSync(), isFalse);
    expect(
      File(p.join(legacy.path, 'resume.docx')).existsSync(),
      isTrue,
      reason: '用户自己的文件绝不能被碰',
    );
    expect(
      Directory(p.join(legacy.path, 'Fushi', 'data')).existsSync(),
      isTrue,
    );
  });

  test('新位置已有同名文件：以新位置为准，删掉旧残留', () async {
    File(p.join(legacy.path, 'error_log.txt')).writeAsStringSync('stale');
    File(p.join(target.path, 'error_log.txt')).writeAsStringSync('current');

    final List<String> failures = await AppPaths.migrateLegacyDiagnostics(
      from: legacy,
      to: target,
    );

    expect(failures, isEmpty);
    expect(
      File(p.join(target.path, 'error_log.txt')).readAsStringSync(),
      'current',
    );
    expect(File(p.join(legacy.path, 'error_log.txt')).existsSync(), isFalse);
  });

  test('旧位置的面包屑搬过来后，ErrorLogService.init 仍能做崩溃恢复', () async {
    File(
      p.join(legacy.path, 'lookup_crash_breadcrumb.txt'),
    ).writeAsStringSync('depth=2');

    await AppPaths.migrateLegacyDiagnostics(from: legacy, to: target);
    final ErrorLogService service = ErrorLogService.instance;
    await service.init(directoryOverride: target);

    expect(service.appDirectory?.path, target.path);
    expect(
      File(p.join(target.path, 'lookup_crash_breadcrumb.txt')).existsSync(),
      isFalse,
      reason: '读出即清',
    );
    expect(
      File(p.join(legacy.path, 'lookup_crash_breadcrumb.txt')).existsSync(),
      isFalse,
    );
    expect(
      service.entries.map((ErrorLogEntry e) => e.source),
      contains('Lookup.crashRecovered'),
    );
    // 恢复条目是 fire-and-forget 落盘：写完再让 tearDown 删临时目录（Windows 上
    // 在途写入持有句柄，删目录会 errno 32）。
    await service.flush();
  });

  test('源码守卫：lib/ 里直连 getApplicationDocumentsDirectory 只剩已审计的用户文件落点', () {
    // 诊断文件（错误日志 / 面包屑 / 诊断日志 / 闪退状态）一律经 AppPaths.diagnosticsDirectory；
    // 下面这些是逐个审计过的「用户可见文件 / 判据」落点，新增直连必须先过审计。
    const Set<String> allowed = <String>{
      'lib/src/storage/app_paths.dart',
      // 用户显式导出的视频片段（用户文件语义，移动端无「另存为」）。
      'lib/src/pages/implementations/video_fushi/clip_export.part.dart',
      'lib/src/pages/implementations/video_fushi/playback_remote.part.dart',
      // 桌面目录选择器的「文档」快捷入口（就是要指向用户文档）。
      'lib/src/platform/desktop/desktop_directory_service.dart',
      // 数据根迁移判「旧根是不是共享 Documents」（只比对路径，不写入）。
      'lib/src/sync/sync_settings_schema/data_root.part.dart',
      // 移动端浏览器下载在公共 Download 不可写时的私有回退。
      'lib/src/web_browser/tab_view/web_browser_downloader.dart',
      // 有声书存储的平台默认解析器（AppModel 会注入 AppPaths 解析器覆盖它）。
      'lib/src/media/audiobook/audiobook_storage_platform.dart',
    };
    final RegExp call = RegExp(r'\bgetApplicationDocumentsDirectory\b');
    final List<String> offenders = <String>[];
    for (final FileSystemEntity e in Directory(
      'lib',
    ).listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      final String rel = p.posix.joinAll(p.split(e.path));
      final bool hits = e.readAsLinesSync().any((String line) {
        final String code = line.trimLeft();
        return !code.startsWith('//') && call.hasMatch(code);
      });
      if (hits && !allowed.contains(rel)) offenders.add(rel);
    }
    expect(
      offenders,
      isEmpty,
      reason:
          '诊断文件必须走 AppPaths.diagnosticsDirectory（4w_veZGiQ7）；'
          '其它新直连先审计再进白名单',
    );
  });
}
