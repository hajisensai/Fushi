/// 数据目录排他锁：同一个 `<data>` 同一时刻只允许一个 fushi_server 进程打开数据库。
///
/// `serve` 与所有离线命令（`withServerRuntime` 的用户）都在打开数据库**之前**拿
/// `<data>/fushi_server.lock` 的排他锁，非阻塞：拿不到就以 75 拒绝。锁是 OS 文件锁
/// （POSIX fcntl / Windows LockFileEx），进程一死自动释放，没有「陈旧锁文件」要人清。
///
/// 为什么离线命令一律拒绝、连 `status` / `pair ls` 这类看着只读的也不放行：
/// SQLite WAL 本身允许跨进程「一写多读」，但 `withServerRuntime` 打开运行时这一步
/// 就不是只读的——Drift 打开即跑 schema 迁移、`ServerPrefs.warmUp` /
/// `ServerIdentity.loadOrCreate` 会补写偏好行、缺 admin_token 时还会改写配置文件；
/// 迁移与 serve 的写事务并发是真实的损坏 / `SQLITE_BUSY` 风险。只读查询请走
/// `fushi_server ctl …`（经运行中 serve 的 admin API，读的是同一个连接）。
///
/// 锁住的是文件里远离内容的一个字节（[_kLockRegionStart]），持有者信息（pid / 模式 /
/// WebUI 地址）以一行 JSON 写在文件开头：Windows 的 LockFileEx 是强制锁，被锁的区间
/// 别的进程读不了，错开之后拿不到锁的一方仍能读出「谁占着」做提示。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

const String kServerLockFileName = 'fushi_server.lock';

const int _kLockRegionStart = 1 << 20;

/// 锁文件里记录的持有者（读不出来的字段为 null）。
class ServerLockHolder {
  const ServerLockHolder({this.pid, this.mode, this.command, this.admin});

  final int? pid;

  /// `serve` 或 `offline`。
  final String? mode;

  /// 离线命令的命令行摘要（`audiobook align` …）。
  final String? command;

  /// serve 的 WebUI / admin API 地址。
  final String? admin;

  bool get isServe => mode == 'serve';

  static ServerLockHolder? parse(String content) {
    final String line = content.trim().split('\n').first.trim();
    if (line.isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(line);
      if (decoded is! Map<String, Object?>) return null;
      return ServerLockHolder(
        pid: decoded['pid'] is int ? decoded['pid']! as int : null,
        mode: decoded['mode'] is String ? decoded['mode']! as String : null,
        command: decoded['command'] is String ? decoded['command']! as String : null,
        admin: decoded['admin'] is String ? decoded['admin']! as String : null,
      );
    } on FormatException {
      return null;
    }
  }
}

/// 数据目录被别的进程占着。
class ServerDataLockedException implements Exception {
  const ServerDataLockedException({required this.dataDir, required this.lockPath, this.holder});

  final String dataDir;
  final String lockPath;
  final ServerLockHolder? holder;

  /// 给用户的一句话提示。
  String describe() {
    final ServerLockHolder? h = holder;
    final String pid = h?.pid == null ? '' : 'pid ${h!.pid}';
    if (h != null && h.isServe) {
      final String detail = <String>[
        pid,
        if (h.admin != null) 'WebUI ${h.admin}',
      ].where((String s) => s.isNotEmpty).join('，');
      return 'serve 正在运行（${detail.isEmpty ? '数据目录 $dataDir' : detail}），'
          '请改用 `fushi_server ctl …` 或先停止 serve';
    }
    if (h != null && h.mode == 'offline') {
      final String detail = <String>[pid, ?h.command].where((String s) => s.isNotEmpty).join('：');
      return '另一条 fushi_server 离线命令正在使用数据目录 $dataDir'
          '${detail.isEmpty ? '' : '（$detail）'}，等它结束后再试';
    }
    return '数据目录 $dataDir 正被另一个 fushi_server 进程占用（锁文件 $lockPath），'
        '若是 serve 请改用 `fushi_server ctl …` 或先停止 serve';
  }

  @override
  String toString() => describe();
}

/// 一把已持有的数据目录锁；[release] 之前本进程独占该数据目录。
class ServerDataLock {
  ServerDataLock._(this.file, this._raf, this.mode, this.command);

  final File file;
  final RandomAccessFile _raf;
  final String mode;
  final String? command;
  bool _released = false;

  /// 非阻塞拿 `<dataDir>/fushi_server.lock` 的排他锁；被占时抛 [ServerDataLockedException]。
  ///
  /// [mode] 是 `serve` 或 `offline`；[command] 写进锁文件给被拒的一方看。
  static Future<ServerDataLock> acquire(String dataDir, {required String mode, String? command}) async {
    final File file = File(p.join(dataDir, kServerLockFileName));
    await file.parent.create(recursive: true);
    // append：打开不截断——别人持有时不能把他写的持有者信息清掉。
    final RandomAccessFile raf = await file.open(mode: FileMode.append);
    try {
      await raf.lock(FileLock.exclusive, _kLockRegionStart, _kLockRegionStart + 1);
    } on FileSystemException {
      await raf.close();
      throw ServerDataLockedException(dataDir: dataDir, lockPath: file.path, holder: await readHolder(file));
    }
    final ServerDataLock lock = ServerDataLock._(file, raf, mode, command);
    await lock.update();
    return lock;
  }

  /// 读锁文件开头的持有者信息（**不要**在持有锁的进程里调：POSIX 下关闭同一文件的
  /// 任意 fd 会释放本进程在该文件上的全部 fcntl 锁）。
  static Future<ServerLockHolder?> readHolder(File file) async {
    try {
      return ServerLockHolder.parse(await file.readAsString());
    } on FileSystemException {
      return null;
    }
  }

  /// 重写持有者信息（serve 起好 WebUI 后补上 [admin] 地址）。
  Future<void> update({String? admin}) async {
    if (_released) return;
    await _raf.truncate(0);
    await _raf.setPosition(0);
    await _raf.writeString(
      '${jsonEncode(<String, Object?>{'pid': pid, 'mode': mode, 'command': ?command, 'admin': ?admin, 'startedAt': DateTime.now().toIso8601String()})}\n',
    );
    await _raf.flush();
  }

  /// 清空持有者信息并放锁（关闭句柄即释放 OS 锁）。锁文件本身留着：删文件会和
  /// 正在 open 它的下一个进程竞争，拿到两把「不同文件」上的锁。
  Future<void> release() async {
    if (_released) return;
    _released = true;
    try {
      await _raf.truncate(0);
    } on FileSystemException {
      // 清不掉不要紧：信息只在锁被占时才被读。
    }
    await _raf.close();
  }
}
