/// 测试辅助进程：拿住 `<dataDir>` 的数据目录锁，打印 `locked` 后等 stdin 关闭再放锁退出。
///
/// 用法：`dart test/support/hold_data_lock.dart <dataDir> <serve|offline> [command]`
///
/// 必须是独立进程：POSIX fcntl 锁按进程计，同一进程里再拿一次不会冲突，测不出互斥。
library;

import 'dart:io';

import 'package:fushi_server/src/server_data_lock.dart';

Future<void> main(List<String> args) async {
  final ServerDataLock lock = await ServerDataLock.acquire(
    args[0],
    mode: args[1],
    command: args.length > 2 ? args[2] : null,
  );
  if (args[1] == 'serve') await lock.update(admin: 'http://127.0.0.1:38766');
  stdout.writeln('locked');
  await stdout.flush();
  await stdin.drain<void>();
  await lock.release();
}
