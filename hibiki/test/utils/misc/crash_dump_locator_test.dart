import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/crash_dump_locator.dart';

/// TODO-607 P0-3/④：CrashDumpLocator 纯函数单测（host 可跑——不碰 native，只验
/// 「定位 %LOCALAPPDATA%\Hibiki\crashdumps + 列 .dmp 按 mtime 降序」）。
void main() {
  group('CrashDumpLocator.resolveDumpDirectory', () {
    test('非 Windows 返回 null（minidump 仅 Windows runner 写）', () {
      expect(
        CrashDumpLocator.resolveDumpDirectory(
          isWindows: false,
          localAppData: r'C:\Users\x\AppData\Local',
        ),
        isNull,
      );
    });

    test('LOCALAPPDATA 缺失 / 空返回 null', () {
      expect(
        CrashDumpLocator.resolveDumpDirectory(
            isWindows: true, localAppData: null),
        isNull,
      );
      expect(
        CrashDumpLocator.resolveDumpDirectory(
            isWindows: true, localAppData: ''),
        isNull,
      );
    });

    test(r'Windows 下拼出 Hibiki\crashdumps（与 native crash_dump.cpp 同确定路径）', () {
      final Directory? dir = CrashDumpLocator.resolveDumpDirectory(
        isWindows: true,
        localAppData: r'C:\Users\x\AppData\Local',
      );
      expect(dir, isNotNull);
      expect(dir!.path, r'C:\Users\x\AppData\Local\Hibiki\crashdumps');
    });
  });

  group('CrashDumpLocator.listDumps', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('hibiki_crashdump_test');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('目录不存在返回空列表（从未崩过）', () {
      final Directory missing = Directory('${tmp.path}/nope');
      expect(CrashDumpLocator.listDumps(missing), isEmpty);
    });

    test('空目录返回空列表', () {
      expect(CrashDumpLocator.listDumps(tmp), isEmpty);
    });

    test('只列 .dmp、忽略其它文件，按修改时间降序（最近崩溃在前）', () {
      // 三个 dmp + 一个无关文件。
      final File older = File('${tmp.path}/hibiki-100-1000.dmp')
        ..writeAsStringSync('a');
      final File newer = File('${tmp.path}/hibiki-200-2000.dmp')
        ..writeAsStringSync('b');
      final File newest = File('${tmp.path}/hibiki-300-3000.dmp')
        ..writeAsStringSync('c');
      File('${tmp.path}/wgc_capture.log').writeAsStringSync('not a dump');

      // 显式拉开 mtime，使排序确定（文件系统 mtime 粒度可能很粗）。
      final DateTime base = DateTime(2026, 1, 1, 12);
      older.setLastModifiedSync(base);
      newer.setLastModifiedSync(base.add(const Duration(minutes: 5)));
      newest.setLastModifiedSync(base.add(const Duration(minutes: 10)));

      final List<File> dumps = CrashDumpLocator.listDumps(tmp);
      expect(dumps.length, 3, reason: '只数 .dmp，不含 wgc_capture.log');
      final List<String> names =
          dumps.map((File f) => f.uri.pathSegments.last).toList();
      expect(
        names,
        <String>[
          'hibiki-300-3000.dmp',
          'hibiki-200-2000.dmp',
          'hibiki-100-1000.dmp',
        ],
        reason: '按 mtime 降序：最近的崩溃排最前',
      );
    });

    test('大写 .DMP 也算（扩展名匹配不区分大小写）', () {
      File('${tmp.path}/HIBIKI-1-1.DMP').writeAsStringSync('x');
      final List<File> dumps = CrashDumpLocator.listDumps(tmp);
      expect(dumps.length, 1);
    });
  });
}
