/// RWKV 排程的装配：app 与无头服务端（fushi_server）共用这一份，宿主只注入位置、HTTP 客户端与日志。
///
/// 「RWKV 牌组按 RWKV 回忆率出卡、没就绪就不出、绝不退回 FSRS-7 的到期日」由 store 的排队一处保证
/// （`SrsDbStore._instantInput`）；它只在 store 挂了 RWKV 服务（[SrsDbStore.rwkv]）时生效。所以每个对外出卡的
/// 宿主都必须在把库交出去之前调 [srsAttachRwkv]——没挂的 store 上 RWKV 牌组按存下的 FSRS-7 到期日排，那只留给
/// 不出卡的场合（裸 store 的单测、离线工具）。
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_rwkv_models.dart';
import 'package:fushi_engine/srs/srs_rwkv_service.dart';
import 'package:fushi_srs/fushi_srs.dart';

// [SrsRwkvBackend] 签名里的类型：经 [srsAttachRwkv] 的 openBackend 换后端的一方（测试替身）不必另外依赖
// fushi_rwkv。
export 'package:fushi_rwkv/fushi_rwkv.dart' show RwkvRows, RwkvScoreLookup;

/// RWKV 权重目录（`<support>/srs_rwkv/models`）：按需下载；也可以事先把权重文件放进来（校验通过即用）。
Directory srsRwkvModelsDir(Directory support) =>
    Directory(p.join(support.path, 'srs_rwkv', 'models'));

/// RWKV 状态快照目录（`<support>/srs_rwkv/state`，每个 profile 一份主快照 + 至多两份检查点）。
Directory srsRwkvStateDir(Directory support) =>
    Directory(p.join(support.path, 'srs_rwkv', 'state'));

/// 把 RWKV 排程服务挂到 [store] 上并返回它。对象本身很轻：后台 runtime、权重下载与全量回放只在
/// [srsRwkvStartIfUsed]（库里有 RWKV 牌组）或第一次给 RWKV 牌组排队时启动。
///
/// 宿主在关库 / 不再提供这份库之前 `await service.close()`（存快照、关后台 runtime）；关了的服务永远「没就绪」，
/// 这之后的排队不出 RWKV 牌组的复习卡。
///
/// [models] 缺省按 [support] 与 [createClient] 新建；[log] 收诊断消息；[threads] 0 = 全部核心。
/// [openBackend] 是测试接缝（把后台 runtime 换成替身），生产不传。
SrsRwkvService srsAttachRwkv(
  SrsDbStore store, {
  required Directory support,
  SrsRwkvModels? models,
  HttpClient Function()? createClient,
  void Function(String message)? log,
  int threads = 0,
  Future<SrsRwkvBackend> Function(File weights)? openBackend,
}) {
  final SrsRwkvService service = SrsRwkvService(
    store: store,
    models:
        models ??
        SrsRwkvModels(
          dir: srsRwkvModelsDir(support),
          createClient: createClient,
        ),
    snapshotDir: srsRwkvStateDir(support),
    threads: threads,
    openBackend: openBackend,
    log: log,
  );
  store.rwkv = service;
  return service;
}

/// 库里有按 RWKV 排程的牌组（参数归属牌组的本机算法是 RWKV）。
Future<bool> srsRwkvUsed(SrsDbStore store) async {
  final SrsDeckTree tree = await store.deckTree();
  return tree.decks.any(
    (SrsDeckView d) => tree.paramsOwner(d.id).localAlgorithm.usesRwkv,
  );
}

/// 库里有 RWKV 牌组就开始准备（下载权重 / 恢复快照 / 全量回放），不等它跑完；返回是否启动了。
/// 没有 RWKV 牌组时不启动：之后第一次给 RWKV 牌组排队时再启动。
Future<bool> srsRwkvStartIfUsed(
  SrsDbStore store,
  SrsRwkvService service, {
  required void Function(Object error, StackTrace stack) onError,
}) async {
  if (!await srsRwkvUsed(store)) return false;
  // 准备失败会转成「出错」状态；这里只兜没预料到的异常。
  unawaited(service.start().then<void>((_) {}, onError: onError));
  return true;
}
