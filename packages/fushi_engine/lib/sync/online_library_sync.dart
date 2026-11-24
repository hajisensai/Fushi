/// 在线源条目跨设备同步（拍板台 mY5VWg1nD-：书库里从在线源加进来的条目在手机和
/// 电脑之间同步，所有者 2026-11-23 拍板「媒体都弄上」）。
///
/// 从在线源加进库的条目（在线漫画、在线小说、在线视频源 / 媒体服务器 / 流媒体
/// 视频、远程音乐曲目）没有可传的内容字节：此前内容同步对它们一律跳过，于是它们
/// 永远只在加入的那台设备上。这里同步的是**条目本身**（重开所需的描述符），不传
/// 任何内容；条目两端都在之后，既有的进度 / 合集 / 标签同步原样接管。
///
/// 形态：每台设备一份清单（[OnlineLibraryManifest]，按设备 id 区分，后写者不覆盖
/// 先写者），读的时候把别的设备的清单逐份并入本机：
/// - 云通道：与合集同一命名空间 `__collections__` 下的 `online-library-<设备>.json`；
/// - 互联：host 的 `/api/library/online-items`（[OnlineLibrarySyncHost]）。GET 回
///   host 自己（app 当 host 时）+ 它收过的各设备清单；PUT 交本机清单，host 存进
///   信箱（[OnlineLibraryMailbox]），app 当 host 时同时并进自己的库。无头服务端
///   没有在线源，只当信箱，于是两台客户端经它照样能互相拿到。
///
/// 并入规则在 app 侧（`fushi/lib/src/sync/online_library_items.dart`）：书 / 视频
/// 只增不删，靠「本机见过的条目」账本区分「对端新加的」与「本机删掉的」；跨设备
/// 删除仍走既有的删除墓碑。音乐曲目按 `updatedAt` 整行 LWW（表本身就是为合并设计的）。
///
/// iOS 按商店合规没有在线源宿主：同步过去的条目照样落库、打不开（所有者拍板可以接受）。
library;

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi_engine/sync/sync_manifest_codec.dart';

/// host 端点路径。
const String kOnlineLibraryItemsPath = '/api/library/online-items';

/// 能力位：host 有 [kOnlineLibraryItemsPath]（`liveLibrary.onlineItems`）。
const String kLiveLibraryOnlineItemsCapability = 'onlineItems';

/// 单份清单的条目上限：防坏数据 / 恶意对端把 host 信箱撑爆。正常用户远小于此。
const int kOnlineLibraryManifestMaxItems = 50000;

/// 条目种类（wire 值冻结）。
enum OnlineLibraryItemKind {
  /// 在线漫画书架条目（`EpubBooks.sourceMetadata` 是在线漫画描述符）。key = bookKey。
  manga('manga'),

  /// 在线小说占位书（LNReader）。key = `<插件 id>\u001f<作品路径>`。
  novel('novel'),

  /// 网络视频行（在线视频源 / 媒体服务器 / 流媒体）。key = `VideoBooks.bookUid`。
  video('video'),

  /// 远程音乐曲目（`music_remote_tracks`）。key = trackUid。
  music('music');

  const OnlineLibraryItemKind(this.wire);

  final String wire;

  static OnlineLibraryItemKind? fromWire(Object? value) {
    for (final OnlineLibraryItemKind kind in values) {
      if (kind.wire == value) return kind;
    }
    return null;
  }
}

/// 一条在线源条目。
class OnlineLibraryItem {
  const OnlineLibraryItem({
    required this.kind,
    required this.key,
    required this.title,
    required this.addedAt,
    this.updatedAt = 0,
    this.payload = const <String, Object?>{},
  });

  final OnlineLibraryItemKind kind;

  /// 跨设备稳定身份（见 [OnlineLibraryItemKind] 各值）。
  final String key;

  final String title;

  /// 这条在加入它的那台设备上的入库时刻（毫秒）。落到别的设备时原样保留，于是
  /// 各设备清单里同一条的 [addedAt] 一致；「本机删了、对端后来又加了一次」靠它
  /// 变大来识别。
  final int addedAt;

  /// 只有 LWW 种类（[OnlineLibraryItemKind.music]）用：整行最后改动时刻。
  final int updatedAt;

  /// 种类专属的重开数据（描述符 / 路径 / 规格）。
  final Map<String, Object?> payload;

  /// 账本 / 去重用的复合键。
  String get ledgerKey => '${kind.wire}:$key';

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind.wire,
    'key': key,
    'title': title,
    'addedAt': addedAt,
    if (updatedAt != 0) 'updatedAt': updatedAt,
    if (payload.isNotEmpty) 'payload': payload,
  };

  /// 形状不对 / 未知种类（对端未来新增）返回 null，不让整份清单作废。
  static OnlineLibraryItem? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final OnlineLibraryItemKind? kind = OnlineLibraryItemKind.fromWire(
      raw['kind'],
    );
    final Object? key = raw['key'];
    if (kind == null || key is! String || key.isEmpty) return null;
    final Object? title = raw['title'];
    final Object? addedAt = raw['addedAt'];
    final Object? updatedAt = raw['updatedAt'];
    final Object? payload = raw['payload'];
    return OnlineLibraryItem(
      kind: kind,
      key: key,
      title: title is String ? title : '',
      addedAt: addedAt is num ? addedAt.toInt() : 0,
      updatedAt: updatedAt is num ? updatedAt.toInt() : 0,
      payload: payload is Map
          ? Map<String, Object?>.from(payload)
          : const <String, Object?>{},
    );
  }
}

/// 一台设备的在线源条目清单。
class OnlineLibraryManifest implements CanonicalJsonManifest {
  const OnlineLibraryManifest({
    required this.deviceId,
    this.items = const <OnlineLibraryItem>[],
  });

  static const int currentVersion = 1;
  static const String _label = 'online library manifest';

  /// 写这份清单的设备（`SyncRepository.getOrCreateDeviceId`）。
  final String deviceId;

  final List<OnlineLibraryItem> items;

  /// 结构非法 / 版本过新抛 [FormatException]（严格清单，见 [requireManifestObject]）；
  /// 单条坏条目只丢那一条。
  factory OnlineLibraryManifest.fromJson(Object? json) {
    final Map<String, dynamic> map = requireManifestObject(json, _label);
    requireManifestVersion(map, currentVersion: currentVersion, label: _label);
    final List<Object?> rawItems = requireManifestList(map, 'items', _label);
    if (rawItems.length > kOnlineLibraryManifestMaxItems) {
      throw const FormatException('$_label: too many items');
    }
    final Object? deviceId = map['deviceId'];
    return OnlineLibraryManifest(
      deviceId: deviceId is String ? deviceId : '',
      items: <OnlineLibraryItem>[
        for (final Object? raw in rawItems)
          if (OnlineLibraryItem.tryParse(raw) case final OnlineLibraryItem i) i,
      ],
    );
  }

  @override
  Map<String, dynamic> toJson() => contentJson();

  @override
  Map<String, dynamic> contentJson() {
    final List<OnlineLibraryItem> sorted = List<OnlineLibraryItem>.of(items)
      ..sort(
        (OnlineLibraryItem a, OnlineLibraryItem b) =>
            a.ledgerKey.compareTo(b.ledgerKey),
      );
    return <String, dynamic>{
      'version': currentVersion,
      'deviceId': deviceId,
      'items': <Map<String, Object?>>[
        for (final OnlineLibraryItem i in sorted) i.toJson(),
      ],
    };
  }

  @override
  String canonicalJson() => canonicalManifestJson(this);
}

/// 本机作为同步参与方：读出本机清单、把别的设备的清单并进本机库。
///
/// app 实现（在线源的建行逻辑都在 app 层）；无头服务端没有。
abstract interface class OnlineLibraryParticipant {
  /// 本机设备 id。
  Future<String> onlineLibraryDeviceId();

  /// 本机当前的在线源条目清单。
  Future<OnlineLibraryManifest> loadLocalOnlineLibraryManifest();

  /// 把 [manifests]（别的设备的）并进本机库，返回本机新建 / 改动的条目数。
  /// 调用方已持同步状态锁。
  Future<int> applyOnlineLibraryManifests(
    List<OnlineLibraryManifest> manifests,
  );
}

/// host 端「在线源条目清单」的可选能力（与 [MediaLinkSyncHost] 同范式：server 用
/// `is` 探测，不实现 → 端点 404、能力位 false，client 记一条「对端版本过旧」）。
abstract interface class OnlineLibrarySyncHost {
  /// host 自己的清单（有的话）+ 信箱里各设备的清单。
  Future<List<OnlineLibraryManifest>> getOnlineLibraryManifests();

  /// 收下一台设备的清单：存进信箱；host 是参与方时同时并进自己的库。
  Future<void> putOnlineLibraryManifest(OnlineLibraryManifest incoming);
}

/// host 的清单信箱：每台设备一行偏好（`sync_` 前缀，不随设置同步外传）。
class OnlineLibraryMailbox {
  OnlineLibraryMailbox(this._db);

  final FushiDatabase _db;

  static const String keyPrefix = 'sync_online_library_peer:';

  /// 全部设备的清单；读不出的那份跳过（下一次那台设备推送时覆盖）。
  Future<List<OnlineLibraryManifest>> readAll() async {
    final List<PreferenceRow> rows = await (_db.select(
      _db.preferences,
    )..where(($PreferencesTable t) => t.key.like('$keyPrefix%'))).get();
    final List<OnlineLibraryManifest> out = <OnlineLibraryManifest>[];
    for (final PreferenceRow row in rows) {
      if (!row.key.startsWith(keyPrefix)) continue;
      try {
        out.add(OnlineLibraryManifest.fromJson(jsonDecode(row.value)));
      } on FormatException {
        continue;
      }
    }
    return out;
  }

  /// 存一台设备的清单（同设备覆盖）。[manifest] 的设备 id 为空抛 [ArgumentError]。
  Future<void> write(OnlineLibraryManifest manifest) async {
    if (manifest.deviceId.isEmpty) {
      throw ArgumentError.value(manifest.deviceId, 'deviceId', 'empty');
    }
    await _db
        .into(_db.preferences)
        .insertOnConflictUpdate(
          PreferencesCompanion.insert(
            key: '$keyPrefix${manifest.deviceId}',
            value: manifest.canonicalJson(),
          ),
        );
  }
}

/// host 端 [OnlineLibrarySyncHost] 的通用实现：信箱 + 可选的本机参与方。
///
/// [runExclusive] 是同步状态锁（与 client 侧并入本机时同一把）。
class OnlineLibraryHostEndpoint implements OnlineLibrarySyncHost {
  OnlineLibraryHostEndpoint({
    required FushiDatabase db,
    required Future<void> Function(Future<void> Function() body) runExclusive,
    this.participant,
  }) : _mailbox = OnlineLibraryMailbox(db),
       _runExclusive = runExclusive;

  final OnlineLibraryMailbox _mailbox;
  final Future<void> Function(Future<void> Function() body) _runExclusive;

  /// app 当 host 时的本机参与方；null = 只当信箱（无头服务端）。
  final OnlineLibraryParticipant? participant;

  @override
  Future<List<OnlineLibraryManifest>> getOnlineLibraryManifests() async {
    final List<OnlineLibraryManifest> peers = await _mailbox.readAll();
    final OnlineLibraryParticipant? self = participant;
    if (self == null) return peers;
    final OnlineLibraryManifest own = await self
        .loadLocalOnlineLibraryManifest();
    return <OnlineLibraryManifest>[
      own,
      for (final OnlineLibraryManifest m in peers)
        if (m.deviceId != own.deviceId) m,
    ];
  }

  @override
  Future<void> putOnlineLibraryManifest(OnlineLibraryManifest incoming) async {
    final OnlineLibraryParticipant? self = participant;
    await _runExclusive(() async {
      await _mailbox.write(incoming);
      if (self == null) return;
      if (incoming.deviceId == await self.onlineLibraryDeviceId()) return;
      await self.applyOnlineLibraryManifests(<OnlineLibraryManifest>[incoming]);
    });
  }
}
