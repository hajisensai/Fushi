/// 在一次性后台 isolate 里，对同一份已打开的 SRS 库做只读的长活（导出 .apkg / 捐赠包）。
///
/// [SrsDbStore] 带着 Future、StreamController 与各种缓存，不能整个发到别的 isolate；能发的只有内核句柄号（原生句柄表
/// 里的编号，进程内通用，[SrsCore.address]）。所以这里与 worker 池（srs_core_workers.dart）、优化器
/// （srs_optimization_scheduler.dart）同一个办法：只把句柄号与几个打开参数带过去，在后台 isolate 里
/// [SrsCore.fromAddress] 包一次（不拥有、不关库），再按查词弹窗那条只读路子 [SrsDbStore.open] 一份
/// [SrsOpenMode.secondary] 副本——跳过开库时的注册类写入（`local_state` / `cache_config_set` / 内置笔记类型），
/// 只读身份、根上 ID 与本机状态。并发由内核负责：读命令走内核的只读连接池（WAL 快照读），与主 isolate 的写不互相
/// 阻塞。后台 isolate 的内核命令就地同步执行（[SrsCoreWorkers.runInlineInThisIsolate]），不另起 worker 池。
///
/// 时钟：后台副本的「此刻」冻结在交接那一刻主副本的可信时间（[SrsDbStore.now]），日界取主副本此刻的
/// [SrsDbStore.dayContext]（含远程复习的设备时区）——一次导出只取一次时间，冻结后与在主 isolate 上导出逐字节相同。
library;

import 'dart:io';
import 'dart:isolate';

import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi_engine/srs/srs_core_workers.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_style_store.dart';

/// 在后台 isolate 里重开一份只读副本所需的全部参数（都可发送）。
final class SrsStoreReopenSpec {
  const SrsStoreReopenSpec({
    required this.address,
    required this.libraryPath,
    required this.profileUid,
    required this.deviceId,
    required this.nowMs,
    required this.utcOffsetMin,
    required this.rolloverHour,
    required this.stylesRoot,
  });

  /// 内核句柄号（[SrsCore.address]）。
  final int address;

  /// 主 isolate 加载的原生库路径（[SrsCore.libraryPath]；null = 默认定位规则 / iOS 静态链接）。
  final String? libraryPath;
  final String profileUid;
  final String deviceId;

  /// 交接那一刻主副本的可信时间（毫秒）。
  final int nowMs;
  final int utcOffsetMin;
  final int rolloverHour;

  /// 共享样式目录（[SrsStyleStore.root]）；null = 主副本没装样式库。
  final String? stylesRoot;

  /// 取 [store] 此刻的打开参数。
  static Future<SrsStoreReopenSpec> of(SrsDbStore store) async {
    final SrsDayContext day = await store.dayContext();
    final (int nowMs, _) = store.now();
    return SrsStoreReopenSpec(
      address: store.core.address,
      libraryPath: store.core.libraryPath,
      profileUid: store.profileUid,
      deviceId: store.deviceId,
      nowMs: nowMs,
      utcOffsetMin: day.utcOffsetMin,
      rolloverHour: day.rolloverHour,
      stylesRoot: store.styles?.root.path,
    );
  }

  /// 在当前（后台）isolate 里打开只读副本。
  Future<SrsDbStore> open() {
    final int frozen = nowMs;
    final int offset = utcOffsetMin;
    final int rollover = rolloverHour;
    final String? styles = stylesRoot;
    return SrsDbStore.open(
      core: SrsCore.fromAddress(
        address,
        libraryPath: libraryPath,
        mode: SrsOpenMode.secondary,
      ),
      profileUid: profileUid,
      deviceId: deviceId,
      // 开机时钟恒 0：本机状态行里的校时锚点不会被认下（[SrsTrustedClock.restoreAnchor] 要求开机时钟不倒退），
      // 「此刻」恒等于交接时主副本的可信时间。
      trustedClock: SrsTrustedClock(
        wallClockMs: () => frozen,
        bootClockMs: () => 0,
      ),
      fallbackRolloverHour: () => rollover,
      localOffsetMin: () => offset,
      styles: styles == null ? null : SrsStyleStore(Directory(styles)),
    );
  }
}

/// 在一次性后台 isolate 里对 [store] 的同一份库跑 [body]（只读）。
///
/// [body] 连同它捕获的东西要能发送：在顶层函数里造闭包，只捕获路径、ID、选项这类值，别捕获 [SrsDbStore]、
/// `File` 以外的宿主对象（见 srs_core_workers.dart「发送」）。结果 [T] 同样要可发送。
Future<T> srsRunWithStoreInBackground<T>(
  SrsDbStore store,
  Future<T> Function(SrsDbStore background) body, {
  String debugName = 'srs-store-background',
}) async {
  final SrsStoreReopenSpec spec = await SrsStoreReopenSpec.of(store);
  return Isolate.run<T>(_backgroundBody(spec, body), debugName: debugName);
}

/// 后台 isolate 的入口闭包（顶层函数：只捕获 [spec] 与 [body]）。
Future<T> Function() _backgroundBody<T>(
  SrsStoreReopenSpec spec,
  Future<T> Function(SrsDbStore background) body,
) => () async {
  SrsCoreWorkers.runInlineInThisIsolate();
  return body(await spec.open());
};
