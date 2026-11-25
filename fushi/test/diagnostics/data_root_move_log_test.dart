import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/diagnostics/data_root_move_log.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// BUG-5467：迁移成功后进程马上重启，内存里的诊断日志随之丢失。摘要必须落盘，重启后
/// （以及之后每次启动）重新记进诊断日志，报告里才看得到上次书库是什么时候、怎么搬的。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  List<ErrorLogEntry> lastMoveEntries() => ErrorLogService
      .instance
      .diagnosticEntries
      .where((ErrorLogEntry e) => e.source == kDataRootLastMoveSource)
      .toList();

  test('迁移摘要带时间落盘，模拟重启后的启动再记一条', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final int before = lastMoveEntries().length;

    await recordDataRootMove(
      'a -> b: copy + verify, source deleted\ncopied 2 files, 0.0 MB, 0.1 s',
      finishedAt: DateTime(2026, 11, 25, 13, 58, 44),
    );

    final SharedPreferences sp = await SharedPreferences.getInstance();
    final String stamped = sp.getString(kDataRootLastMovePrefKey)!;
    expect(stamped, startsWith('2026-11-25T13:58:44'));
    expect(stamped, contains('copied 2 files'));
    expect(lastMoveEntries().length, before + 1, reason: '迁移进程自己也记一条');

    // 新进程：内存日志是空的，只剩落盘的那份。
    await logLastDataRootMove();
    expect(lastMoveEntries().length, before + 2);
    expect(lastMoveEntries().last.error, stamped);
  });

  test('从没迁移过：启动时不记', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final int before = lastMoveEntries().length;
    await logLastDataRootMove();
    expect(lastMoveEntries().length, before);
  });
}
