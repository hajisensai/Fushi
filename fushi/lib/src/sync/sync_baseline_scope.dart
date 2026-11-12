/// 同步基线的远端作用域工具（BUG-4434）。
///
/// `sync_baselines` 的主键是 `(assetKey, dimension)`；按远端分槽不改表结构，只让
/// `dimension` 带上远端标签后缀（[remoteScopedKey]）。逻辑维度名（冲突上报、裁决簿
/// 用的那个）不变，只有落库的「存储维度」不同。
library;

import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/obfuscating_sync_backend.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_manager.dart'
    show progressBaselineDimensionOf;
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/webdav_ops.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/sync_channel_scope.dart';

/// 某作用域下 [logicalDimension] 的存储维度：[tag] 为 null（认不出的
/// 后端）→ 逻辑维度本身，即升级前的那一行；否则 `<逻辑维度>@<tag>`。
String baselineStorageDimension(String logicalDimension, String? tag) =>
    tag == null ? logicalDimension : remoteScopedKey(logicalDimension, tag);

/// 进程内领养记录：数据库 → 「源维度 → 目标维度」→ 那一次领养的 Future。并发调用方
/// await 同一个，领养只做一次；失败则移出，下次重试。
final Expando<Map<String, Future<void>>> _adoptions =
    Expando<Map<String, Future<void>>>('syncBaselineAdoptions');

/// 把升级前写下的无后缀旧行按 [adoption] 处理到 [tag] 作用域，并把 [predecessorTags]
/// （同一远端先前用过的作用域）的行并进来（[tag] 为 null 时什么都不做——那个作用域
/// 用的就是旧行）：
/// - [LegacyBaselineAdoption.move]：每个逻辑维度的旧行逐行搬到目标作用域后删除。
///   目标行不存在或与旧行相等 → 照搬；目标行已存在且不同 → 两行都删。旧行可能来自
///   降级期间（比目标行新），也可能来自曾经认不出 host 的老条目作用域（与目标行谁新
///   不可考，评审 correctness-3）——拿错的那份当共同祖先会把单边改动判错方向、静默
///   覆盖，宁可这一条首轮无基线（两端不同判冲突，不丢数据）。
/// - [LegacyBaselineAdoption.discard]：删除旧行（来源不可考）。
/// - [LegacyBaselineAdoption.keep]：旧行不动，不记进程内缓存。
/// - [predecessorTags]：每个前任作用域的行都按 move 的规则并入，与 [adoption] 无关
///   （前任作用域与当前作用域是同一台远端，见 `InterconnectHostScope.predecessorTags`）。
///
/// 每一对「源 → 目标」的判空 / 读源行 / 写目标 / 删源行在同一个事务里，进程内按
/// (db, 源, 目标) 只做一次。
Future<void> ensureBaselinesAdopted(
  FushiDatabase db, {
  required List<String> logicalDimensions,
  required String? tag,
  required LegacyBaselineAdoption adoption,
  List<String> predecessorTags = const <String>[],
}) async {
  if (tag == null) return;
  final Map<String, Future<void>> done = _adoptions[db] ??=
      <String, Future<void>>{};
  final List<Future<void>> waits = <Future<void>>[];
  void adopt(String source, String target, LegacyBaselineAdoption how) {
    final String key = '$source|$target';
    waits.add(
      done[key] ??= _adoptOne(db, source, target, how).catchError((
        Object e,
        StackTrace st,
      ) {
        done.remove(key);
        Error.throwWithStackTrace(e, st);
      }),
    );
  }

  for (final String logical in logicalDimensions) {
    final String storage = baselineStorageDimension(logical, tag);
    if (adoption != LegacyBaselineAdoption.keep) {
      adopt(logical, storage, adoption);
    }
    for (final String predecessor in predecessorTags) {
      if (predecessor == tag) continue;
      adopt(
        remoteScopedKey(logical, predecessor),
        storage,
        LegacyBaselineAdoption.move,
      );
    }
  }
  await Future.wait(waits);
}

Future<void> _adoptOne(
  FushiDatabase db,
  String source,
  String target,
  LegacyBaselineAdoption adoption,
) => db.transaction(() async {
  final Map<String, int> legacy = await db.getSyncBaselinesForDimension(source);
  if (legacy.isEmpty) return;
  for (final MapEntry<String, int> row in legacy.entries) {
    if (adoption == LegacyBaselineAdoption.move) {
      final int? existing = await db.getSyncBaseline(row.key, target);
      if (existing == null) {
        await db.setSyncBaseline(row.key, target, row.value);
      } else if (existing != row.value) {
        await db.deleteSyncBaseline(row.key, target);
      }
    }
    await db.deleteSyncBaseline(row.key, source);
  }
});

// ── 文件箱进度基线的远端作用域（BUG-4434 步骤 8）────────────────────────────

/// 能自己报出远端身份的后端（测试 fake；云后端将来需要比「类型 + 账号 + 服务器」
/// 更细的身份时实现，改了身份公式要自己负责旧槽迁移）。
abstract interface class SyncRemoteIdentified {
  /// 远端身份（任意稳定字符串，只经 [syncRemoteTag] 落库，不存明文）。
  Future<String> syncRemoteIdentity();
}

/// 云后端的账号这一轮拿不到、本机也从没记下过（OAuth 邮箱取失败且从未成功过）。
/// 认不出远端就不能挑基线槽：本轮文件箱进度判定报错跳过，不换槽、不写基线。
class SyncRemoteIdentityUnavailableError extends SyncBackendError {
  SyncRemoteIdentityUnavailableError(this.type)
    : super('Sync remote account unavailable for ${type.name}');

  final SyncBackendType type;
}

/// 一个后端实例当前连着的远端在基线表里的作用域。
class SyncRemoteScope {
  const SyncRemoteScope({
    required this.tag,
    required this.adoption,
    this.hostPin,
    this.predecessorTags = const <String>[],
  });

  /// 远端标签（[syncRemoteTag]）；null = 不分槽（认不出的后端），
  /// 存储维度就是逻辑维度本身。
  final String? tag;

  /// 升级前无后缀旧行怎么处理（见 [ensureBaselinesAdopted]）。
  final LegacyBaselineAdoption adoption;

  /// 同一远端先前用过的作用域标签，绑定时并入 [tag]（见 [ensureBaselinesAdopted]）。
  final List<String> predecessorTags;

  /// 互联时非空：本次作用域钉住的 host。落地 / 写基线前用
  /// [InterconnectSyncBackend.checkHostPin] 核对，会话中途换了 host 就放弃。
  final InterconnectHostPin? hostPin;
}

/// 偏好键：某云后端最近一次取到的账号（规整后的小写邮箱 / 用户名）。设备本地
/// （登记在 [SyncRepository.deviceLocalPrefKeys]：不随备份 / 设置同步带到别的设备，
/// 否则登着别的账号的设备在邮箱缺失时会回退到外来值、挑错基线槽）。
/// OAuth 后端的 `currentEmail` 只作展示、可临时为空（`fetchUserEmail` 失败不抛），
/// 身份不能直接取它——取不到时回退到这里记下的值，基线才不会一轮一换槽。
String syncRemoteAccountPrefKey(SyncBackendType type) =>
    SyncChannelScope.forBackendType(
      type,
    ).key(SyncRepository.syncRemoteAccountPrefBase);

/// 登出时清掉 [type] 记下的账号（下一次登录的账号重新记）。
Future<void> clearSyncRemoteAccount(FushiDatabase db, SyncBackendType type) =>
    db.deletePref(syncRemoteAccountPrefKey(type));

/// 通道 [channel] 对应哪种云后端；互联通道与认不出的后端（测试 fake 的
/// [SyncChannelScope.unscoped]）→ null。[syncRemoteScopeOf] 与 [signOutSyncBackend]
/// 共用这一张对照，记账号和忘账号认的是同一批类型。
SyncBackendType? cloudBackendTypeOfChannel(SyncChannelScope channel) {
  for (final SyncBackendType type in SyncBackendType.values) {
    if (type == SyncBackendType.fushiServer) continue;
    if (channel == SyncChannelScope.forBackendType(type)) return type;
  }
  return null;
}

/// 登出一条同步通道。设置页的「退出登录」和鉴权失效后的自动登出都走这里，登出要
/// 连带做的事只写这一处：
/// 1. 忘掉这种云后端记下的账号（[clearSyncRemoteAccount]）。[cloudRemoteScopeOf] 在
///    邮箱取不到时会沿用记下的账号；登出之后下一次登录可能是另一个账号，不忘的话
///    邮箱恰好取失败的那一轮会落进旧账号的基线槽（BUG-4434）。放在最前：后面的登出
///    即使中途抛了，也只是下一轮重新记一次账号。
/// 2. 后端登出、清它的内存缓存。
/// 3. 只清**这条通道**那格的目录缓存（BUG-1576 / BUG-1578）。
Future<void> signOutSyncBackend(FushiDatabase db, SyncBackend backend) async {
  final SyncChannelScope channel = syncChannelScopeOf(backend);
  final SyncBackendType? cloud = cloudBackendTypeOfChannel(channel);
  if (cloud != null) await clearSyncRemoteAccount(db, cloud);
  final SyncRepository repo = SyncRepository(db);
  await backend.signOut(repo: repo);
  backend.clearCache();
  await repo.clearFolderCache(channel);
}

/// [backend] 当前连着的远端的基线作用域。解析顺序：
/// 1. 剥掉 [ObfuscatingSyncBackend]（纯包装，远端是被包着的那个）。
/// 2. [SyncRemoteIdentified] → 按它报的身份分槽。
/// 3. 互联 → 会话所连 host 的作用域（[InterconnectSyncBackend.liveHostScope]：
///    hostId，认不出 hostId 的老条目按配对凭据）。
/// 4. 认得出的云后端 → `类型 + 账号 + 服务器`（见 [cloudRemoteScopeOf]）。
/// 5. 其余（测试 fake）→ 不分槽、不领养。
Future<SyncRemoteScope> syncRemoteScopeOf(
  SyncBackend backend,
  FushiDatabase db,
) async {
  final SyncBackend inner = backend is ObfuscatingSyncBackend
      ? backend.inner
      : backend;
  if (inner is SyncRemoteIdentified) {
    final String identity = await (inner as SyncRemoteIdentified)
        .syncRemoteIdentity();
    return SyncRemoteScope(
      tag: syncRemoteTag(identity),
      adoption: LegacyBaselineAdoption.move,
    );
  }
  if (inner is InterconnectSyncBackend) {
    final InterconnectHostScope scope = await inner.liveHostScope();
    return SyncRemoteScope(
      tag: scope.pin.tag,
      adoption: scope.adoption,
      hostPin: scope.pin,
      predecessorTags: scope.predecessorTags,
    );
  }
  final SyncBackendType? cloud = cloudBackendTypeOfChannel(
    syncChannelScopeOf(inner),
  );
  if (cloud != null) {
    return cloudRemoteScopeOf(
      db,
      cloud,
      currentEmail: await inner.currentEmail,
    );
  }
  return const SyncRemoteScope(
    tag: null,
    adoption: LegacyBaselineAdoption.keep,
  );
}

/// 云后端 [type] 的作用域：`syncRemoteTag('<type>\n<账号>\n<服务器>')`。
///
/// - 账号：[currentEmail] 规整（trim + 小写）后非空就用它，与记下的值不同时更新
///   偏好；为空则回退到上次记下的值；都没有 → [SyncRemoteIdentityUnavailableError]。
/// - 服务器：WebDAV 取规整后的 URL，FTP 取主机名；其余为空（SFTP 的 `currentEmail`
///   已含主机，OAuth 云盘只有一个服务器）。
/// - 领养：其它云类型都没有自己槽位的同步冷却戳（本机自 BUG-1576 分槽以来只用过
///   当前云类型）→ 无后缀旧行归当前远端；否则旧行来源混杂，删掉。
///
/// 后端实例的识别在 [syncRemoteScopeOf]；这里只吃 [currentEmail]，测试直接驱动。
Future<SyncRemoteScope> cloudRemoteScopeOf(
  FushiDatabase db,
  SyncBackendType type, {
  required String? currentEmail,
}) async {
  final String prefKey = syncRemoteAccountPrefKey(type);
  final String fresh = (currentEmail ?? '').trim().toLowerCase();
  final String account;
  if (fresh.isNotEmpty) {
    account = fresh;
    if (await db.getPref(prefKey) != fresh) await db.setPref(prefKey, fresh);
  } else {
    final String? remembered = await db.getPref(prefKey);
    if (remembered == null || remembered.isEmpty) {
      throw SyncRemoteIdentityUnavailableError(type);
    }
    account = remembered;
  }
  final SyncRepository repo = SyncRepository(db);
  final String server = switch (type) {
    SyncBackendType.webDav => WebDavOps.normalizeUrl(
      await repo.getWebDavUrl() ?? '',
    ),
    SyncBackendType.ftp => await repo.getFtpHost() ?? '',
    _ => '',
  };
  bool otherCloudUsed = false;
  for (final SyncBackendType other in SyncBackendType.values) {
    if (other == type || other == SyncBackendType.fushiServer) continue;
    // 只看带槽位后缀的键：[SyncRepository.getLastSyncMs] 会回退无后缀全局键，
    // 那个键说明不了用过哪种云。
    final String key = SyncChannelScope.forBackendType(
      other,
    ).key('sync_last_sync_ms');
    if (await db.getPref(key) != null) {
      otherCloudUsed = true;
      break;
    }
  }
  return SyncRemoteScope(
    tag: syncRemoteTag('${type.name}\n$account\n$server'),
    adoption: otherCloudUsed
        ? LegacyBaselineAdoption.discard
        : LegacyBaselineAdoption.move,
  );
}

/// 文件箱（`progress_*.json`）进度基线的存储维度：逻辑维度
/// [progressBaselineDimensionOf] 挂到 [backend] 当前远端名下，并完成旧无后缀行的
/// 领养。[hostPin] 非空（互联）时，调用方在判定前 / 落地前 / 写基线前用
/// [InterconnectSyncBackend.checkHostPin] 核对。
Future<({String storageDimension, InterconnectHostPin? hostPin})>
progressBaselineStorageFor(FushiDatabase db, SyncBackend backend) async {
  final String logical = progressBaselineDimensionOf(backend);
  final SyncRemoteScope scope = await syncRemoteScopeOf(backend, db);
  await ensureBaselinesAdopted(
    db,
    logicalDimensions: <String>[logical],
    tag: scope.tag,
    adoption: scope.adoption,
    predecessorTags: scope.predecessorTags,
  );
  return (
    storageDimension: baselineStorageDimension(logical, scope.tag),
    hostPin: scope.hostPin,
  );
}
