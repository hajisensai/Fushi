/// 同步 v2 的一轮（docs/specs/2026-10-25-srs-sync-v2-design.md §6.2）：
///
/// 1. 读位置上全部设备的 head（每台取代号最大的；同一代号有两份 = 同一身份的两个安装，都交给内核判分叉）；
/// 2. 内核看 head 定要拉的段 → 只拉缺的段 → 收（校验签名 / 链 / 解密，按设备连续前缀 + 因果满足才应用，投影、
///    重放受影响的卡；本机身份分叉就在这一步换身份、重签发）；
/// 3. 发件：本机还没传到这个位置的段 → 上传 → 写新 head（**先读后写**：同一身份的另一个安装刚写的 head 不会
///    被自己这一轮的 head 挡住视线）；
/// 4. 清掉本机两代以前的 head，以及小段合并换下来、大家都 ack 过的旧小段（归档位置都不删）。
///
/// 写入纪律（§6.1）：先写段、再写 head；读者只认「head 引用的段都可读」的前缀，所以 head 先于段可见、上传
/// 中断、列目录最终一致（Google Drive）都只会让这一轮少收一点，下一轮补齐。传输只经 [SrsLocationStore]。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:fushi_engine/srs/sync2/srs_location_crypto.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsSync2Result;

/// 一轮同步要的内核接口（[SrsDbStore] 实现；测试可替身）。
abstract interface class SrsSync2Host {
  String get profileUid;

  /// 不改投影的命令（看 head、发件、写 head、摘要、状态）。
  Future<SrsSync2Result> sync2Command(
    Map<String, Object?> request, {
    List<Uint8List> blobs = const <Uint8List>[],
  });

  /// 收段：写锁里 ingest，投影变化接进本机缓存。返回内核的 ingest 结果。
  Future<Map<String, Object?>> sync2Ingest(
    List<Uint8List> segments, {
    String? keyHex,
  });
}

/// 本协议版本（`meta.json` 的 `v`）与能读它的最低读者版本。
const int kSrsSync2Protocol = 1;
const int kSrsSync2MinReader = 1;

/// 一轮的结果。
class SrsSync2Report {
  SrsSync2Report();

  /// 这一轮应用的远端操作条数。
  int applied = 0;

  /// 收到但因果还不满足、留在缓冲里的条数。
  int pending = 0;

  /// 这一轮上传的段数。
  int uploaded = 0;

  /// 发现本机身份分叉（已换身份重签发）。
  bool fork = false;

  /// 投影有变化（Dart 侧要刷新界面）。
  bool changed = false;

  /// 位置上的数据来自更新版本、本机读不了（`meta.json` 的 `minReader` 比本机新）：停写并提示升级（§8）。
  bool needsUpgrade = false;

  /// 写 head 那一刻的服务端时间（校时用；后端给不出为 null）。
  int? serverTimeMs;

  /// 这个位置这一轮没同步成的原因（调度器据此如实报「未同步」）；null = 成功。
  String? error;

  /// 位置开了加密（`meta.json` 有 `kdf`）时它的参数；UI 让用户输入口令时用同一份盐与参数派生。
  SrsKdf? kdf;

  /// 这一轮把本机的「开加密」写进了位置的 `meta.json`（调度器据此把本机密钥标成已生效）。
  bool encryptionEnabled = false;

  /// 这一轮实际用密钥收发（位置是加密的且本机口令对）。
  bool encrypted = false;

  /// 非致命错误（段损坏 / 签名不符 / 解不开……）：记日志，不打断这一轮。
  final List<String> errors = <String>[];
}

Future<Map<String, Object?>?> _readJson(
  SrsLocationStore loc,
  String path,
) async {
  final Uint8List? b = await loc.get(path);
  if (b == null) return null;
  try {
    final Object? j = jsonDecode(utf8.decode(b));
    return j is Map ? j.cast<String, Object?>() : null;
  } on FormatException {
    return null;
  }
}

/// 跑一轮。[locationId] 是这个位置的稳定身份（本机记每个位置传到了哪）；[key] = 本机为这个位置记的密钥
/// （见 srs_location_crypto.dart：位置是加密的而本机没有 / 不对 → 这一轮不同步，报 [kSrsSync2NeedsKey] /
/// [kSrsSync2WrongKey]；本机刚开加密 → 这一轮把 `kdf` 写进 `meta.json`）；[archive] = 归档位置：只写不删（不清本机
/// 的旧 head，设计 §10.3）。
Future<SrsSync2Report> srsSync2Round({
  required SrsSync2Host host,
  required SrsLocationStore location,
  required String locationId,
  required int Function() nowMs,
  SrsLocationKey? key,
  bool archive = false,
}) async {
  final SrsSync2Report report = SrsSync2Report();
  // meta.json：协议版本与集合身份，创建后只读（§6.1）。
  final Map<String, Object?> id = (await host.sync2Command(<String, Object?>{
    'op': 'identity',
    'now': nowMs(),
  })).map;
  Map<String, Object?>? meta = await _readJson(location, 'meta.json');
  if (meta == null) {
    meta = <String, Object?>{
      'v': kSrsSync2Protocol,
      'minReader': kSrsSync2MinReader,
      'collection': id['collection'],
      'createdAt': nowMs(),
    };
    await location.put('meta.json', utf8.encode(jsonEncode(meta)));
  } else if (((meta['minReader'] as int?) ?? 1) > kSrsSync2Protocol) {
    report.needsUpgrade = true;
    return report;
  }

  // 加密握手（§9）：位置上的 kdf 是准；本机密钥对不上就不碰这个位置。
  final Map<String, Object?>? kdfJson = (meta['kdf'] as Map?)
      ?.cast<String, Object?>();
  String? keyHex;
  if (kdfJson == null) {
    if (key != null && key.pendingEnable) {
      await location.put(
        'meta.json',
        utf8.encode(
          jsonEncode(<String, Object?>{
            ...meta,
            'kdf': <String, Object?>{...key.kdf.toJson(), 'check': key.check},
          }),
        ),
      );
      report.encryptionEnabled = true;
      report.kdf = key.kdf;
      keyHex = key.keyHex;
    }
  } else {
    report.kdf = SrsKdf.fromJson(kdfJson);
    if (key == null) {
      report.error = kSrsSync2NeedsKey;
      return report;
    }
    if (kdfJson['check'] != key.check) {
      report.error = kSrsSync2WrongKey;
      return report;
    }
    keyHex = key.keyHex;
  }
  report.encrypted = keyHex != null;
  // 加密位置换一个上传进度身份：开加密之前传过的明文段，本机全部按密文重传一遍（同名覆盖）。
  final String progressId = keyHex == null ? locationId : '$locationId#e';

  // 1. 全部设备的 head。
  final List<Uint8List> heads = <Uint8List>[];
  for (final SrsLocationEntry d in await location.list('devices')) {
    if (!d.isFolder) continue;
    int top = -1;
    final List<String> names = <String>[];
    final Map<String, int> genOf = <String, int>{};
    for (final SrsLocationEntry f in await location.list('devices/${d.name}')) {
      final int? g = _headGen(f.name);
      if (g == null) continue;
      genOf[f.name] = g;
      if (g > top) top = g;
    }
    genOf.forEach((String n, int g) {
      if (g == top) names.add(n);
    });
    for (final String n in names) {
      final Uint8List? b = await location.get('devices/${d.name}/$n');
      if (b != null) heads.add(b);
    }
  }

  // 2. 定要拉的段 → 拉 → 收。
  final Map<String, Object?> plan = (await host.sync2Command(<String, Object?>{
    'op': 'plan',
  }, blobs: heads)).map;
  final List<Uint8List> segments = <Uint8List>[];
  for (final Object? f in (plan['fetch'] as List?) ?? const <Object?>[]) {
    final Map<String, Object?> e = (f! as Map).cast<String, Object?>();
    for (final Object? name in (e['files'] as List?) ?? const <Object?>[]) {
      // head 指向的段暂时还列不到（最终一致）就这一轮跳过，下一轮再来。
      final Uint8List? b = await location.get(name! as String);
      if (b != null) segments.add(b);
    }
  }
  if (segments.isNotEmpty || plan['fork'] == true) {
    final Map<String, Object?> r = await host.sync2Ingest(
      segments,
      keyHex: keyHex,
    );
    report.applied = (r['applied'] as int?) ?? 0;
    report.pending = (r['pending'] as int?) ?? 0;
    report.fork = r['fork'] == true;
    report.changed =
        ((r['events'] as List?)?.isNotEmpty ?? false) ||
        ((r['replayed'] as List?)?.isNotEmpty ?? false) ||
        ((r['changed'] as List?)?.isNotEmpty ?? false);
    report.errors.addAll(<String>[
      for (final Object? x in (r['errors'] as List?) ?? const <Object?>[]) '$x',
    ]);
  }

  // 3. 发件：先段、后 head。
  final SrsSync2Result out = await host.sync2Command(<String, Object?>{
    'op': 'outbox',
    'location': progressId,
    'key': keyHex,
  });
  for (final (String path, Uint8List bytes) in out.files) {
    await location.put(path, bytes);
    report.uploaded++;
  }
  final int upto = (out.map['upto'] as int?) ?? 0;
  final SrsSync2Result head = await host.sync2Command(<String, Object?>{
    'op': 'head',
    'location': progressId,
    'upto': upto,
    'now': nowMs(),
  });
  final String self =
      (await host.sync2Command(<String, Object?>{
            'op': 'identity',
            'now': nowMs(),
          })).map['device']!
          as String;
  String? written;
  for (final (String path, Uint8List bytes) in head.files) {
    await location.put(path, bytes);
    written = path.substring(path.lastIndexOf('/') + 1);
  }
  // 小段合并（§7.1）换下来的旧小段：新 head 已不再引用、全部活跃设备都 ack 过了。归档位置一个不删。
  if (!archive) {
    for (final Object? name
        in (head.map['delete'] as List?) ?? const <Object?>[]) {
      await location.delete(name! as String);
    }
  }

  // 4. 本机两代以前的 head；顺便取服务端时间。
  final int gen = (head.map['gen'] as int?) ?? 0;
  for (final SrsLocationEntry f in await location.list('devices/$self')) {
    final int? g = _headGen(f.name);
    if (!archive && g != null && g < gen - 2) {
      await location.delete('devices/$self/${f.name}');
    }
    if (f.name == written) report.serverTimeMs = f.modifiedAt;
  }
  return report;
}

/// `head-<gen>-<tag>.json` 的代号；不是 head 返回 null。
int? _headGen(String name) {
  if (!name.startsWith('head-') || !name.endsWith('.json')) return null;
  final String rest = name.substring(5, name.length - 5);
  final int dash = rest.indexOf('-');
  return int.tryParse(dash < 0 ? rest : rest.substring(0, dash));
}
