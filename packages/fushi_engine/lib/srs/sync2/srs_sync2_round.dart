/// 复习同步的一轮（新代，设计 2026-11-11 §4；内核 `native/fushi_fsrs/src/store/gen4/cmd/sync.rs`，G8-7）：
///
/// 0. 位置的根（`location_root`）：新根 `v4/meta.json` 与 loc 标记由内核写定，旧根 `v3/meta.json` 改写成让协议 3 的
///    版本停下的围栏；新集合预先立围栏与墓碑 head。加密握手（[srsLocationHandshake]）照旧判口令，只看不写。
/// 1. 读位置上全部设备的 head（每台取代号最大的），连同各设备目录的文件名交给内核（`plan`）：记公钥 / 名字、判本机
///    身份分叉、定要拉的原生段与承袭段；有设备要求更新的读者就整轮停下。
/// 2. 只拉缺的段 → 分批收（`ingest`，每批一个写事务）→ 有分叉点就收尾换身份（`ingest_finish`）。
/// 3. 发件：本机原生日志从「已传到这个位置」的水位起切段、签名、按位置钥匙封装 → 上传 → `outbox_ack` → 写新 head
///    （**先读后写**：同一身份的另一个安装刚写的 head 不会被自己这一轮的 head 挡住视线）。
/// 4. 收尾：列本机目录交给内核（`obsolete`），删旧 head 与不再被引用的旧段；归档位置都不删。
///
/// 写入纪律：先写段、再写 head；读者只认「head 引用的段都可读」的前缀。传输只经 [SrsLocationStore]（[location] 是
/// 新根 `v4/`，[oldRoot] 是旧根 `v3/`）。转发（别的设备的段经本机转到这个位置）、媒体命令归 G8-7b，这一轮不做。
///
/// 读写文件同时最多 [kSrsSync2Concurrency] 个在途：网盘每个请求的固定延迟远大于传输本身。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:fushi_engine/srs/sync2/srs_location_crypto.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync4_steps.dart';
import 'package:fushi_engine/srs/sync2/srs_v1_fence.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsSync2Result;

/// 一轮同步要的内核接口（[SrsDbStore] 实现；测试可替身）。
abstract interface class SrsSync2Host {
  String get profileUid;

  /// 不改投影的命令（看 head、发件、写 head、摘要、状态）。
  Future<SrsSync2Result> sync2Command(
    Map<String, Object?> request, {
    List<Uint8List> blobs = const <Uint8List>[],
  });

  /// 开一段收段（Dart 侧：整 profile 的 RWKV 回放排到它之后）。新代内核没有收段会话：每批一个写事务，分叉点记在
  /// 库里，[sync2IngestFinish] 换身份（内核 `cmd/sync.rs`）。
  Future<void> sync2IngestBegin();

  /// 收一批（内核 `ingest`，一个写事务：核对、按因果投递、派生层收尾），本机状态行的修订号随之推进。返回内核这一批
  /// 的结果（`fork` = 这一批里本机身份的段与本机日志分叉了，记下了分叉点）。[location] = 这一批是从哪个位置读的
  /// （与 `plan` 的 `location` 同值）：内核据此把等 Purge / 等信任变化的重切件停在这个位置上，之后只在等的事发生时
  /// 才再拉（内核 `cmd/sync_park.rs`）。
  Future<Map<String, Object?>> sync2IngestBatch(
    List<Uint8List> segments, {
    String? keyHex,
    String? location,
  });

  /// 收尾（内核 `ingest_finish`）：记下过分叉点就换身份、分叉点之后的本机操作以新身份重签发；返回 `fork` 等。
  Future<Map<String, Object?>> sync2IngestFinish();

  /// 结束 [sync2IngestBegin] 开的那一段（Dart 侧；内核没有要放的东西）。
  Future<void> sync2IngestEnd();
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
/// 预算 + [kSrsSync2Concurrency] × 单段上限（≈ 32 MiB）。内核收一批时 Dart 侧预读下一批（[srsFetchInBatches]），
/// 同一时刻最多两批在 Dart 侧、一批在内核，仍在百兆以内。
const int kSrsSync2IngestBudgetBytes = 8 * 1024 * 1024;

/// 调用方要求中途收手（库要关 / 调度器卸下）：已收的批次都已提交，下一轮接着拉。
const String kSrsSync2Stopped = 'srs sync round stopped';

/// 发件的一批在上传与确认之间被内核改切（并发的另一轮跑了小段合并）：这一轮不写 head，下一轮从水位续发。
const String kSrsSync2OutboxRecut = 'srs outbox batch was re-cut';

/// 本协议版本（`meta.json` 的 `v`，与内核 segment.rs `PROTOCOL` 同值）与能读这个**目录布局**的最低读者版本
/// （`meta.json` 的 `minReader`）。
///
/// [kSrsSync2MinReader] 只管目录布局层（集合根、文件命名、媒体寻址），布局不变就不动；段里**内容**要求的最低读者
/// 由内核按本机实际写出的内容声明在 head 的 `minReader` 里（native/fushi_fsrs/src/sync2/min_reader.rs，地板值 3，
/// 与这里同值但互不联动）。以后升协议只要布局没变，这里保持 3，v3.3.0 读者就能继续和没用到新内容的设备同步。
///
/// 2 = 2026-10-30 断代：集合根从 `v2/` 挪到 `v3/`（srs_location_store.dart [kSrsSync2Folder]），媒体只剩内容寻址；
/// 协议 1 的位置当时由一次性迁移搬过来（新代已删那份迁移，只有协议 1 旧根的位置一律拒绝，D21），旧根上只留一份
/// 让旧版本停下的围栏（srs_v1_fence.dart）。
///
/// 3 = 存量重复流收敛（BUG-4005，内核 store/sync2/dedup.rs）：段里出现新种类 `Dedup` 与带副本说明的骨架，协议 2 的
/// 读者解不开，head 的 `minReader` = 3 让它们停下、报需要升级（[SrsSync2Report.needsUpgrade]）。
///
/// 4 = 新代（设计 2026-11-11 §4，G8-7）：集合根挪到 `v4/`，`meta.json` 由内核写定（`location_root`），旧根 `v3/meta.json`
/// 改写成 `minReader` 4 的围栏让协议 3 的版本停下。
const int kSrsSync2Protocol = 4;
const int kSrsSync2MinReader = 4;

/// 新代集合根的目录名（内核 `gen4/location.rs` `NEW_ROOT`）。
const String kSrs4Root = 'v4';

/// `location_root` 的结论（内核 `cmd/sync.rs` `ROOT_*`）：可以同步 / 要更新的版本 / 位置上的根认不得（别的集合、
/// 坏 meta），什么都不写。
const String kSrs4RootOk = 'ok';
const String kSrs4RootNeedsUpgrade = 'needsUpgrade';

/// 位置上的新根 meta 与本机对不上（别的集合 / 认不得的外形）：这一轮不同步，什么都不写。
const String kSrs4LocationRefused = 'srs location root refused';

/// 位置只有协议 1 旧根 `v2/`（内核 `oldroot.rs` `ERR_PROTOCOL1_ROOT`，同一个机读码）：这一轮的 [SrsSync2Report.error]
/// 正好是它，界面据此给专门的升级提示（先用 3.x 同步一次把位置升级，或换位置；本机卡片不受影响），不当一般错误报。
const String kSrsLocationProtocol1Root = 'srs_location_protocol1_root';

/// 旧根 `v3/meta.json` 是本版本立的围栏、新根 `v4/` 下却什么都列不到（没有 meta、设备 / 媒体数据、loc 标记；内核
/// `gen4/cmd/sync.rs` `ERR_NEW_ROOT_MISSING`，同一个机读码）：新根多半被整个删了。不重建（新根原来的媒体根 / `kdf`
/// 从围栏推不出来），这一轮的 [SrsSync2Report.error] 正好是它，界面据此说明恢复办法——它不像 [kSrsSync2MetaUnavailable]
/// 那样等下去会自己好。
const String kSrsLocationNewRootMissing = 'srs_location_new_root_missing';

/// 不是一个同步位置的读（v1 旧根的一次性迁移）：`plan` 记位置上的 head 时用的位置名。
const String kSrs4NoLocation = 'oldroot';

/// 一轮的结果。
class SrsSync2Report {
  SrsSync2Report();

  /// 这一轮应用的远端操作条数。
  int applied = 0;

  /// 收到但因果还不满足、留在缓冲里的条数。
  int pending = 0;

  /// 内核要拉、位置上却没读到的段数（head 指向的段暂时还列不到，最终一致）：这一轮跳过，下一轮再来。
  int missing = 0;

  /// 这一轮上传的段数。
  int uploaded = 0;

  /// 这一轮转发到这个位置的文件数（中继件 `rly-` 与被转发的 head `rhd-`，[srsSync4Relay]）。
  int relayed = 0;

  /// 发现本机身份分叉（已换身份重签发）。
  bool fork = false;

  /// 投影有变化（Dart 侧要刷新界面）。
  bool changed = false;

  /// 位置上的数据来自更新版本、本机读不了（`meta.json` 的 `minReader` 比本机新）：停写并提示升级（§8）。
  bool needsUpgrade = false;

  /// 写 head 那一刻的服务端时间（校时用；后端给不出为 null）。
  int? serverTimeMs;

  /// [serverTimeMs] 被盖下那一刻本机的开机时钟（含睡眠，[SrsTrustedClock.bootNowMs]；只有调用方给了
  /// `bootClockMs` 才有，要校时就必须给）：写 head 那次上传前后
  /// 两次读数的中点（误差 ≤ 上传耗时的一半）。校时必须把服务器时间与**同一刻**的本机时钟配对：以前拿一轮开头的
  /// 时钟读数去配这一轮末尾的服务器时间，整轮同步的耗时（大库、卡顿时十几分钟）全算成了「本机时钟落后」，可信
  /// 时间因此超前同样的时长。
  int? serverTimeBootMs;

  /// 这个位置这一轮没同步成的原因（调度器据此如实报「未同步」）；null = 成功。
  String? error;

  /// 这一轮所在的集合目录名（`fushi-srs/<它>/`，内核 `identity` 回包的 `dir`；一轮一开头就取，任何 [error] 都在它
  /// 之后）。界面给恢复办法时要写出真实路径（[kSrsLocationNewRootMissing]：删掉 `fushi-srs/<它>/v3/meta.json`）。
  String? locationDir;

  /// 位置开了加密（`meta.json` 有 `kdf`）时它的参数；UI 让用户输入口令时用同一份盐与参数派生。
  SrsKdf? kdf;

  /// 这一轮把本机的「开加密」写进了位置的 `meta.json`（调度器据此把本机密钥标成已生效）。
  bool encryptionEnabled = false;

  /// 这一轮实际用密钥收发（位置是加密的且本机口令对）。
  bool encrypted = false;

  /// 这个位置的媒体在哪个根（内核 `location_root` 的 `media`：存量集合 [kSrsSync2Folder]、新集合 [kSrs4Root]）；
  /// 没走到根那一步为 null。
  String? mediaRoot;

  /// 位置那头自己也跑复习同步的设备（互联 host）报告它还没加入复习同步（BUG-4320）：本机这一轮发出去了，但对端既
  /// 不并入、也没发布它自己的数据。调度器在一轮成功后填（引擎的一轮不碰它）；不算这一轮失败。
  bool peerNotJoined = false;

  /// 非致命错误（段损坏 / 签名不符 / 解不开……）：记日志，不打断这一轮。
  final List<String> errors = <String>[];

  /// 本机有内容、但因作者在本机待确认 / 已拒绝而**不替传**的承袭日志的作者（设备 ID，内核 `heritage_plan` 的
  /// `unvouched`，G10-4）：用户在设备页确认了那台设备，下一轮就补传。没走到承袭上传这一步为 null。只是提示，不算
  /// 这一轮失败。
  List<String>? heritageUnvouched;

  /// [heritageUnvouched] 里作者在本机还**待确认**的那部分（内核 `heritage_plan` 的 `pending`；已拒绝的不在里面）。
  /// 同步页只按它提示「等你确认」：用户有意拒绝的设备不该一直被催着去确认。null 的含义同 [heritageUnvouched]。
  List<String>? heritagePending;

  /// 清位置上本机旧身份的目录时没做成的（[srsSync4SweepFormer]），每项
  /// `<旧身份>: <原因>`。不算这一轮失败、也不算跳过了段（不进 [errors]）：这一轮自己的收发与 head 都已完成，旧
  /// 目录里多留几份旧 head 不影响任何设备读到的内容，内核过一个周期再让看。只供记日志。
  final List<String> formerSweepErrors = <String>[];

  /// 这一轮从位置目录里清掉的 v3.0.x 写入者目录（`<设备>#<化身号>`，`srsSweepLegacyWriters`，BUG-5017）。只供诊断。
  final List<String> legacyWritersRemoved = <String>[];

  /// 清 v3.0.x 写入者目录时没做成的（`srsSweepLegacyWriters`），每项 `<写入者目录>[/<文件>]: <原因>`。与
  /// [formerSweepErrors] 同理不算这一轮失败（那些文件没有任何受支持的版本读），下一轮再清。只供记日志。
  final List<String> legacyWriterErrors = <String>[];
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
/// 字节预算（null = 内核默认 `OUTBOX_BATCH_BYTES`，测试用小值逼出多批）；[outboxSegmentBytes] = 切段的目标体积
/// （null = 内核默认 `SEGMENT_TARGET_BYTES`，测试用小值逼出多段）。
/// 一轮里的细分步骤（诊断用）：调度器把它写进活动面包屑，进程死在一轮里时下次启动能报出死在哪一步、当时多少
/// 内存（反馈 i8qNDs_V_D：大库上一轮卡在「开始」4.5 分钟后被系统杀，开头这段原本只有一个阶段名）。只做记录，
/// 不得抛出、不得做慢事。
typedef SrsSyncStepCallback = void Function(String step);

Future<SrsSync2Report> srsSync2Round({
  required SrsSync2Host host,
  required SrsLocationStore location,
  required String locationId,
  required int Function() nowMs,
  SrsLocationStore? oldRoot,
  SrsLocationStore? protocol1Root,
  int Function()? bootClockMs,
  SrsLocationKey? key,
  bool archive = false,
  void Function(int done, int total)? onFetchProgress,
  void Function()? onUploadStart,
  Future<void> Function(String? keyHex)? beforeUpload,
  bool Function()? shouldStop,
  int ingestBudgetBytes = kSrsSync2IngestBudgetBytes,
  int fetchConcurrency = kSrsSync2Concurrency,
  int? outboxBudgetBytes,
  int? outboxSegmentBytes,
  SrsSyncStepCallback? onStep,
  void Function(SrsLocationRoot root)? onLocationRoot,
}) async {
  final SrsSync2Report report = SrsSync2Report();
  onStep?.call('identity');
  final Map<String, Object?> id = (await host.sync2Command(<String, Object?>{
    'op': 'identity',
    'now': nowMs(),
  })).map;
  report.locationDir = id['dir'] as String?;
  onStep?.call('handshake');
  final SrsLocationRoot? rooted = await srsSync4LocationRoot(
    host: host,
    location: location,
    oldRoot: oldRoot,
    protocol1Root: protocol1Root,
    locationId: locationId,
    nowMs: nowMs,
    key: key,
    collection: id['collection'],
    report: report,
  );
  if (rooted == null) return report;
  onLocationRoot?.call(rooted);
  final String? keyHex = rooted.keyHex;
  final String loc = rooted.loc;
  final String progressId = srsLocationProgressId(locationId, keyHex);

  // 1–2. 读全部 head → 拉缺的段 → 收。需要更新的读者（有设备的 head 要求）就停在这里，一个字节也不写。
  final Map<String, List<String>> listed = <String, List<String>>{};
  if (!await srsSync2Pull(
    host: host,
    location: location,
    progressId: progressId,
    keyHex: keyHex,
    report: report,
    nowMs: nowMs,
    loc: loc,
    onFetchProgress: onFetchProgress,
    shouldStop: shouldStop,
    ingestBudgetBytes: ingestBudgetBytes,
    fetchConcurrency: fetchConcurrency,
    onStep: onStep,
    listed: listed,
  )) {
    return report;
  }
  if (keyHex == null) {
    // 按明文收发的这一轮见到了对这个位置密封的段 / 本位置写的 head 带 `seal`（BUG-4299）：发件与 head 一个都不写。
    final SrsLocationSeal seal = await srsLocationSealed(host, locationId);
    if (seal.sealed) {
      return report
        ..kdf = seal.kdf
        ..error = srsSealedRefusal(seal);
    }
  }
  // 收段时可能换了身份（分叉）：发件用换完之后的身份。
  final String self =
      (await host.sync2Command(<String, Object?>{
            'op': 'identity',
            'now': nowMs(),
          })).map['device']!
          as String;
  final List<String> present = List<String>.of(
    listed['devices/$self'] ?? const <String>[],
  );

  // 2b. 旧根接手（G8-7b）：协议 3 旧根上的段收进本机承袭日志。
  if (oldRoot != null) {
    await srsSync4TakeOldRoot(
      host: host,
      oldRoot: oldRoot,
      locationId: locationId,
      keyHex: keyHex,
      report: report,
      nowMs: nowMs,
      budgetBytes: ingestBudgetBytes,
      shouldStop: shouldStop,
      onStep: onStep,
    );
    if (shouldStop?.call() ?? false) return report..error = kSrsSync2Stopped;
  }
  // 2c. 别的设备的媒体清单：本机媒体对账（发件前那一步）据此知道位置上有什么。
  await srsSync4MediaManifestsIn(
    host: host,
    location: location,
    locationId: locationId,
    listed: listed,
    report: report,
    nowMs: nowMs,
  );

  // 3. 发件：媒体 → 承袭段 → 本机原生段 → head，分批（一批全部写成后 `outbox_ack` 持久化水位，再取下一批）。媒体先于
  // 引用它的段；承袭段先于本机原生段（D19：新设备先拿到旧历史）。
  onStep?.call('beforeUpload');
  if (beforeUpload != null) await beforeUpload(keyHex);
  onUploadStart?.call();
  await srsSync4UploadHeritage(
    host: host,
    location: location,
    progressId: progressId,
    keyHex: keyHex,
    listed: listed,
    report: report,
    onStep: onStep,
  );
  bool audited = false;
  while (true) {
    final SrsSync2Result out = await host.sync2Command(<String, Object?>{
      'op': 'outbox',
      'progress': progressId,
      'key': keyHex,
      if (outboxBudgetBytes != null) 'maxBytes': outboxBudgetBytes,
      if (outboxSegmentBytes != null) 'segBytes': outboxSegmentBytes,
      if (!audited) 'present': present,
    });
    audited = true;
    if (out.files.isEmpty) break;
    await srsRunPooled(out.files, kSrsSync2Concurrency, (
      (String, Uint8List) f,
    ) async {
      await location.put(f.$1, f.$2);
      report.uploaded++;
    });
    final Map<String, Object?> ack = (await host.sync2Command(<String, Object?>{
      'op': 'outbox_ack',
      'progress': progressId,
      'segments': out.map['segments'],
    })).map;
    if (ack['accepted'] != true) {
      // 发件与确认之间本机日志变了（清除了这一批里的操作）：这一轮不写 head，下一轮按当前日志重切。
      return report..error = kSrsSync2OutboxRecut;
    }
    if (out.map['more'] != true) break;
    if (shouldStop?.call() ?? false) return report..error = kSrsSync2Stopped;
  }

  // 4. head：内容与上次写到这个位置的相同、离上次没满心跳间隔就不写（每写一次 head 都会唤醒连着这个位置的设备）；
  // 上次那个 head 此刻不在位置上就照写。
  Map<String, Object?> headRequest({required bool skip}) => <String, Object?>{
    'op': 'head',
    'location': locationId,
    'progress': progressId,
    'loc': loc,
    'seal': keyHex == null ? '' : srsKeyFingerprint(keyHex),
    'now': nowMs(),
    if (skip) 'skipUnchangedMs': kSrsSync2HeadHeartbeat.inMilliseconds,
  };
  SrsSync2Result head = await host.sync2Command(headRequest(skip: true));
  if (head.map['unchanged'] == true &&
      !await location.exists(head.map['path']! as String)) {
    head = await host.sync2Command(headRequest(skip: false));
  }
  String? written;
  int? writtenAtBootMs;
  for (final (String path, Uint8List bytes) in head.files) {
    final int? before = bootClockMs?.call();
    await location.put(path, bytes);
    if (before != null) {
      writtenAtBootMs = before + (bootClockMs!() - before) ~/ 2;
    }
    written = path.substring(path.lastIndexOf('/') + 1);
  }
  // 5. 收尾：head 已经在位置上，列本机目录（顺便取服务端时间）交给内核定该删什么（旧 head、不再被引用的段）。
  final List<SrsLocationEntry> own = await location.list('devices/$self');
  for (final SrsLocationEntry f in own) {
    if (f.name == written && f.modifiedAt != null) {
      report
        ..serverTimeMs = f.modifiedAt
        ..serverTimeBootMs = writtenAtBootMs;
    }
  }
  final Map<String, Object?> obsolete = (await host.sync2Command(
    <String, Object?>{
      'op': 'obsolete',
      'progress': progressId,
      'archive': archive,
      'present': <String>[
        for (final SrsLocationEntry f in own)
          if (!f.isFolder) f.name,
      ],
    },
  )).map;
  await srsRunPooled(
    _pathsOf(obsolete['delete']),
    kSrsSync2Concurrency,
    location.delete,
  );
  // 6. 本机旧身份目录里的旧 head；本机这一轮的媒体观察打成清单。
  await srsSync4SweepFormer(
    host: host,
    location: location,
    former: obsolete['former'],
    listed: listed,
    archive: archive,
    report: report,
  );
  await srsSync4MediaManifestsOut(
    host: host,
    location: location,
    locationId: locationId,
    loc: loc,
    self: self,
    listed: listed,
  );
  // 7. 转发（内核 `cmd/sync_relay.rs`）：本机收到过、这个位置缺的别的设备的段与 head。
  await srsSync4Relay(
    host: host,
    location: location,
    locationId: locationId,
    keyHex: keyHex,
    archive: archive,
    report: report,
    shouldStop: shouldStop,
  );
  return report;
}

/// 位置的根这一步（[srsSync4LocationRoot]）定下来的东西。
class SrsLocationRoot {
  const SrsLocationRoot({
    required this.keyHex,
    required this.loc,
    required this.media,
  });

  /// 这个位置这一轮用的密钥（明文位置为 null）。
  final String? keyHex;

  /// 本位置的 loc 标记（`plan` / `head` 带上）。
  final String loc;

  /// 媒体所在的根（[kSrsSync2Folder] 或 [kSrs4Root]，新根 meta 的 `media`）。
  final String media;
}

/// 位置的根（内核 `location_root`，G8-7）：新根 `v4/meta.json` 由内核按集合算出（只读不改，开加密是唯一的改写），
/// 旧根 `v3/meta.json` 读到了就改写成让旧版本停下的围栏（设计 §4.3）；没有 `v3/meta.json` = 新集合，预先立围栏与
/// 墓碑 head（规划 §4 补记：判据只看它在不在，所以这一步之前谁都不能往旧根写 `meta.json`）。加密握手
/// （[srsLocationHandshake]）照旧判口令 / 校验值 / 见过加密，但只看、不写：它想写的 `kdf` 交给内核写进新根 meta。
///
/// 结论写进 [report]（`kdf` / `encryptionEnabled` / `encrypted` / `mediaRoot`；没过时 `needsUpgrade` 或 `error`）；
/// 没过返回 null，什么都没写。一轮同步（[srsSync2Round]）与只做媒体的位置（srs_folder_location.dart）共用。
Future<SrsLocationRoot?> srsSync4LocationRoot({
  required SrsSync2Host host,
  required SrsLocationStore location,
  required SrsLocationStore? oldRoot,
  required String locationId,
  required int Function() nowMs,
  required Object? collection,
  required SrsSync2Report report,
  SrsLocationKey? key,
  SrsLocationStore? protocol1Root,
}) async {
  final Uint8List? meta4 = await location.get('meta.json');
  final Uint8List? meta3 = await oldRoot?.get('meta.json');
  // 只有协议 1 旧根 `v2/` 的位置：内核明确拒绝（D21），一个字节不写。新根、旧根都在时不用看它；`v2/` 上只有围栏
  // （协议 2 的迁移或下面立的）不算协议 1 的集合。
  final Uint8List? meta2 = meta4 == null && meta3 == null
      ? await protocol1Root?.get('meta.json')
      : null;
  final bool has2 = meta2 != null && srsDecodeV1Fence(meta2) == null;
  final List<String> locs = <String>[
    for (final SrsLocationEntry e in await location.list('loc'))
      if (!e.isFolder) e.name,
  ];
  // 新根 meta 读不到（最终一致的网盘暂时列不到 / 被删）而这个集合的新根已经立过：旧根是围栏（围栏只在新根 meta 写好
  // 之后才写），或新根下已有设备 / 媒体数据 / loc 标记。这时新根原来的 `media` / `kdf` 从别处推不出来（围栏不带
  // `media`），重建一份会把媒体根改错、把加密位置的 `kdf` 丢掉、在允许同名文件的后端上多出一份 meta：这一轮什么都不写
  // （与协议 3 的「已有数据却读不到 meta 就不重写」同一条闸）。新根下还列得到东西 → [kSrsSync2MetaUnavailable]（多半
  // 一时读不到）；只剩围栏 → [kSrsLocationNewRootMissing]（新根多半被整个删了，要用户处理）。围栏也不能当 meta 交给
  // 握手——那正是绕过这道闸的路。内核 `location_root` 按同一组证据再判一次。
  final bool v4Data =
      meta4 == null && (locs.isNotEmpty || await _srsV4HasData(location));
  if (meta4 == null && (srsIsOldRootFence(meta3) || v4Data)) {
    report.error = v4Data
        ? kSrsSync2MetaUnavailable
        : kSrsLocationNewRootMissing;
    return null;
  }
  final _SrsMetaView view = _SrsMetaView(location, meta4 ?? meta3);
  final SrsLocationHandshake hs = await srsLocationHandshake(
    view,
    host: host,
    locationId: locationId,
    key: key,
    collection: collection,
    nowMs: nowMs(),
    protocol: kSrsSync2Protocol,
    minReader: kSrsSync2MinReader,
  );
  report.kdf = hs.kdf;
  report.encryptionEnabled = hs.encryptionEnabled;
  if (hs.needsUpgrade) {
    report.needsUpgrade = true;
    return null;
  }
  if (hs.error != null) {
    report.error = hs.error;
    return null;
  }
  final String? keyHex = hs.keyHex;
  report.encrypted = keyHex != null;
  final SrsSync2Result root = await host.sync2Command(
    <String, Object?>{
      'op': 'location_root',
      'location': locationId,
      'now': nowMs(),
      'has4': meta4 != null,
      'has3': meta3 != null,
      'has2': has2,
      'v4Data': v4Data,
      'locs': locs,
      'enableKdf': view.writtenKdf,
    },
    blobs: <Uint8List>[?meta4, ?meta3],
  );
  final String state = root.map['state']! as String;
  if (state == kSrs4RootNeedsUpgrade) {
    report.needsUpgrade = true;
    return null;
  }
  if (state != kSrs4RootOk) {
    // 只有协议 1 旧根：错误就是机读码本身（[kSrsLocationProtocol1Root]），界面按它给专门的升级提示；其余带码的拒绝把
    // 码放在前面。
    final Object? code = root.map['code'];
    report.error =
        code == kSrsLocationProtocol1Root || code == kSrsLocationNewRootMissing
        ? code! as String
        : code == kSrs4MetaUnavailableCode
        ? kSrsSync2MetaUnavailable
        : code == null
        ? '$kSrs4LocationRefused: ${root.map['error']}'
        : '$kSrs4LocationRefused: $code: ${root.map['error']}';
    return null;
  }
  final Set<String> ensure = <String>{
    for (final Object? p in (root.map['ensure'] as List?) ?? const <Object?>[])
      p! as String,
  };
  // 先新根、后旧根（围栏让旧版本停下之前，新根必须已经立住）：内核给的顺序就是写入顺序。
  for (final (String path, Uint8List bytes) in root.files) {
    final bool isNew = path.startsWith('$kSrs4Root/');
    final SrsLocationStore? target = isNew ? location : oldRoot;
    if (target == null) continue;
    final String rel = path.substring(path.indexOf('/') + 1);
    if (ensure.contains(path) && await target.exists(rel)) continue;
    await target.put(rel, bytes);
  }
  // 协议 1 的版本只看 `v2/`：那里没有 `meta.json` 时它会另起一个集合、和新版本各同步各的。新根与旧根围栏立住之后
  // 在 `v2/` 立一份它解析不了的围栏，让它在握手就停下（字节固定，几台设备并发立的相同）。
  if (protocol1Root != null && !await protocol1Root.exists('meta.json')) {
    await protocol1Root.put(
      'meta.json',
      srsEncodeV1Fence(<String, Object?>{
        'v': kSrsSync2Protocol,
        'minReader': kSrsSync2MinReader,
        kSrsV1MovedToKey: kSrs4Root,
      }),
    );
  }
  final String media = (root.map['media'] as String?) ?? kSrs4Root;
  report.mediaRoot = media;
  return SrsLocationRoot(
    keyHex: keyHex,
    loc: root.map['loc']! as String,
    media: media,
  );
}

/// 内核 `location_root` 拒绝码：新根 meta 读不到而新根已经立过（旧根是围栏 / 新根下已有数据），不重写
/// （`gen4/cmd/sync.rs` `ERR_META_UNAVAILABLE`）。
const String kSrs4MetaUnavailableCode = 'srs_location_meta_unavailable';

/// [bytes]（旧根 `v3/meta.json`）是本版本立的围栏（`moved` = [kSrs4Root]，内核 `gen4/location.rs` `fence3`）。
/// 解析不了 / 不是 JSON 对象 / 没有 `moved` 的都不算（存量协议 3 的 meta 由内核核对）。
bool srsIsOldRootFence(Uint8List? bytes) {
  if (bytes == null) return false;
  try {
    final Object? j = jsonDecode(utf8.decode(bytes));
    return j is Map && j['moved'] == kSrs4Root;
  } on FormatException {
    return false;
  }
}

/// 新根 [location] 下已经有设备目录或加密媒体：有人在这个新根上同步过（与握手 [srsLocationHandshake] 判「已有数据」
/// 同一口径；明文媒体目录不算：内容寻址的明文对象可能先于 meta 落在位置上，它也不带 `kdf` / 媒体根的信息）。
Future<bool> _srsV4HasData(SrsLocationStore location) async =>
    (await location.list('devices')).isNotEmpty ||
    (await location.list(kSrsSealedMediaFolder)).isNotEmpty;

/// [srsLocationHandshake] 看到的位置：`meta.json` 是这一轮读到的那份（新根的，没有就是旧根的），写 `meta.json`
/// 不落盘、只记下要开的 `kdf`（新根 meta 只由内核 `location_root` 写）；别的路径照原位置读。
class _SrsMetaView implements SrsLocationStore {
  _SrsMetaView(this._inner, this._meta);

  final SrsLocationStore _inner;
  final Uint8List? _meta;

  /// 握手想写进 `meta.json` 的 `kdf`（开加密 / 新位置带口令）；null = 没有要写的。
  Map<String, Object?>? writtenKdf;

  @override
  Future<Uint8List?> get(String path) async =>
      path == 'meta.json' ? _meta : _inner.get(path);

  @override
  Future<void> put(String path, Uint8List bytes) async {
    if (path != 'meta.json') {
      throw StateError('handshake writes only meta.json, not $path');
    }
    final Object? kdf = (jsonDecode(utf8.decode(bytes)) as Map)['kdf'];
    if (kdf is Map) writtenKdf = kdf.cast<String, Object?>();
  }

  @override
  Future<void> putNew(String path, Uint8List bytes) => put(path, bytes);

  @override
  Future<bool> exists(String path) async =>
      path == 'meta.json' ? _meta != null : _inner.exists(path);

  @override
  Future<List<SrsLocationEntry>> list(String dir) => _inner.list(dir);

  @override
  Future<void> delete(String path) =>
      throw StateError('handshake never deletes ($path)');
}

/// 一轮的读半边：读 [location] 上全部设备的 head（每台取代号最大的）→ 内核定要拉
/// 的段 → 分批拉、分批收。结果累加进 [report]。返回 false = 这一轮到此为止：中途收手（[report] 的 error 是
/// [kSrsSync2Stopped]）或有设备的 head 要求更新的读者（[SrsSync2Report.needsUpgrade]，什么都没收）。[progressId] = null：
/// 不按位置记 head / 转发账。
/// [listed] 给了就记下读 head 时列到的每个设备目录（`devices/<id>` → 文件名）：一轮的作者自检用本机那一份，不再多列一次。
Future<bool> srsSync2Pull({
  required SrsSync2Host host,
  required SrsLocationStore location,
  required String? progressId,
  required String? keyHex,
  required SrsSync2Report report,
  required int Function() nowMs,
  void Function(int done, int total)? onFetchProgress,
  bool Function()? shouldStop,
  int ingestBudgetBytes = kSrsSync2IngestBudgetBytes,
  int fetchConcurrency = kSrsSync2Concurrency,
  SrsSyncStepCallback? onStep,
  Map<String, List<String>>? listed,
  String? loc,
}) async {
  // 1. 全部设备的 head：每台设备取代号最大的（同一代号的都要）。
  onStep?.call('heads');
  listed ??= <String, List<String>>{};
  final List<String> deviceDirs = <String>[
    for (final SrsLocationEntry d in await location.list('devices'))
      if (d.isFolder) 'devices/${d.name}',
  ];
  final List<(List<String>, String?)> headPaths = await srsRunPooled(
    deviceDirs,
    kSrsSync2Concurrency,
    (String dir) async {
      int top = -1;
      final Map<String, int> genOf = <String, int>{};
      int relayTop = -1;
      String? relayHead;
      final List<SrsLocationEntry> files = await location.list(dir);
      listed?[dir] = <String>[
        for (final SrsLocationEntry f in files)
          if (!f.isFolder) f.name,
      ];
      for (final SrsLocationEntry f in files) {
        final int? r = _relayHeadGen(f.name);
        if (r != null && r > relayTop) {
          relayTop = r;
          relayHead = '$dir/${f.name}';
        }
        final int? g = _headGen(f.name);
        if (g == null) continue;
        genOf[f.name] = g;
        if (g > top) top = g;
      }
      return (
        <String>[
          for (final MapEntry<String, int> e in genOf.entries)
            if (e.value == top) '$dir/${e.key}',
        ],
        relayHead,
      );
    },
  );
  final List<Uint8List> heads = <Uint8List>[
    for (final Uint8List? b in await srsRunPooled(
      <String>[for (final (List<String>, String?) p in headPaths) ...p.$1],
      kSrsSync2Concurrency,
      location.get,
    ))
      ?b,
  ];
  // 别的设备转发来的 head（`rhd-`，每台取代号最大的一份）：排在作者自写的之后，`relayed` 告诉内核有几份——内核拿它
  // 认作者公钥、定要拉的段（`seg-` 不在就拉 `rly-`），但不当这个位置的证据。
  final List<Uint8List> relayedHeads = <Uint8List>[
    for (final Uint8List? b in await srsRunPooled(
      <String>[
        for (final (List<String>, String?) p in headPaths)
          if (p.$2 != null) p.$2!,
      ],
      kSrsSync2Concurrency,
      location.get,
    ))
      ?b,
  ];

  // 2. 定要拉的段 → 拉 → 收。
  onStep?.call('plan heads=${heads.length}');
  // `location`：内核记下这个位置上有谁的哪些段（别的位置缺、本机可以转发的，见步骤 3 之后的转发）。
  // `location`：内核记下这个位置上每台设备的 head（状态页的「已传到」）；`listing`：各设备目录的文件名（承袭段按
  // 文件名定区间）；`loc`：本位置的 loc 标记（本位置自写的 head 带 `seal` = 位置是加密的）。
  final String planLocation = progressId == null
      ? kSrs4NoLocation
      : srsLocationOfProgressId(progressId);
  final Map<String, Object?> plan = (await host.sync2Command(
    <String, Object?>{
      'op': 'plan',
      'location': planLocation,
      'now': nowMs(),
      'loc': ?loc,
      'listing': <String, List<String>>{
        for (final MapEntry<String, List<String>> e in listed.entries)
          e.key.substring(e.key.indexOf('/') + 1): e.value,
      },
      'relayed': relayedHeads.length,
    },
    blobs: <Uint8List>[...heads, ...relayedHeads],
  )).map;
  report.errors.addAll(<String>[
    for (final Object? x in (plan['errors'] as List?) ?? const <Object?>[])
      '$x',
  ]);
  if (keyHex == null && plan['sealed'] == true && progressId != null) {
    // 本位置自写的 head 带 `seal`：位置是加密的（设计 §4.4）。记下，调用方据此不发件。
    await srsNoteLocationSealed(
      host,
      srsLocationOfProgressId(progressId),
      nowMs: nowMs(),
      seen: true,
    );
  }
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
        ((r['applied'] as int?) ?? 0) > 0 ||
        ((r['moved'] as int?) ?? 0) > 0;
    report.errors.addAll(<String>[
      for (final Object? x in (r['errors'] as List?) ?? const <Object?>[]) '$x',
    ]);
  }

  onStep?.call(
    'planned fetch=${wanted.length} finishPending=${plan['finishPending'] == true}',
  );
  // 按明文读一个同步位置时，读到的段交给内核看一眼段头（BUG-4299）：有对这个位置密封的段就记下「这里是加密的」，
  // 调用方（[srsSync2Round]）据此不发件。见到一次就不再看。
  final String? sealProbe = keyHex == null && progressId != null
      ? srsLocationOfProgressId(progressId)
      : null;
  bool sealSeen = false;
  if (wanted.isNotEmpty) {
    int done = 0;
    onFetchProgress?.call(0, wanted.length);
    await host.sync2IngestBegin();
    // 会话的寿命限在这一段里：收手 / 出错退出时也放掉（[SrsSync2Host.sync2IngestEnd]）。
    try {
      await for (final SrsFetchedBatch batch in srsFetchInBatches(
        wanted,
        fetch: (String path) => srsFetchSegment(location, path),
        budgetBytes: ingestBudgetBytes,
        concurrency: fetchConcurrency,
      )) {
        // head 指向的段暂时还列不到（最终一致）的不在 batch.segments 里：这一轮跳过，下一轮再来。
        report.missing += batch.covered - batch.segments.length;
        if (sealProbe != null && !sealSeen && batch.segments.isNotEmpty) {
          sealSeen = (await srsNoteLocationSealed(
            host,
            sealProbe,
            nowMs: nowMs(),
            segmentPrefixes: batch.segments,
          )).sealed;
        }
        if (batch.segments.isNotEmpty) {
          absorb(
            await host.sync2IngestBatch(
              batch.segments,
              keyHex: keyHex,
              location: planLocation,
            ),
          );
        }
        done += batch.covered;
        onFetchProgress?.call(done, wanted.length);
        onStep?.call('ingest $done/${wanted.length}');
        if (shouldStop?.call() ?? false) {
          report.error = kSrsSync2Stopped;
          return false;
        }
      }
      onStep?.call('ingestFinish');
      absorb(await host.sync2IngestFinish());
    } finally {
      await host.sync2IngestEnd();
    }
  } else if (plan['finishPending'] == true) {
    // 上一轮收段被打断在收尾之前：受影响的卡还在内核的待重放集合里（审查 S-4），这一轮没段可拉也收个尾。
    onStep?.call('finishPending');
    await host.sync2IngestBegin();
    try {
      absorb(await host.sync2IngestFinish());
    } finally {
      await host.sync2IngestEnd();
    }
  }
  return true;
}

List<String> _pathsOf(Object? list) => <String>[
  for (final Object? p in (list as List?) ?? const <Object?>[]) p! as String,
];

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

/// [srsFetchInBatches] 的一批。
class SrsFetchedBatch {
  const SrsFetchedBatch(this.segments, {required this.covered});

  /// 这一批读到的内容，按路径原顺序；不存在的路径不在里面。
  final List<Uint8List> segments;

  /// 这一批走过的路径数（含不存在的）。
  final int covered;
}

/// 按原顺序读 [paths]，同时最多 [concurrency] 个在途，按实际读到的字节切批：一批累计到 [budgetBytes] 就不再开
/// 新的读、等在途的读完后交出这一批（在途的读完之前不知道多大，所以一批最多超出预算 [concurrency] 个文件）。
/// 交出一批的同时开始读下一批，消费方收这一批（内核在 worker isolate 上投影）与下载重叠；只预读一批，同一时刻
/// 内存里最多两批。每批至少一个路径，所以单个超过预算的文件自成一批；[paths] 为空时也交出一个空批。
/// 任一读失败：不再开新的，等在途的跑完后在交到那一批时抛出第一个错误（与 [srsRunPooled] 一致；之前的批照常
/// 交出）。消费方中途停止监听，预读的那一批读完后就不再读，且取消要等这批在途的读收完才返回（不留游离的下载）。
Stream<SrsFetchedBatch> srsFetchInBatches(
  List<String> paths, {
  required Future<Uint8List?> Function(String path) fetch,
  required int budgetBytes,
  int concurrency = kSrsSync2Concurrency,
}) async* {
  assert(budgetBytes > 0 && concurrency > 0);
  int next = 0;
  bool stopped = false;

  // 读一批。错误放进结果而不是让 Future 失败：预读的那一批可能在消费方停止监听后才失败，没人等它。
  Future<_FetchRead> read() async {
    final int start = next;
    final Map<int, Uint8List> got = <int, Uint8List>{};
    int bytes = 0;
    Object? error;
    StackTrace? stack;
    Future<void> worker() async {
      while (!stopped &&
          error == null &&
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
    return _FetchRead(
      SrsFetchedBatch(<Uint8List>[
        for (int i = start; i < next; i++) ?got[i],
      ], covered: next - start),
      error,
      stack,
    );
  }

  Future<_FetchRead>? ahead = read();
  try {
    while (ahead != null) {
      final _FetchRead r = await ahead;
      final Object? failure = r.error;
      if (failure != null) Error.throwWithStackTrace(failure, r.stack!);
      ahead = next < paths.length ? read() : null;
      yield r.batch;
    }
  } finally {
    // 消费方停止监听 / 收段抛错：不再开新的读，并等在途的读（至多 [concurrency] 个）收完再结束——生成器拥有
    // 它启动的读，取消（await for 的 break / return / 抛错）返回时这一轮没有游离在外的下载。预读那一批的
    // 错误已装在 _FetchRead 里，这里不会抛。
    stopped = true;
    final Future<_FetchRead>? inFlight = ahead;
    if (inFlight != null) await inFlight;
  }
}

/// [srsFetchInBatches] 读完的一批，或它的第一个错误。
class _FetchRead {
  const _FetchRead(this.batch, this.error, this.stack);

  final SrsFetchedBatch batch;
  final Object? error;
  final StackTrace? stack;
}

/// `rhd-<gen>-<tag>.json`（被转发的 head，内核 `gen4/location.rs` `relay_head_name`）的代号；不是返回 null。
int? _relayHeadGen(String name) {
  if (!name.startsWith('rhd-') || !name.endsWith('.json')) return null;
  final List<String> parts = name.substring(4, name.length - 5).split('-');
  return parts.length == 2 ? int.tryParse(parts[0]) : null;
}

/// `head-<gen>-<tag>.json` 的代号；不是 head 返回 null。
int? _headGen(String name) {
  if (!name.startsWith('head-') || !name.endsWith('.json')) return null;
  final String rest = name.substring(5, name.length - 5);
  final int dash = rest.indexOf('-');
  return int.tryParse(dash < 0 ? rest : rest.substring(0, dash));
}
