/// serve 里的自动整机备份计时器（D14）：启动时先做中断检测，之后启动后 [initialDelay] 查一次、每
/// [checkInterval] 查一次，到期就跑（[ServerBackupService.startAutomatic]）。
///
/// 只在 serve 进程里跑：serve 整个生命周期持数据目录锁，所以它永远不会与离线还原 / 另一个进程同时动数据目录。
/// [stop] 取消计时器、不再开始新的一轮，并等在跑的那一轮写完（库要等它写完才关）。
library;

import 'dart:async';

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_server/src/backup/server_backup_service.dart';

class ServerBackupScheduler {
  ServerBackupScheduler(
    this.service, {
    this.checkInterval = const Duration(minutes: 15),
    this.initialDelay = const Duration(seconds: 30),
  });

  final ServerBackupService service;

  /// 到期检查周期（同 app 桌面端）。
  final Duration checkInterval;

  /// 启动后第一次检查的延迟：让启动扫描 / 复习库打开先走完。
  final Duration initialDelay;

  Timer? _first;
  Timer? _periodic;
  Future<void>? _tick;
  bool _stopped = false;

  /// 中断检测 + 挂上计时器。
  Future<void> start() async {
    try {
      await service.recoverInterrupted();
    } on Object catch (e, stack) {
      engineLog.log('ServerBackupScheduler.recover', e, stack);
    }
    if (_stopped) return;
    _first = Timer(initialDelay, check);
    _periodic = Timer.periodic(checkInterval, (_) => check());
  }

  /// 查一次（到期就跑并等它写完）。上一轮还没完、或已停，什么都不做。
  Future<void> check() {
    if (_stopped || _tick != null) return _tick ?? Future<void>.value();
    final Future<void> tick = () async {
      try {
        await service.runAutomatic();
      } on Object catch (e, stack) {
        engineLog.log('ServerBackupScheduler.check', e, stack);
      }
    }();
    _tick = tick.whenComplete(() => _tick = null);
    return _tick!;
  }

  /// 停：取消计时器，等在跑的那一轮（以及别的来源的作业）结束。
  Future<void> stop() async {
    _stopped = true;
    _first?.cancel();
    _periodic?.cancel();
    _first = null;
    _periodic = null;
    await _tick;
    await service.idle();
  }
}
