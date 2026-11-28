/// 互联 host 的同步清单端点（合集 / 标签 / 作品图谱）在**后台 isolate** 里现算、
/// 编解码，host 所在 isolate 只搬字节（BUG-5606）。
///
/// app 当 host 时 HTTP 服务与 UI 同一个 isolate：用户规模（3k 合集 / 85k 成员）的
/// 合集清单是 7 MB JSON，旧实现每个 GET 都在主 isolate 里映射全部 DB 行、拼清单、
/// `canonicalJson`，POST 再在主 isolate 里 `jsonDecode` 7 MB 请求体 + 合并 + 编码，
/// 实测单次停顿 100～300 ms，对端每轮同步都打一次，电脑上的界面跟着一卡一卡。
///
/// 这里的命令都跑在 [AggregateSyncOwner]（同一个库的后台连接）里：读库、组装、
/// 合并、编码、ETag 摘要都在那边做，交回的只有字节（[TransferableTypedData]，不在
/// 接收方拷贝）与少量结果。合集合并的**落库**仍在调用方 isolate 做（它要回收合集
/// 封面文件，路径根与图片缓存是 host 进程装配的全局钩子，后台 isolate 里没有）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:drift/drift.dart' show TableUpdateQuery;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/collections/library_organize/organize_convergence.dart'
    show
        ConvergencePlan,
        loadConvergenceCollections,
        planOrganizeConvergenceWithProposals;
import 'package:fushi_engine/sync/aggregate_sync_owner.dart';
import 'package:fushi_engine/sync/collection_manifest.dart';
import 'package:fushi_engine/sync/collection_sync_engine.dart';
import 'package:fushi_engine/sync/http_etag.dart' show weakContentEtag;
import 'package:fushi_engine/sync/media_link_sync.dart';
import 'package:fushi_engine/sync/tag_sync.dart';

/// 走后台现算的三种清单端点。
enum HostManifestKind {
  /// `/api/library/collections`
  collections,

  /// `/api/library/tags`
  tags,

  /// `/api/library/media-links`
  mediaLinks,
}

/// 编码好的清单报文体（UTF-8 JSON）+ 它的弱 ETag（`weakContentEtag`，可直接放进
/// 响应头）。
final class HostManifestBody {
  const HostManifestBody({required this.bytes, required this.etag});

  final Uint8List bytes;
  final String etag;
}

/// POST 合并的结果：并入后的清单报文体，或请求体不合法（端点回 400，什么都没写）。
sealed class HostManifestMergeResult {
  const HostManifestMergeResult();
}

/// 合并成功：并入后的 host 清单报文体。
final class HostManifestMerged extends HostManifestMergeResult {
  const HostManifestMerged(this.bytes);

  final Uint8List bytes;
}

/// 请求体不是合法清单（坏 JSON / 顶层不是 object / 版本或字段非法）。
final class HostManifestRejected extends HostManifestMergeResult {
  const HostManifestRejected(this.message);

  /// 400 响应体（与旧端点同形：`Invalid JSON` / `Invalid manifest: ...`）。
  final String message;
}

/// host 端「清单报文体在后台现算」的**可选**能力。与 [TagSyncHost] 同范式：不扩大
/// `FushiLibraryHostService` 主接口（十余个测试 fake 全量 implements），server 用
/// `is` 探测——实现了就走字节进字节出，没实现退回对象接口在调用方 isolate 编码。
abstract interface class HostManifestBodyHost {
  /// [kind] 清单的当前报文体与 ETag。纯读。
  Future<HostManifestBody> getManifestBody(HostManifestKind kind);

  /// 把 client 上报的清单报文体 [body]（[encodingName] = 请求声明的 charset，缺省
  /// UTF-8）并入 host，返回并入后的清单报文体。
  Future<HostManifestMergeResult> mergeManifestBody(
    HostManifestKind kind,
    Uint8List body, {
    String? encodingName,
  });
}

/// 后台所有者里的一份已解码清单（POST 的第一步解码在锁外做，结果暂存在所有者的
/// session 里，交给锁内的合并命令）。
final class _DecodedIncoming {
  const _DecodedIncoming(this.manifest);

  final Object manifest;
}

/// 在后台所有者里读 [kind] 清单并编码，交回报文体与 ETag。
AggregateOwnerCommand<(TransferableTypedData, String)>
encodeLocalManifestCommand(HostManifestKind kind) =>
    (AggregateOwnerContext context) async {
      final String json = switch (kind) {
        HostManifestKind.collections => (await loadLocalCollectionManifest(
          context.db,
        )).canonicalJson(),
        HostManifestKind.tags => (await loadLocalTagManifest(
          context.db,
        )).canonicalJson(),
        HostManifestKind.mediaLinks => (await loadLocalMediaLinkManifest(
          context.db,
        )).canonicalJson(),
      };
      final Uint8List bytes = utf8.encode(json);
      return (
        TransferableTypedData.fromList(<TypedData>[bytes]),
        weakContentEtag(bytes),
      );
    };

/// 在后台所有者里解码 client 上报的 [kind] 清单，暂存进 session；不合法返回 400
/// 响应体，合法返回 null。
AggregateOwnerCommand<String?> decodeIncomingManifestCommand(
  HostManifestKind kind,
  TransferableTypedData body,
  String? encodingName,
) => (AggregateOwnerContext context) {
  context.session = null;
  final Uint8List bytes = body.materialize().asUint8List();
  final Object? decoded;
  try {
    if (bytes.isEmpty) return 'Invalid JSON';
    final Encoding encoding =
        (encodingName == null ? null : Encoding.getByName(encodingName)) ??
        utf8;
    decoded = jsonDecode(encoding.decode(bytes));
  } on Object {
    return 'Invalid JSON';
  }
  if (decoded is! Map) return 'Invalid JSON';
  final Map<String, dynamic> json = decoded is Map<String, dynamic>
      ? decoded
      : Map<String, dynamic>.from(decoded);
  try {
    context.session = _DecodedIncoming(switch (kind) {
      HostManifestKind.collections => CollectionManifest.fromJson(json),
      HostManifestKind.tags => TagManifest.fromJson(json),
      HostManifestKind.mediaLinks => MediaLinkManifest.fromJson(json),
    });
  } on FormatException catch (e) {
    return 'Invalid manifest: $e';
  }
  return null;
};

/// 合集 POST 的锁内计算（后台所有者里）：拿 session 里已解码的对端清单与本地清单
/// 合并，交回本地变更集（交给调用方落库）与合并后清单的报文体。
AggregateOwnerCommand<(List<CollectionManifestEntry>, TransferableTypedData)>
mergeIncomingCollectionsCommand(int lastSyncedAtMs) =>
    (AggregateOwnerContext context) async {
      final Object? session = context.session;
      context.session = null;
      final CollectionManifest incoming =
          (session! as _DecodedIncoming).manifest as CollectionManifest;
      final CollectionSyncOutcome outcome =
          await mergeIncomingCollectionManifest(
            context.db,
            incoming,
            lastSyncedAtMs: lastSyncedAtMs,
          );
      return (
        outcome.changes.entries,
        TransferableTypedData.fromList(<TypedData>[
          utf8.encode(outcome.merged.canonicalJson()),
        ]),
      );
    };

/// 合集 POST 锁内第一步（后台所有者里）：透传成员行升格为本地书 uid
/// （[FushiDatabase.reconcileEpubCollectionMemberKeys]，纯 DB，先全表读计划）。
AggregateOwnerCommand<void> reconcileCollectionMemberKeysCommand() =>
    (AggregateOwnerContext context) async {
      await context.db.reconcileEpubCollectionMemberKeys();
    };

/// 合集 POST 锁内末步的判据（后台所有者里）：整理器合集收敛有没有事可做（有可并
/// 的或有提议）。没有就不必在调用方 isolate 里再全表读一遍；有才由调用方跑
/// `convergeCollectionsAfterSync`（它可能删合集、回收封面文件，要 host 进程的钩子）。
AggregateOwnerCommand<bool> collectionsNeedConvergenceCommand() =>
    (AggregateOwnerContext context) async {
      final ConvergencePlan plan = planOrganizeConvergenceWithProposals(
        await loadConvergenceCollections(context.db),
      );
      return plan.merges.isNotEmpty || plan.proposals.isNotEmpty;
    };

/// 标签 / 作品图谱 POST 的锁内步骤（后台所有者里）：按 LWW 落库后重读并编码。
/// 这两种只写 DB 行，不碰文件，可以整段在后台做。
AggregateOwnerCommand<TransferableTypedData> applyIncomingLwwManifestCommand(
  HostManifestKind kind,
) => (AggregateOwnerContext context) async {
  final Object? session = context.session;
  context.session = null;
  final Object incoming = (session! as _DecodedIncoming).manifest;
  final String json;
  switch (kind) {
    case HostManifestKind.tags:
      await applyTagManifest(context.db, incoming as TagManifest);
      json = (await loadLocalTagManifest(context.db)).canonicalJson();
    case HostManifestKind.mediaLinks:
      await applyMediaLinkManifest(context.db, incoming as MediaLinkManifest);
      json = (await loadLocalMediaLinkManifest(context.db)).canonicalJson();
    case HostManifestKind.collections:
      throw ArgumentError.value(kind, 'kind', 'collections merge in two steps');
  }
  return TransferableTypedData.fromList(<TypedData>[utf8.encode(json)]);
};

/// 一份清单报文体的缓存：数据源表有写入就作废（[invalidations]），作废后的第一个
/// 读者在后台重算（[compute]），并发读者共用同一次重算。
///
/// 订阅只在「手上有缓存或正在算」时挂着：作废时退订，下一次读再订——没人读的
/// 清单不留任何监听，host 服务对象被丢弃后最多再收一次作废就彻底放手。
///
/// 正确性：先订阅再开算；算的途中来过作废（代数变了）就只把结果交给这一批读者、
/// 不进缓存，下一个读者重算。所以缓存里的报文体一定读自「最后一次作废之后」。
///
/// **投影依赖**（可选，[projectedUpdates] + [projection]）：有些表写得勤、但清单
/// 只依赖它们的一小块投影（合集清单之于下载任务表：只看「哪些合集由下载管理」）。
/// 这些表的写入不直接作废，只把缓存标成「待核对」；下一个读者先在调用方读一次
/// [projection]（廉价），与缓存报文体当初的投影相等就继续用，不等才重算。保证
/// 「缓存报文体的投影 = 记下的投影」：重算前先读投影，读投影到重算结束之间来过
/// 投影表写入就不进缓存（那段时间里投影可能先变后变回，记下的值不再可信）。
final class HostManifestBodyCache {
  HostManifestBodyCache({
    required Stream<Object?> Function() invalidations,
    required Future<HostManifestBody> Function() compute,
    Stream<Object?> Function()? projectedUpdates,
    Future<String> Function()? projection,
  }) : assert(
         (projectedUpdates == null) == (projection == null),
         'projectedUpdates 与 projection 要么都给、要么都不给',
       ),
       _invalidations = invalidations,
       _compute = compute,
       _projectedUpdates = projectedUpdates,
       _projection = projection;

  final Stream<Object?> Function() _invalidations;
  final Future<HostManifestBody> Function() _compute;
  final Stream<Object?> Function()? _projectedUpdates;
  final Future<String> Function()? _projection;

  StreamSubscription<Object?>? _subscription;
  StreamSubscription<Object?>? _projectedSubscription;
  int _generation = 0;
  int _projectedGeneration = 0;
  HostManifestBody? _body;

  /// [_body] 读自的投影（无投影依赖时恒 null）。
  String? _bodyProjection;

  /// [_body] 已核对到的投影表写入代数：小于 [_projectedGeneration] 即「待核对」。
  int _bodyProjectedGeneration = 0;
  Future<HostManifestBody>? _inFlight;
  int _inFlightGeneration = -1;
  int _inFlightProjectedGeneration = -1;

  /// 当前报文体（命中缓存直接给，待核对先核对投影，否则后台重算）。
  Future<HostManifestBody> get() {
    // 退订在 [_invalidate] 里（作废即退订，见类注释）。
    _subscription ??= _invalidations().listen((Object? _) => _invalidate());
    final Stream<Object?> Function()? projectedUpdates = _projectedUpdates;
    if (projectedUpdates != null) {
      _projectedSubscription ??= projectedUpdates().listen(
        (Object? _) => _projectedGeneration++,
      );
    }
    final HostManifestBody? cached = _body;
    if (cached != null && _bodyProjectedGeneration == _projectedGeneration) {
      return Future<HostManifestBody>.value(cached);
    }
    final Future<HostManifestBody>? running = _inFlight;
    if (running != null &&
        _inFlightGeneration == _generation &&
        _inFlightProjectedGeneration == _projectedGeneration) {
      return running;
    }
    final int generation = _generation;
    final int projected = _projectedGeneration;
    final Future<HostManifestBody> refreshing = _refresh(generation, projected);
    _inFlight = refreshing;
    _inFlightGeneration = generation;
    _inFlightProjectedGeneration = projected;
    refreshing
        .then<void>((HostManifestBody _) {}, onError: (Object _) {})
        .whenComplete(() {
          if (identical(_inFlight, refreshing)) _inFlight = null;
        });
    return refreshing;
  }

  /// [generation] / [projected] = 本次读开始时的两种代数（[projected] 在读投影之前
  /// 取，见类注释的保证）。
  Future<HostManifestBody> _refresh(int generation, int projected) async {
    final Future<String> Function()? projection = _projection;
    final String? key = projection == null ? null : await projection();
    final HostManifestBody? cached = _body;
    if (cached != null && generation == _generation) {
      if (key == _bodyProjection) {
        // 投影没变：缓存的报文体就是此刻的清单。核对到 [projected] 为止，之后再来
        // 的投影表写入仍让它待核对。
        if (_bodyProjectedGeneration < projected) {
          _bodyProjectedGeneration = projected;
        }
        return cached;
      }
      _body = null;
      _bodyProjection = null;
    }
    final HostManifestBody body = await _compute();
    if (generation == _generation && projected == _projectedGeneration) {
      _body = body;
      _bodyProjection = key;
      _bodyProjectedGeneration = projected;
    }
    return body;
  }

  /// 直接作废（调用方确知数据变了时用；表写入经 [invalidations] 自动作废）。
  void invalidate() => _invalidate();

  void _invalidate() {
    _generation++;
    _body = null;
    _bodyProjection = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
    unawaited(_projectedSubscription?.cancel());
    _projectedSubscription = null;
  }
}

/// [db] 里合集清单数据源表（[collectionManifestSourceTables]）的写入流。
Stream<Object?> collectionManifestInvalidations(FushiDatabase db) =>
    db.tableUpdates(
      TableUpdateQuery.onAllTables(collectionManifestSourceTables(db)),
    );

/// [db] 里合集清单投影依赖表（[collectionManifestProjectedTables]）的写入流；配
/// [collectionManifestProjection] 交给 [HostManifestBodyCache]。
Stream<Object?> collectionManifestProjectedUpdates(FushiDatabase db) =>
    db.tableUpdates(
      TableUpdateQuery.onAllTables(collectionManifestProjectedTables(db)),
    );
