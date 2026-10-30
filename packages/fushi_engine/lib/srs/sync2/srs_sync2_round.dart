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
///
/// 读写文件同时最多 [kSrsSync2Concurrency] 个在途：网盘每个请求的固定延迟远大于传输本身，逐个等是首次同步 /
/// 新设备追赶慢的主因。段之间没有先后约束（读者按 seq 排、写者在全部段写完后才写 head），只有 head 要等段。
library;

import 'dart:math';
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

  /// 开一个分批收段会话（覆盖上一轮没收尾的）。本机身份的段在会话里跨批累积分叉点，换身份推到
  /// [sync2IngestFinish]（内核 `sync2_ingest_begin`），所以分叉判定与一次收完完全相同、与怎么分批无关。
  Future<void> sync2IngestBegin();

  /// 会话里收一批：写锁里 ingest，远端操作投递并提交，投影变化接进本机缓存。返回内核这一批的结果（`fork`
  /// 恒为 false）。
  Future<Map<String, Object?>> sync2IngestBatch(
    List<Uint8List> segments, {
    String? keyHex,
  });

  /// 收尾：累积出分叉点就换身份；返回同形结果（`fork`、重签发带来的投影变化）。
  Future<Map<String, Object?>> sync2IngestFinish();
}

/// 状态摘要最多多久重算一次（版本向量没变就不算）。
const Duration kSrsSync2DigestInterval = Duration(minutes: 10);

/// head 内容没变时最多隔多久仍写一次（别的设备显示的「最后在线」与本机校时靠它刷新）。没变的一轮不写 head、
/// 也就不拿服务端时间（[SrsSync2Report.serverTimeMs] 为 null）。
const Duration kSrsSync2HeadHeartbeat = Duration(hours: 6);

/// 一次 ingest 收进本机的段字节预算（按实际下载到的字节累计，到了就切批）。
///
/// 取值理由：段按压缩后体积切，单段上限 4 MiB（内核 `segment.rs` 的 `SEGMENT_TARGET_BYTES`），老版本写的段上限
/// 64 KB。按段数分批（以前每批 128 段）在大段下一批能到 512 MB、整批跨 FFI 拷进内核再解压，移动端会被杀；按字节
/// 切则与段多大无关。8 MiB 与旧设计「128 个 64 KB 段 ≈ 8 MB 一批」同量级：老段的批大小与进度粒度不变，大段一批
/// 也至少两段。预算到了不再开新下载、只等在途的（读完之前不知道段多大），所以一批的实际上界是
/// 预算 + [kSrsSync2Concurrency] × 单段上限（≈ 32 MiB），Dart 侧与内核各持一份也在百兆以内。
const int kSrsSync2IngestBudgetBytes = 8 * 1024 * 1024;

/// 调用方要求中途收手（库要关 / 调度器卸下）：已收的批次都已提交，下一轮接着拉。
const String kSrsSync2Stopped = 'srs sync round stopped';

/// 发件的一批在上传与确认之间被内核改切（并发的另一轮跑了小段合并）：这一轮不写 head，下一轮从水位续发。
const String kSrsSync2OutboxRecut = 'srs outbox batch was re-cut';

/// 本协议版本（`meta.json` 的 `v`）与能读它的最低读者版本（与内核 segment.rs `PROTOCOL` / `MIN_READER` 同值）。
///
/// 2 = 2026-10-30 断代：集合根从 `v2/` 挪到 `v3/`（srs_location_store.dart [kSrsSync2Folder]），媒体只剩内容寻址；
/// 协议 1 的位置由一次性迁移搬过来（srs_location_migration.dart），旧根上只留一份 `minReader` = 2 的 `meta.json`
/// 让旧版本停下。
const int kSrsSync2Protocol = 2;
const int kSrsSync2MinReader = 2;

/// 一轮的结果。
class SrsSync2Report {
  SrsSync2Report();

  /// 这一轮应用的远端操作条数。
  int applied = 0;

  /// 收到但因果还不满足、留在缓冲里的条数。
  int pending = 0;

  /// 这一轮上传的段数。
  int uploaded = 0;

  /// 这一轮转发到这个位置的文件数（别的设备的转发件与 head，见 [srsRelayToLocation]）。
  int relayed = 0;

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

/// 跑一轮。[locationId] 是这个位置的稳定身份（本机记每个位置传到了哪）；[key] = 本机为这个位置记的密钥
/// （见 srs_location_crypto.dart [srsLocationHandshake]：位置是加密的而本机没有 / 不对 → 这一轮不同步，报
/// [kSrsSync2NeedsKey] / [kSrsSync2WrongKey]；本机开过加密而位置上的 `kdf` 不见了 → [kSrsSync2EncryptionMissing]，
/// 绝不降级成明文；本机刚开加密 → 这一轮把 `kdf` 写进 `meta.json`）；[archive] = 归档位置：只写不删（不清本机
/// 的旧 head，设计 §10.3）。[onFetchProgress] 报下载 + 收进本机的段数（开拉前一次 `(0, 总数)`，之后每批一次）；
/// [onUploadStart] 在开始发件时调一次；[beforeUpload] 在发件之前调一次（参数 = 这个位置的密钥，明文位置为 null），
/// 用来先传媒体；[shouldStop] 每批收完后问一次，为真就以 [kSrsSync2Stopped] 收手（已收的
/// 批次都已提交）；发件的每批确认后也问一次（已确认的批次水位已持久化）。[ingestBudgetBytes] 见
/// [kSrsSync2IngestBudgetBytes]；[fetchConcurrency] = 拉段时同时在途的下载数；[outboxBudgetBytes] = 发件一批的
/// 字节预算（null = 内核默认 `OUTBOX_BATCH_BYTES`，测试用小值逼出多批）。
Future<SrsSync2Report> srsSync2Round({
  required SrsSync2Host host,
  required SrsLocationStore location,
  required String locationId,
  required int Function() nowMs,
  SrsLocationKey? key,
  bool archive = false,
  void Function(int done, int total)? onFetchProgress,
  void Function()? onUploadStart,
  Future<void> Function(String? keyHex)? beforeUpload,
  bool Function()? shouldStop,
  int ingestBudgetBytes = kSrsSync2IngestBudgetBytes,
  int fetchConcurrency = kSrsSync2Concurrency,
  int? outboxBudgetBytes,
}) async {
  final SrsSync2Report report = SrsSync2Report();
  // meta.json：协议版本与集合身份，创建后只读（§6.1）；加密握手（§9）以位置上的 kdf 为准。
  final Map<String, Object?> id = (await host.sync2Command(<String, Object?>{
    'op': 'identity',
    'now': nowMs(),
  })).map;
  final SrsLocationHandshake hs = await srsLocationHandshake(
    location,
    key: key,
    collection: id['collection'],
    nowMs: nowMs(),
    protocol: kSrsSync2Protocol,
    minReader: kSrsSync2MinReader,
  );
  report.kdf = hs.kdf;
  report.encryptionEnabled = hs.encryptionEnabled;
  if (hs.needsUpgrade) {
    report.needsUpgrade = true;
    return report;
  }
  if (hs.error != null) {
    report.error = hs.error;
    return report;
  }
  final String? keyHex = hs.keyHex;
  report.encrypted = keyHex != null;
  // 上传进度按「位置 + 密钥指纹」记：开加密之前传过的明文段、或用另一把密钥（并发开加密时输掉的那份 kdf）
  // 传过的密文段，本机全部按当前密钥重传一遍（同名覆盖）。
  final String progressId = srsLocationProgressId(locationId, keyHex);

  // 1–2. 读全部 head → 拉缺的段 → 收。需要更新的读者（有设备的 head 要求）就停在这里，一个字节也不写（§8）。
  if (!await srsSync2Pull(
    host: host,
    location: location,
    progressId: progressId,
    keyHex: keyHex,
    report: report,
    onFetchProgress: onFetchProgress,
    shouldStop: shouldStop,
    ingestBudgetBytes: ingestBudgetBytes,
    fetchConcurrency: fetchConcurrency,
  )) {
    return report;
  }

  // 3. 发件：先段、后 head。分批（内核 `sync2_outbox` 按字节 / 段数上限产出一批，见 transport.rs
  // `OUTBOX_BATCH_BYTES`）：一批全部写成后 `outbox_ack` 持久化水位，再取下一批——内存里同一时刻只有一批，
  // 上传中途断网 / 被杀只丢在途那一批，下一轮从水位接着发（以前一次取全部积压，断一次整份重来，反馈
  // XDV7Mzc2gw / kB2ltk0u9F / U37Aku3oeL）。head 仍在全部批次写完后才写，读者看到的永远是一致前缀。
  // 媒体先于引用它的段（设计 §6.1 写入纪律 3，审查 S-10）：本机新绑定的媒体此刻先传上去（绑定本身是操作，随下面
  // 的段一起发），读到这些段的设备就拿得到它们引用的内容。媒体失败由调用方处理，不打断操作同步。
  if (beforeUpload != null) await beforeUpload(keyHex);
  onUploadStart?.call();
  int upto = 0;
  while (true) {
    final SrsSync2Result out = await host.sync2Command(<String, Object?>{
      'op': 'outbox',
      'location': progressId,
      'key': keyHex,
      if (outboxBudgetBytes != null) 'maxBytes': outboxBudgetBytes,
    });
    upto = (out.map['upto'] as int?) ?? 0;
    if (out.files.isEmpty) break;
    await srsRunPooled(out.files, kSrsSync2Concurrency, (
      (String, Uint8List) f,
    ) async {
      await location.put(f.$1, f.$2);
      report.uploaded++;
    });
    final Map<String, Object?> ack = (await host.sync2Command(<String, Object?>{
      'op': 'outbox_ack',
      'location': progressId,
      'segments': out.map['segments'],
    })).map;
    if (ack['accepted'] != true) {
      // 发件与确认之间段被改切（只会是并发的另一轮跑了合并）：没对上的段不算数，这一轮不写 head，
      // 下一轮按当前切法从水位续发。
      return report..error = kSrsSync2OutboxRecut;
    }
    upto = (ack['uploaded'] as int?) ?? upto;
    if (out.map['more'] != true) break;
    if (shouldStop?.call() ?? false) return report..error = kSrsSync2Stopped;
  }
  // 3½. 转发（反熵，设计 §6.3）：本机持有、而这个位置缺的别的设备的段（作者签名的转发件 `rly-…`）与 head 原文。
  // 不转发的话只经别的位置连着本机的设备的操作永远到不了这里，本机之后的操作（上下文含它们）在读者那里也因果
  // 投递不了（审查 S-1）。段先、head 后：内核只在一台设备的段都确认写上之后才给它的 head。
  await srsRelayToLocation(
    host: host,
    location: location,
    progressId: progressId,
    keyHex: keyHex,
    archive: archive,
    budgetBytes: outboxBudgetBytes,
    onWritten: () => report.relayed++,
    shouldStop: shouldStop,
  );

  // 状态摘要随 head 发布（§4.5：同一版本向量下两台设备摘要不同 = 确定性 bug）。全库扫描，内核只在版本向量
  // 变了且离上次满 [kSrsSync2DigestInterval] 时才重算，读连接上算、不占写锁。
  await host.sync2Command(<String, Object?>{
    'op': 'digest',
    'now': nowMs(),
    'minIntervalMs': kSrsSync2DigestInterval.inMilliseconds,
  });
  final String self =
      (await host.sync2Command(<String, Object?>{
            'op': 'identity',
            'now': nowMs(),
          })).map['device']!
          as String;
  // head 内容（发布的段、ack、摘要）与上次写到这个位置的相同就不写：每写一次 head 都会唤醒连着这个位置的全部设备
  // （互联 host 按 head 写入推进长轮询令牌，写的设备自己也在等），空 head 让同步一轮接一轮不停。上次那个 head
  // 此刻不在位置上（写 head 前断网 / 被清掉）就照写。
  SrsSync2Result head = await host.sync2Command(<String, Object?>{
    'op': 'head',
    'location': progressId,
    'upto': upto,
    'now': nowMs(),
    'skipUnchangedMs': kSrsSync2HeadHeartbeat.inMilliseconds,
  });
  if (head.map['unchanged'] == true) {
    final String last = head.map['path']! as String;
    final String lastName = last.substring(last.lastIndexOf('/') + 1);
    final bool present = (await location.list(
      'devices/$self',
    )).any((SrsLocationEntry f) => f.name == lastName);
    if (present) {
      // head 没变也交出待删清单：上一轮删到一半失败（或 head 上传失败没走到删除）的旧段 / 旧转发件这一轮再删。
      await srsDeleteAndAck(
        host: host,
        location: location,
        progressId: progressId,
        paths: _pathsOf(head.map['delete']),
        archive: archive,
      );
      return report;
    }
    head = await host.sync2Command(<String, Object?>{
      'op': 'head',
      'location': progressId,
      'upto': upto,
      'now': nowMs(),
    });
  }
  String? written;
  for (final (String path, Uint8List bytes) in head.files) {
    await location.put(path, bytes);
    written = path.substring(path.lastIndexOf('/') + 1);
  }
  // 小段合并（§7.1）换下来的旧小段（新 head 已不再引用、过了宽限期）与没删成的旧转发件：两段式，删成功才确认
  // （内核 `obsolete_ack`），失败的下一轮再给。归档位置一个不删（只确认）。
  await srsDeleteAndAck(
    host: host,
    location: location,
    progressId: progressId,
    paths: _pathsOf(head.map['delete']),
    archive: archive,
  );
  final List<String> stale = <String>[];

  // 4. 本机两代以前的 head；顺便取服务端时间。
  final int gen = (head.map['gen'] as int?) ?? 0;
  for (final SrsLocationEntry f in await location.list('devices/$self')) {
    final int? g = _headGen(f.name);
    if (!archive && g != null && g < gen - 2) {
      stale.add('devices/$self/${f.name}');
    }
    if (f.name == written) report.serverTimeMs = f.modifiedAt;
  }
  await srsRunPooled(stale, kSrsSync2Concurrency, location.delete);
  return report;
}

/// 一轮的读半边（§6.2 第 1–3 步）：读 [location] 上全部设备的 head（每台取代号最大的，同一代号的都要）→ 内核定要拉
/// 的段 → 分批拉、分批收。结果累加进 [report]。返回 false = 这一轮到此为止：中途收手（[report] 的 error 是
/// [kSrsSync2Stopped]）或有设备的 head 要求更新的读者（[SrsSync2Report.needsUpgrade]，什么都没收）。v1 位置的
/// 一次性迁移也用它先把旧根上的段收进本机（srs_location_migration.dart），再补媒体绑定。
Future<bool> srsSync2Pull({
  required SrsSync2Host host,
  required SrsLocationStore location,
  required String progressId,
  required String? keyHex,
  required SrsSync2Report report,
  void Function(int done, int total)? onFetchProgress,
  bool Function()? shouldStop,
  int ingestBudgetBytes = kSrsSync2IngestBudgetBytes,
  int fetchConcurrency = kSrsSync2Concurrency,
}) async {
  // 1. 全部设备的 head：每台设备取代号最大的（同一代号的都要）。
  final List<String> deviceDirs = <String>[
    for (final SrsLocationEntry d in await location.list('devices'))
      if (d.isFolder) 'devices/${d.name}',
  ];
  final List<List<String>> headPaths = await srsRunPooled(
    deviceDirs,
    kSrsSync2Concurrency,
    (String dir) async {
      int top = -1;
      final Map<String, int> genOf = <String, int>{};
      for (final SrsLocationEntry f in await location.list(dir)) {
        final int? g = _headGen(f.name);
        if (g == null) continue;
        genOf[f.name] = g;
        if (g > top) top = g;
      }
      return <String>[
        for (final MapEntry<String, int> e in genOf.entries)
          if (e.value == top) '$dir/${e.key}',
      ];
    },
  );
  final List<Uint8List> heads = <Uint8List>[
    for (final Uint8List? b in await srsRunPooled(
      <String>[for (final List<String> p in headPaths) ...p],
      kSrsSync2Concurrency,
      location.get,
    ))
      ?b,
  ];

  // 2. 定要拉的段 → 拉 → 收。
  // `location`：内核记下这个位置上有谁的哪些段（别的位置缺、本机可以转发的，见步骤 3 之后的转发）。
  final Map<String, Object?> plan = (await host.sync2Command(<String, Object?>{
    'op': 'plan',
    'location': progressId,
  }, blobs: heads)).map;
  if (plan['needsUpgrade'] == true) {
    // 有设备的 head 声明的最低读者版本比本机新：内核没收它，这一轮整个停下（不收、不发、不写 head）。
    report.needsUpgrade = true;
    return false;
  }
  // 本机身份的段只用来比链找分叉点：内核在收段会话里跨批累积、收尾才换身份（[SrsSync2Host.sync2IngestBegin]），
  // 所以它们和别的段一样受字节预算约束。
  final List<String> wanted = <String>[
    for (final Object? f in (plan['fetch'] as List?) ?? const <Object?>[])
      for (final Object? name
          in ((f! as Map)['files'] as List?) ?? const <Object?>[])
        name! as String,
  ];
  // 分批拉、分批收（首次同步一台老设备可能是几千个段）：每批独立提交，中途断网 / 被杀 / 关库都只丢在途
  // 那一批（已收的进了本机投影或因果缓冲，plan 下一轮不再要它们）；写锁每批只占一小会儿，复习写入不被
  // 整轮挡住；返回给 Dart 的投影变化也按批解析，不会一次把几十万条事件压在 UI isolate 上。中途收手不收尾：
  // 分叉点可能还没看全，不换身份，下一轮 plan 照样再要本机身份的段。
  void absorb(Map<String, Object?> r) {
    report.applied += (r['applied'] as int?) ?? 0;
    report.pending = (r['pending'] as int?) ?? 0;
    report.fork = report.fork || r['fork'] == true;
    report.changed =
        report.changed ||
        (((r['marks'] as Map?)?['landed'] as int?) ?? 0) > 0 ||
        ((r['replayed'] as List?)?.isNotEmpty ?? false) ||
        ((r['changed'] as List?)?.isNotEmpty ?? false);
    report.errors.addAll(<String>[
      for (final Object? x in (r['errors'] as List?) ?? const <Object?>[]) '$x',
    ]);
  }

  if (wanted.isNotEmpty) {
    int done = 0;
    onFetchProgress?.call(0, wanted.length);
    await host.sync2IngestBegin();
    await for (final SrsFetchedBatch batch in srsFetchInBatches(
      wanted,
      fetch: (String path) => srsFetchSegment(location, path),
      budgetBytes: ingestBudgetBytes,
      concurrency: fetchConcurrency,
    )) {
      // head 指向的段暂时还列不到（最终一致）的不在 batch.segments 里：这一轮跳过，下一轮再来。
      if (batch.segments.isNotEmpty) {
        absorb(await host.sync2IngestBatch(batch.segments, keyHex: keyHex));
      }
      done += batch.covered;
      onFetchProgress?.call(done, wanted.length);
      if (shouldStop?.call() ?? false) {
        report.error = kSrsSync2Stopped;
        return false;
      }
    }
    absorb(await host.sync2IngestFinish());
  } else if (plan['finishPending'] == true) {
    // 上一轮收段被打断在收尾之前：受影响的卡还在内核的待重放集合里（审查 S-4），这一轮没段可拉也收个尾。
    await host.sync2IngestBegin();
    absorb(await host.sync2IngestFinish());
  }
  return true;
}

List<String> _pathsOf(Object? list) => <String>[
  for (final Object? p in (list as List?) ?? const <Object?>[]) p! as String,
];

/// 两段式删除（集成审查【中】）：删掉内核给的待删清单 [paths]（`head` / `relay_ack` 的 `delete`），**只把删成功的**
/// 发 `obsolete_ack` 让内核移除记录；没删成的留在内核的待删表里，下一轮照样再给（[SrsLocationStore.delete] 对不存在
/// 的文件视为成功，重删幂等）。以前内核交出清单时就删了记录，head 上传或删除中途抛错，这批旧文件永远没人再删。
/// 归档位置（[archive]）按策略一个不删，直接确认。删除出错时先确认已删的那些，再原样抛出第一个错误。
Future<void> srsDeleteAndAck({
  required SrsSync2Host host,
  required SrsLocationStore location,
  required String progressId,
  required List<String> paths,
  required bool archive,
}) async {
  if (paths.isEmpty) return;
  final List<String> done = <String>[if (archive) ...paths];
  Object? error;
  StackTrace? stack;
  if (!archive) {
    try {
      await srsRunPooled(paths, kSrsSync2Concurrency, (String path) async {
        await location.delete(path);
        done.add(path);
      });
    } catch (e, s) {
      error = e;
      stack = s;
    }
  }
  if (done.isNotEmpty) {
    await host.sync2Command(<String, Object?>{
      'op': 'obsolete_ack',
      'location': progressId,
      'deleted': done,
    });
  }
  if (error != null) Error.throwWithStackTrace(error, stack!);
}

/// 段文件对应的转发件路径（`devices/<设备>/seg-…` → `rly-…`，内核 segment.rs `relay_file_name`）；不是段文件原样返回。
String srsRelayPath(String path) {
  final int slash = path.lastIndexOf('/');
  final String name = path.substring(slash + 1);
  if (!name.startsWith('seg-')) return path;
  return '${path.substring(0, slash + 1)}rly-${name.substring(4)}';
}

/// 拉一个段：作者自己写的 `seg-…` 不在就找别的设备转发来的同名 `rly-…`（作者没连过这个位置时只有后者）。
Future<Uint8List?> srsFetchSegment(
  SrsLocationStore location,
  String path,
) async {
  final Uint8List? own = await location.get(path);
  if (own != null) return own;
  final String relayed = srsRelayPath(path);
  return relayed == path ? null : location.get(relayed);
}

/// 把本机持有、而 [location] 缺的别的设备的段与 head 转发过去（内核 `relay_outbox` / `relay_ack`，
/// store/sync2/relay.rs）：一批全部写成再确认，确认后内核才给段都已到位的设备的 head；被新转发的 head 取代的旧
/// 转发件按内核给的清单删（归档位置一个不删），删成功才确认（[srsDeleteAndAck]）。[onWritten] 每写一个文件调一次。
Future<void> srsRelayToLocation({
  required SrsSync2Host host,
  required SrsLocationStore location,
  required String progressId,
  required String? keyHex,
  required bool archive,
  int? budgetBytes,
  void Function()? onWritten,
  bool Function()? shouldStop,
}) async {
  while (true) {
    final SrsSync2Result out = await host.sync2Command(<String, Object?>{
      'op': 'relay_outbox',
      'location': progressId,
      'key': keyHex,
      if (budgetBytes != null) 'maxBytes': budgetBytes,
    });
    if (out.files.isEmpty) return;
    await srsRunPooled(out.files, kSrsSync2Concurrency, (
      (String, Uint8List) f,
    ) async {
      await location.put(f.$1, f.$2);
      onWritten?.call();
    });
    final Map<String, Object?> ack = (await host.sync2Command(<String, Object?>{
      'op': 'relay_ack',
      'location': progressId,
      'paths': <String>[for (final (String, Uint8List) f in out.files) f.$1],
    })).map;
    // 被取代的旧转发件 / 旧转发 head：两段式删（失败的下一轮由这里或 head 那一步再给）。
    await srsDeleteAndAck(
      host: host,
      location: location,
      progressId: progressId,
      paths: _pathsOf(ack['delete']),
      archive: archive,
    );
    if (out.map['more'] != true) return;
    if (shouldStop?.call() ?? false) return;
  }
}

/// [srsFetchInBatches] 的一批。
class SrsFetchedBatch {
  const SrsFetchedBatch(this.segments, {required this.covered});

  /// 这一批读到的内容，按路径原顺序；不存在的路径不在里面。
  final List<Uint8List> segments;

  /// 这一批走过的路径数（含不存在的）。
  final int covered;
}

/// 按原顺序读 [paths]，同时最多 [concurrency] 个在途，按实际读到的字节切批：一批累计到 [budgetBytes] 就不再开
/// 新的读、等在途的读完后交出这一批（在途的读完之前不知道多大，所以一批最多超出预算 [concurrency] 个文件），
/// 消费方收完再开下一批（同一时刻内存里只有一批）。每批至少一个路径，所以单个超过预算的文件自成一批；
/// [paths] 为空时也交出一个空批。
/// 任一读失败：不再开新的，等在途的跑完后抛出第一个错误（与 [srsRunPooled] 一致）。消费方中途停止监听，
/// 当前批读完后就不再读。
Stream<SrsFetchedBatch> srsFetchInBatches(
  List<String> paths, {
  required Future<Uint8List?> Function(String path) fetch,
  required int budgetBytes,
  int concurrency = kSrsSync2Concurrency,
}) async* {
  assert(budgetBytes > 0 && concurrency > 0);
  int next = 0;
  do {
    final int start = next;
    final Map<int, Uint8List> got = <int, Uint8List>{};
    int bytes = 0;
    Object? error;
    StackTrace? stack;
    Future<void> worker() async {
      while (error == null &&
          next < paths.length &&
          (next == start || bytes < budgetBytes)) {
        final int i = next++;
        try {
          final Uint8List? b = await fetch(paths[i]);
          if (b != null) {
            got[i] = b;
            bytes += b.length;
          }
        } catch (e, s) {
          error ??= e;
          stack ??= s;
        }
      }
    }

    await Future.wait(<Future<void>>[
      for (int w = 0; w < min(concurrency, paths.length - start); w++) worker(),
    ]);
    final Object? failure = error;
    if (failure != null) Error.throwWithStackTrace(failure, stack!);
    yield SrsFetchedBatch(<Uint8List>[
      for (int i = start; i < next; i++) ?got[i],
    ], covered: next - start);
  } while (next < paths.length);
}

/// `head-<gen>-<tag>.json` 的代号；不是 head 返回 null。
int? _headGen(String name) {
  if (!name.startsWith('head-') || !name.endsWith('.json')) return null;
  final String rest = name.substring(5, name.length - 5);
  final int dash = rest.indexOf('-');
  return int.tryParse(dash < 0 ? rest : rest.substring(0, dash));
}
