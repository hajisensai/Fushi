/// 整包备份里的复习部分（G11-4；docs/specs/2026-11-15-srs-gen4-g7-g11-plan.md §1.9、D34，交接说明「G11-4」一节）。
///
/// **新形态**（这一版起写）：zip 里 `srs/manifest.json` + 每个集合一条 `srs/<n>.bin`（内核 `export` 写的 `FSRS4EXP`
/// 流，与 `.fushisrs` 第 2 版的 `ops.bin` 同一种），**不再写 `srs.db` 条目**，也不带签名私钥（备份可能存到任何地方）。
/// 清单 `{v: 2, gen: 4, exportedAt, collections: [{n, profiles: [{uid, name}], collection, dir, salts, peers, counts}]}`，
/// **不带 `magic`**（v2 之前的事件备份清单才有）。`collection` / `dir` / `salts` / `peers` 是内核导出命令的回包原样。
///
/// **旧形态**（只读，长期支持，D34）：
/// - 协议 3 的 `srs.db` 条目（2026-10-23 起）：内核 `legacy_backup_import`（`source: "db"`）。
/// - 2026-10-23 之前的整包备份（SRS 表在主库条目里，只有 v1 事件）：Dart 把事件写成「外来、已盖戳」的 JSONL
///   （[srsWriteLegacyEventsJsonl]），内核 `legacy_backup_import`（`source: "events"`）在一份临时协议 3 库里备好再读入。
///
/// 落库（[srsLandBackupUnit]）一律是内核命令：新形态 = G11-3 的 `import`，旧形态 = `legacy_backup_import`；两者都先认领
/// （G9-4 `collection_adopt`），另一个集合 / 新盐 / 新设备公钥没确认时回 `needsConfirm`、什么都不写。
///
/// 旧版本：已发布的版本不认这个清单（它们找的是 `srs.db` 条目），挡住它们的是主库 schemaVersion（D33）：旧版本见到
/// 更新的主库就拒绝整份备份，什么都不动。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/srs/srs_backup_merge.dart';
import 'package:fushi_engine/srs/srs_db_store.dart'
    show srsCacheConfigFor, srsProfileHasUserData;

/// 清单条目名。
const String kSrsBackupManifestEntry = 'srs/manifest.json';

/// 归档里复习部分的前缀。
const String kSrsBackupPrefix = 'srs/';

/// 第 [n] 个集合的操作流条目名。
String srsBackupStreamEntry(int n) => 'srs/$n.bin';

/// 本版本写的清单版本（第 2 版 = 协议 4）。
const int kSrsBackupManifestVersion = 2;

/// 清单代号（协议 4）。
const int kSrsBackupManifestGen = 4;

/// 清单上限（外部文件不可信）。
const int kSrsBackupManifestMaxBytes = 16 << 20;

/// 备份里的复习数据来自更新的版本（清单版本 / 代号比这一版新）：这一版读不了，要先升级；本机什么都没动。
final class SrsBackupTooNewException implements Exception {
  const SrsBackupTooNewException(this.version, this.gen);

  final Object? version;
  final Object? gen;

  @override
  String toString() =>
      'SrsBackupTooNewException: the review data in this backup was written '
      'by a newer version (manifest v=$version, gen=$gen); update the app '
      'first. Nothing was changed.';
}

/// 清单里一个集合。
final class SrsBackupUnit {
  const SrsBackupUnit({
    required this.n,
    required this.profiles,
    required this.collection,
    required this.dir,
    required this.salts,
    required this.peers,
    this.counts = const <String, Object?>{},
  });

  /// 流条目序号（[srsBackupStreamEntry]）。
  final int n;

  /// 导出时绑在这个集合上的 profile（主库 uid 与名字）。
  final List<SrsBackupProfile> profiles;
  final String collection;
  final String dir;
  final List<Object?> salts;
  final List<Object?> peers;
  final Map<String, Object?> counts;

  /// 交给内核 `import` 的清单（G11-3 第 2 版口径）。
  Map<String, Object?> get kernelManifest => <String, Object?>{
    'collection': collection,
    'dir': dir,
    'salts': salts,
    'peers': peers,
  };

  Map<String, Object?> toJson() => <String, Object?>{
    'n': n,
    'profiles': <Object?>[
      for (final SrsBackupProfile p in profiles)
        <String, Object?>{'uid': p.uid, 'name': p.name},
    ],
    'collection': collection,
    'dir': dir,
    'salts': salts,
    'peers': peers,
    'counts': counts,
  };
}

/// `srs/manifest.json`。
final class SrsBackupBundleManifest {
  const SrsBackupBundleManifest({
    required this.exportedAt,
    required this.units,
  });

  final int exportedAt;
  final List<SrsBackupUnit> units;

  Map<String, Object?> toJson() => <String, Object?>{
    'v': kSrsBackupManifestVersion,
    'gen': kSrsBackupManifestGen,
    'exportedAt': exportedAt,
    'collections': <Object?>[for (final SrsBackupUnit u in units) u.toJson()],
  };

  /// 解析清单（外部数据，逐项校验）。更新版本写的抛 [SrsBackupTooNewException]，坏清单抛 [FormatException]。
  static SrsBackupBundleManifest parse(List<int> bytes) {
    if (bytes.length > kSrsBackupManifestMaxBytes) {
      throw const FormatException('srs backup manifest too large');
    }
    final Object? m;
    try {
      m = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const FormatException('srs backup manifest is not JSON');
    }
    if (m is! Map) throw const FormatException('bad srs backup manifest');
    if (m.containsKey('magic')) {
      throw const FormatException('bad srs backup manifest (magic)');
    }
    final Object? v = m['v'];
    final Object? gen = m['gen'];
    if (v is! int || gen is! int) {
      throw const FormatException('bad srs backup manifest version');
    }
    if (v > kSrsBackupManifestVersion || gen > kSrsBackupManifestGen) {
      throw SrsBackupTooNewException(v, gen);
    }
    if (v != kSrsBackupManifestVersion || gen != kSrsBackupManifestGen) {
      throw const FormatException('bad srs backup manifest version');
    }
    final Object? cols = m['collections'];
    if (cols is! List) throw const FormatException('bad srs backup manifest');
    final Set<int> seen = <int>{};
    final List<SrsBackupUnit> units = <SrsBackupUnit>[];
    for (final Object? c in cols) {
      if (c is! Map) throw const FormatException('bad srs backup collection');
      final Object? n = c['n'];
      final Object? col = c['collection'];
      final Object? dir = c['dir'];
      final Object? salts = c['salts'];
      final Object? peers = c['peers'];
      final Object? profiles = c['profiles'];
      if (n is! int ||
          n < 0 ||
          !seen.add(n) ||
          col is! String ||
          dir is! String ||
          salts is! List ||
          (peers != null && peers is! List) ||
          profiles is! List ||
          profiles.isEmpty) {
        throw const FormatException('bad srs backup collection');
      }
      final List<SrsBackupProfile> ps = <SrsBackupProfile>[];
      for (final Object? pr in profiles) {
        if (pr is! Map || pr['uid'] is! String || pr['name'] is! String) {
          throw const FormatException('bad srs backup profile');
        }
        final String uid = pr['uid'] as String;
        if (uid.isEmpty) throw const FormatException('bad srs backup profile');
        ps.add(SrsBackupProfile(uid: uid, name: pr['name'] as String));
      }
      final Object? counts = c['counts'];
      units.add(
        SrsBackupUnit(
          n: n,
          profiles: ps,
          collection: col,
          dir: dir,
          salts: List<Object?>.of(salts),
          peers: List<Object?>.of((peers as List?) ?? const <Object?>[]),
          counts: counts is Map
              ? counts.cast<String, Object?>()
              : const <String, Object?>{},
        ),
      );
    }
    final Object? at = m['exportedAt'];
    return SrsBackupBundleManifest(
      exportedAt: at is int ? at : 0,
      units: units,
    );
  }
}

/// 把 [core]（本机新代库，Primary）里 [profiles] 中有用户数据的 profile 按集合导出到 [outDir]（`<n>.bin`），回清单；
/// 一个都没有回 null。还没绑定集合的 profile 跳过（没有数据可导）。导出在后台 isolate 跑（内核在一个读快照里写流）。
Future<SrsBackupBundleManifest?> srsExportBackupStreams({
  required SrsCore core,
  required List<SrsBackupProfile> profiles,
  required String outDir,
  required int nowMs,
}) async {
  final List<SrsBackupProfile> withData = <SrsBackupProfile>[];
  for (final SrsBackupProfile pr in profiles) {
    try {
      if (await srsProfileHasUserData(core, pr.uid)) withData.add(pr);
    } on SrsProfileUnboundException {
      // 没有集合 = 没有数据。
    }
  }
  if (withData.isEmpty) return null;
  final int address = core.address;
  final String? lib = core.libraryPath;
  final List<(String, String)> plain = <(String, String)>[
    for (final SrsBackupProfile pr in withData) (pr.uid, pr.name),
  ];
  final List<Map<String, Object?>> raw = await Isolate.run(
    () => _exportStreams(address, lib, plain, outDir),
    debugName: 'srs-backup-export',
  );
  if (raw.isEmpty) return null;
  return SrsBackupBundleManifest(
    exportedAt: nowMs,
    units: <SrsBackupUnit>[
      for (final Map<String, Object?> u in raw)
        SrsBackupUnit(
          n: u['n']! as int,
          profiles: <SrsBackupProfile>[
            for (final (String, String) pr
                in (u['profiles']! as List<Object?>).cast<(String, String)>())
              SrsBackupProfile(uid: pr.$1, name: pr.$2),
          ],
          collection: u['collection']! as String,
          dir: u['dir']! as String,
          salts: (u['salts']! as List<Object?>),
          peers: (u['peers'] as List<Object?>?) ?? const <Object?>[],
          counts:
              (u['counts'] as Map?)?.cast<String, Object?>() ??
              const <String, Object?>{},
        ),
    ],
  );
}

/// [srsExportBackupStreams] 的后台一半：同一个集合只导一次（G9-5 关联过的几个 profile 共用一个集合）。
List<Map<String, Object?>> _exportStreams(
  int address,
  String? lib,
  List<(String, String)> profiles,
  String outDir,
) {
  final SrsCore core = SrsCore.fromAddress(address, libraryPath: lib);
  final Map<String, Map<String, Object?>> byCollection =
      <String, Map<String, Object?>>{};
  final List<Map<String, Object?>> out = <Map<String, Object?>>[];
  for (final (String uid, String name) in profiles) {
    final Map<String, Object?> info;
    try {
      info = core.sync2(<String, Object?>{
        'op': 'collection_info',
        'profile': uid,
      }).map;
    } on SrsProfileUnboundException {
      continue;
    }
    final String col = info['collection']! as String;
    final Map<String, Object?>? seen = byCollection[col];
    if (seen != null) {
      (seen['profiles']! as List<Object?>).add((uid, name));
      continue;
    }
    final int n = out.length;
    final Map<String, Object?> r = core.sync2(<String, Object?>{
      'op': 'export',
      'profile': uid,
      'path': p.join(outDir, '$n.bin'),
    }).map;
    final Map<String, Object?> unit = <String, Object?>{
      'n': n,
      'profiles': <Object?>[(uid, name)],
      'collection': r['collection'],
      'dir': r['dir'],
      'salts': r['salts'],
      'peers': r['peers'],
      'counts': r['counts'],
    };
    byCollection[col] = unit;
    out.add(unit);
  }
  return out;
}

/// 一份要落进新代库的复习数据（一个集合 / 一个旧 profile）。
sealed class SrsBackupSourceFile {
  const SrsBackupSourceFile();
}

/// 新形态：`srs/<n>.bin` 解出来的文件 + 清单项。
final class SrsBackupStreamFile extends SrsBackupSourceFile {
  const SrsBackupStreamFile({required this.path, required this.unit});

  final String path;
  final SrsBackupUnit unit;
}

/// 协议 3 的 `srs.db`（备份里解出来的文件，内核只读不改）里 [backupProfile] 的数据。[scratch] 是给内核拷一份再备的空
/// 目录：同一份 `srs.db` 里的每个 profile 各给一个（内核只认里面它自己备的库文件，别的文件一概拒绝）。
final class SrsBackupLegacyDbFile extends SrsBackupSourceFile {
  const SrsBackupLegacyDbFile({
    required this.path,
    required this.scratch,
    required this.backupProfile,
  });

  final String path;
  final String scratch;
  final String backupProfile;
}

/// 只有 v1 事件的旧输入：[path] 是 [srsWriteLegacyEventsJsonl] 写的 JSONL，[scratch] 是给内核备临时协议 3 库的空目录。
final class SrsBackupLegacyEventsFile extends SrsBackupSourceFile {
  const SrsBackupLegacyEventsFile({
    required this.path,
    required this.scratch,
    required this.backupProfile,
  });

  final String path;
  final String scratch;
  final String backupProfile;
}

/// 一次落库的结果（内核回包原样 + 归纳）。
final class SrsBackupLanded {
  const SrsBackupLanded(this.reply);

  final Map<String, Object?> reply;

  /// 另一个集合 / 新盐 / 新设备公钥，调用方没确认：什么都没写。
  bool get needsConfirm => reply['outcome'] == 'needsConfirm';

  /// 什么都没变（同一份再落一遍）。
  bool get unchanged => reply['unchanged'] == true;

  int get applied => (reply['applied'] as int?) ?? 0;
}

/// 把 [file] 落进 [core]（目标库，Primary）的 profile [targetUid]（内核命令，后台 isolate）。[confirmed] = 调用方已就
/// 「并入另一个集合 / 记下新的盐与设备公钥」取得用户确认；没确认而需要时回 [SrsBackupLanded.needsConfirm]、什么都没写。
/// [preflight] 只判断、什么都不写。坏文件 / 前提核对不过抛错，整笔回滚。
Future<SrsBackupLanded> srsLandBackupUnit({
  required SrsCore core,
  required String targetUid,
  required SrsBackupSourceFile file,
  required bool confirmed,
  required int nowMs,
  bool preflight = false,
}) {
  final Map<String, Object?> request = switch (file) {
    SrsBackupStreamFile(:final String path, :final SrsBackupUnit unit) =>
      <String, Object?>{
        'op': 'import',
        'profile': targetUid,
        'now': nowMs,
        'path': path,
        'manifest': unit.kernelManifest,
        'confirmed': confirmed,
        'preflight': preflight,
      },
    SrsBackupLegacyDbFile(
      :final String path,
      :final String scratch,
      :final String backupProfile,
    ) =>
      <String, Object?>{
        'op': 'legacy_backup_import',
        'profile': targetUid,
        'now': nowMs,
        'source': 'db',
        'path': path,
        'scratch': scratch,
        'backupProfile': backupProfile,
        'caches': srsCacheConfigFor(backupProfile),
        'confirmed': confirmed,
        'preflight': preflight,
      },
    SrsBackupLegacyEventsFile(
      :final String path,
      :final String scratch,
      :final String backupProfile,
    ) =>
      <String, Object?>{
        'op': 'legacy_backup_import',
        'profile': targetUid,
        'now': nowMs,
        'source': 'events',
        'path': path,
        'scratch': scratch,
        'backupProfile': backupProfile,
        'caches': srsCacheConfigFor(backupProfile),
        'confirmed': confirmed,
        'preflight': preflight,
      },
  };
  final int address = core.address;
  final String? lib = core.libraryPath;
  return Isolate.run(
    () => SrsBackupLanded(
      SrsCore.fromAddress(address, libraryPath: lib).sync2(request).map,
    ),
    debugName: 'srs-backup-land',
  );
}

/// 把 [events]（一个 profile 的 v1 事件）写成内核 `legacy_backup_import`（`source: "events"`）读的 JSONL：每行一项协议 3
/// `apply` 的「外来、已盖戳」输入 `{e: SrsEvent.toJson(), stamped: true, note?}`。复习日志的 `note` 取 [noteOfCard]
/// （卡片 ID → 笔记 ID；查不到不写）。回写入的行数。
Future<int> srsWriteLegacyEventsJsonl(
  List<SrsEvent> events,
  File out, {
  Map<String, String> noteOfCard = const <String, String>{},
}) async {
  final IOSink sink = out.openWrite();
  int n = 0;
  try {
    for (final SrsEvent e in events) {
      final Map<String, Object?> item = <String, Object?>{
        'e': e.toJson(),
        'stamped': true,
      };
      if (e is SrsLogEvent) {
        final String? note = noteOfCard[e.log.cardId];
        if (note != null) item['note'] = note;
      }
      sink.writeln(jsonEncode(item));
      n++;
    }
  } finally {
    await sink.close();
  }
  return n;
}
