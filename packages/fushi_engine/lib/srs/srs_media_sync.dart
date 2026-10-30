/// SRS 媒体同步（docs/specs/2026-10-25-srs-sync-v2-design.md §6.4、§6.5、§10.5）。
///
/// 媒体内容寻址、不可变、只增：位置上按内容存 `media/<sha256 前 2 位>/<sha256>`，本机文件名经日志里的绑定
/// （内核 `Body::Media`，store/sync2/media.rs）映射到内容（审查 S-3：以前按名字存 `media/<名字>`、下载不校验，
/// 同名不同内容的文件在两台设备上各留各的，云盘覆盖写的半截文件被当成本机文件）。每轮（发段之前先传一遍、
/// 操作同步之后再完整对账一遍）：
/// 1. 收集本 profile 全部存活笔记（含删除未满保留期的）与笔记类型引用的媒体文件名；
/// 2. 本机有的按内容传上去；本机缺的、或绑定换了内容的，下载并校验 sha256；
/// 3. 只被「删除已满 [kSrsMediaRetention]」的笔记引用、且不被任何存活引用绑定的内容 → 删（要正面证据：
///    本机不认识的文件不删）。别的设备若还看不到那次删除，会把它再传上来，不丢。**归档位置永不删**。
///
/// 位置上只有内容目录这一种布局（协议 2）。协议 1 的按名字存的 `media/<名字>`、整份封装的加密媒体与更老的写入者目录
/// 只在一次性迁移里读（sync2/srs_location_migration.dart：按内容重写进内容目录、补绑定、删旧文件），这里不再兜底。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show Digest, sha256;
import 'package:fushi_engine/srs/apkg/srs_apkg_common.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/sync2/srs_location_crypto.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;

/// 集合根下的媒体目录。
const String kSrsMediaFolder = 'media';

/// 被删笔记的媒体在同步 / 媒体位置上的保留期（设计 §10.5；本机媒体回收同一口径，见 srs_purge.dart）。
const Duration kSrsMediaRetention = Duration(days: 90);

/// 一轮媒体同步的结果。
class SrsMediaSyncReport {
  int uploaded = 0;
  int downloaded = 0;

  /// 从位置上删掉的过期 / 无引用文件数。
  int deleted = 0;

  /// 引用了但位置与本机都没有的文件（等持有它的设备上线）。
  final Set<String> missing = <String>{};

  /// 下载到的内容与绑定的 sha256 对不上（截断 / 被改 / 解不开）而没有落地的名字。位置上那份不删，只在日志里记
  /// 可疑，由持有原文的设备覆盖重传（[repaired]）。
  final Set<String> rejected = <String>{};

  /// 本机持有原文、把位置上被记为可疑的内容对象覆盖重传的份数。
  int repaired = 0;

  /// 加密位置上用这把密钥解不开（第一块就认证不过，密钥证明不了是对的）而没有落地的名字（也在 [rejected] 里）。
  /// 这些**不记可疑**：持有者覆盖重传修不好密钥的问题，记了只会让读者每轮记、持有者每轮覆盖。调用方按口令不对
  /// 提示（`kSrsSync2WrongKey`，srs_sync_scheduler.dart）。
  final Set<String> undecryptable = <String>{};

  /// 这一轮列了位置上的整个媒体目录（没有日志投影可用：本地文件夹位置，或这个位置第一次对账）。
  bool listedRemote = false;

  /// 整轮跑完（没有中途抛错）。
  bool completed = false;
}

/// 本 profile 全部未删除笔记（含模板正文里下划线开头的静态文件）引用的媒体文件名。
///
/// 笔记字段的引用读笔记缓存的 `media_refs` 列（[SrsDbStore.noteMediaRefs]）：它随笔记缓存同一次刷新算出，
/// 每轮媒体同步不逐页读全部修改记录解析字段。[deletedAfterMs] 给出时，删除晚于它的已删笔记也算。
Future<Set<String>> srsReferencedMedia(
  SrsDbStore store, {
  int? deletedAfterMs,
}) async {
  final Set<String> out = await store.noteMediaRefs(
    deletedAfterMs: deletedAfterMs,
  );
  for (final SrsNoteTypeView t in await store.noteTypes()) {
    for (final SrsTemplateDef tpl in t.templates) {
      out.addAll(srsMediaRefsIn(tpl.front, includeStatic: true));
      out.addAll(srsMediaRefsIn(tpl.back, includeStatic: true));
    }
    out.addAll(srsMediaRefsIn(t.css, includeStatic: true));
  }
  return out.where(srsIsBareMediaName).toSet();
}

/// 媒体回收 / 位置清理用的「存活引用」：存活笔记、删除未满 [retention] 的笔记、全部笔记类型（含已删除的）的
/// 模板与 CSS。比 [srsReferencedMedia] 多算已删除的笔记类型（可能被恢复）。
Future<Set<String>> srsLiveMediaReferences(
  SrsDbStore store, {
  Duration retention = kSrsMediaRetention,
}) async {
  final int cutoff = store.now().$1 - retention.inMilliseconds;
  final Set<String> out = await store.noteMediaRefs(deletedAfterMs: cutoff);
  final Map<String, SrsNoteTypeView?> types = await store.noteTypesById(
    await store.entityIds(SrsEntityKind.noteType),
  );
  for (final SrsNoteTypeView? t in types.values) {
    if (t == null) continue;
    for (final SrsTemplateDef tpl in t.templates) {
      out.addAll(srsMediaRefsIn(tpl.front, includeStatic: true));
      out.addAll(srsMediaRefsIn(tpl.back, includeStatic: true));
    }
    out.addAll(srsMediaRefsIn(t.css, includeStatic: true));
  }
  return out.where(srsIsBareMediaName).toSet();
}

/// 只认裸文件名（不含路径分隔、不是 `.` / `..`）：媒体目录外的路径一律不碰。
bool srsIsBareMediaName(String n) =>
    n.isNotEmpty &&
    !n.contains('/') &&
    !n.contains(r'\') &&
    n != '.' &&
    n != '..';

/// 位置上媒体目录的内容记进日志时用的位置身份（内核 `MediaAt.location`，store/sync2/media.rs）：位置的稳定身份 +
/// 媒体目录（加密媒体按密钥指纹分目录，换了密钥就是另一份内容）。
String srsMediaPresenceKey(String locationId, String folder) =>
    '$locationId/$folder';

/// 位置上一份内容的路径：`<媒体目录>/<sha256 前 2 位>/<sha256>`（设计 §6.1，内容寻址、不可变）。
String srsMediaContentPath(String folder, String sha) =>
    '$folder/${sha.substring(0, 2)}/$sha';

/// 不记日志的位置（本地文件夹，[_Presence.key] 为 null）上「内容 [sha] 可疑」的标记文件：与内容对象同目录、
/// 名字加后缀，每轮列目录时一起看到。读者只写它（从不删内容对象），持有原文的设备覆盖重传后删掉它。
String srsMediaSuspectMarkerPath(String folder, String sha) =>
    '${srsMediaContentPath(folder, sha)}$kSrsMediaSuspectSuffix';

/// [srsMediaSuspectMarkerPath] 的后缀。
const String kSrsMediaSuspectSuffix = '.suspect';

/// 位置上内容寻址目录的「有什么」记进日志用的位置身份（名字是 sha256）。
String srsMediaContentPresenceKey(String locationId, String folder) =>
    '${srsMediaPresenceKey(locationId, folder)}#sha256';

/// 一段字节的 sha256（小写十六进制）。
String srsMediaSha256(List<int> bytes) => sha256.convert(bytes).toString();

/// 文件内容的 sha256（流式读，不整份进内存）。
Future<String> srsMediaSha256File(File f) async =>
    (await sha256.bind(f.openRead()).first).toString();

/// 把 [src] 流式拷到 [dst]，同一遍读顺带算 sha256（[dst] 就是被核对的那份快照）。
Future<String> _copyHashing(File src, File dst) async {
  final _DigestCapture captured = _DigestCapture();
  final ByteConversionSink hash = sha256.startChunkedConversion(captured);
  final IOSink out = dst.openWrite();
  try {
    await for (final List<int> chunk in src.openRead()) {
      hash.add(chunk);
      out.add(chunk);
    }
    await out.flush();
  } finally {
    await out.close();
  }
  hash.close();
  return captured.value!.toString();
}

class _DigestCapture implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// 远端某个名字的已知状态。[suspect] = 在，但有设备下载到的内容与名字（内容哈希）对不上（内核
/// `MEDIA_AT_SUSPECT`）：读者照样可以再试（上次可能只是传输被截断），持有原文的设备覆盖重传修复。
enum _Remote { present, suspect, absent, unknown }

/// 一个位置目录里「有什么」：日志投影（[locationKey] 给出时）+ 本轮确认的事实，最后写回日志。
class _Presence {
  _Presence(this.key);

  /// 日志里的位置身份；null = 不记日志（本地文件夹位置，每轮列目录）。
  final String? key;
  final Set<String> present = <String>{};
  final Set<String> knownAbsent = <String>{};
  final Set<String> suspect = <String>{};
  bool listed = false;
  final Set<String> confirmedPresent = <String>{};
  final Set<String> confirmedAbsent = <String>{};
  final Set<String> confirmedSuspect = <String>{};

  _Remote stateOf(String name) {
    if (present.contains(name)) return _Remote.present;
    if (suspect.contains(name)) return _Remote.suspect;
    if (listed || knownAbsent.contains(name)) return _Remote.absent;
    return _Remote.unknown;
  }

  void markPresent(String name) {
    present.add(name);
    suspect.remove(name);
    confirmedPresent.add(name);
    confirmedAbsent.remove(name);
    confirmedSuspect.remove(name);
  }

  void markAbsent(String name) {
    present.remove(name);
    suspect.remove(name);
    confirmedPresent.remove(name);
    confirmedAbsent.add(name);
    confirmedSuspect.remove(name);
  }

  /// 位置上 [name] 这份对象在、但内容对不上：记可疑（不删、不当成在）。
  void markSuspect(String name) {
    present.remove(name);
    suspect.add(name);
    confirmedPresent.remove(name);
    confirmedAbsent.remove(name);
    confirmedSuspect.add(name);
  }

  /// 读日志投影。[seed] = 日志里没人完整列举过时由本轮列。
  Future<bool> load(SrsDbStore store, {required bool seed}) async {
    final String? k = key;
    if (k == null) return listed = seed;
    final Map<String, Object?> known = (await store.sync2Command(
      <String, Object?>{'op': 'media_known', 'location': k},
    )).map;
    present.addAll((known['present']! as List<Object?>).cast<String>());
    knownAbsent.addAll((known['absent']! as List<Object?>).cast<String>());
    suspect.addAll((known['suspect']! as List<Object?>).cast<String>());
    return listed = seed && known['seeded'] != true;
  }

  Future<void> record(SrsDbStore store, {required bool seeded}) async {
    final String? k = key;
    if (k == null) return;
    if (confirmedPresent.isEmpty &&
        confirmedAbsent.isEmpty &&
        confirmedSuspect.isEmpty &&
        !seeded) {
      return;
    }
    await store.sync2Command(<String, Object?>{
      'op': 'media_record',
      'location': k,
      'present': confirmedPresent.toList(),
      'absent': confirmedAbsent.toList(),
      'suspect': confirmedSuspect.toList(),
      'seeded': seeded,
      'now': store.now().$1,
    });
  }
}

/// 内核对一个媒体名字的结论（`media_scan`，store/sync2/media.rs）。
class _MediaItem {
  _MediaItem(Map<String, Object?> m)
    : name = m['name']! as String,
      sha = m['sha'] as String?,
      have = m['have'] == true,
      local = m['local'] as String?;

  final String name;

  /// 这个名字该是的内容（日志里的绑定）；null = 没有绑定、本机也没有（拿不到）。
  final String? sha;

  /// 本机文件已经是 [sha]。
  final bool have;

  /// 本机文件现在的内容（没有文件为 null）。
  final String? local;
}

/// 跑一轮媒体同步。[mediaRoot] 是本 profile 的本机媒体目录；[archive] = 归档位置（只写不删）；[cipher] = 位置开了
/// 加密时的媒体封装（文件放 `media-e/`、内容是密文，见 srs_location_crypto.dart）。
///
/// 位置上的媒体内容寻址（审查 S-3）：`<媒体目录>/<sha256 前 2 位>/<sha256>`，不可变、只增、只写一次
/// （[SrsLocationStore.putNew]，从不覆盖）；本机文件名经日志里的绑定（内核 `Body::Media`）映射到内容：
/// - 本机有文件 → 内核算出（或从缓存取）它的 sha256，没绑定 / 本机改过就绑上（`media_scan`），位置上没有那份内容就传；
/// - 本机没有，或绑定指向别的内容（别的设备后来改了它）→ 下载绑定的内容，**校验 sha256**，对不上一律不落地，
///   也**不删**位置上那份（读者看到的「坏」可能只是传输被截断，而那份也许是位置上唯一的一份）：只在日志里记
///   「可疑」；本机哈希对得上的持有者看到「可疑」就用核对过的原文覆盖重传修复（集成审查【中】）；
/// - 没有绑定、本机也没有 → 记缺失，等绑定随段到达。
///
/// [uploadOnly] = 只把本机有的内容传上去（不下载、不清理）：发段之前先跑这一步，媒体先于引用它的段到位置上
/// （设计 §6.1 写入纪律 3，审查 S-10）。
///
/// [locationId]（位置的稳定身份，各设备相同）给出时，位置上有什么读日志投影（内核 `media_known`），不列目录：
/// - 日志里还没有任何设备对这个位置的内容目录完整列举过 → 列一次（256 个前缀子目录），结果带「已列举」写进日志；
/// - 之后只对投影里不认识的内容逐个查，确认结果同样写回日志；读取时发现投影说在、实际不在 → 记「不在」，持有它的
///   设备下一轮就会补传。
/// 不给（本地文件夹位置，列目录只是本机文件系统调用）时照旧每轮列目录、不记日志。
Future<SrsMediaSyncReport> srsSyncMedia({
  required SrsLocationStore location,
  required SrsDbStore store,
  required Directory mediaRoot,
  bool archive = false,
  SrsMediaCipher? cipher,
  String? locationId,
  bool uploadOnly = false,
}) async {
  final SrsMediaSyncReport report = SrsMediaSyncReport();
  // 加密媒体按密钥指纹分目录（换了密钥 = 新目录，全部按新密钥重传）。
  final String folder = cipher == null ? kSrsMediaFolder : cipher.folder;
  // 内容按 sha256 寻址（加密时 AAD 也是 sha256：密文换了位置 / 名字解不开）。读写一律文件到文件、流式（审查 S-9：
  // 大媒体不整份进内存）。
  final Random rand = Random();
  File scratch(String tag) => File(
    p.join(
      Directory.systemTemp.path,
      'fushi_srs_media_${tag}_${DateTime.now().microsecondsSinceEpoch}_'
      '${rand.nextInt(1 << 30)}',
    ),
  );
  Future<void> drop(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } on FileSystemException {
      // 临时文件留给系统清理。
    }
  }

  final List<String> names = (await srsReferencedMedia(
    store,
    deletedAfterMs: store.now().$1 - kSrsMediaRetention.inMilliseconds,
  )).toList()..sort();

  // 1. 本机文件 → 内容（不进写锁：首次对账要把每个文件读一遍）→ 该做什么（写锁里，顺带写绑定）。
  final Map<String, Object?> hashed = (await store.sync2Command(
    <String, Object?>{
      'op': 'media_hash',
      'root': mediaRoot.path,
      'names': names,
    },
  )).map;
  final Map<String, Object?> scanned =
      (await store.sync2Command(<String, Object?>{
        'op': 'media_scan',
        'names': names,
        'files': hashed['files'],
        'now': store.now().$1,
      })).map;
  final List<_MediaItem> items = <_MediaItem>[
    for (final Object? m in scanned['items']! as List<Object?>)
      _MediaItem((m! as Map<Object?, Object?>).cast<String, Object?>()),
  ];

  // 2. 位置上有什么：日志投影，没人列过就列一次。
  final _Presence content = _Presence(
    locationId == null ? null : srsMediaContentPresenceKey(locationId, folder),
  );
  final List<String> markers = <String>[];
  if (await content.load(store, seed: true)) {
    report.listedRemote = true;
    for (final SrsLocationEntry d in await location.list(folder)) {
      if (!d.isFolder || d.name.length != 2) continue;
      for (final SrsLocationEntry f in await location.list(
        '$folder/${d.name}',
      )) {
        if (!f.isFolder && f.name.length == 64) {
          content.present.add(f.name);
          if (content.key != null) content.confirmedPresent.add(f.name);
        } else if (!f.isFolder &&
            content.key == null &&
            f.name.length == 64 + kSrsMediaSuspectSuffix.length &&
            f.name.endsWith(kSrsMediaSuspectSuffix)) {
          markers.add(f.name.substring(0, 64));
        }
      }
    }
    // 不记日志的位置：可疑标记旁边那份对象若还在，就是「在但可疑」（对象已不在的标记是孤儿，当不在处理）。
    for (final String sha in markers) {
      if (content.present.contains(sha)) content.markSuspect(sha);
    }
  }

  final List<(String, String)> landed = <(String, String)>[];

  /// 把 [src] 作为内容 [sha] 传进内容目录；[src] 此刻的内容不是 [sha]（对账中途被改了）就不传、返回 false，留给
  /// 下一轮。传的是核对过的那份：加密时内核封装的同一遍读顺带算出明文哈希；不加密时先流式拷一份快照再传快照。
  /// 位置上那份被记为可疑（[_Remote.suspect]）时覆盖写：这是唯一会覆盖内容寻址对象的地方，且只由本机哈希对得上
  /// 的持有者发起；其余一律 [SrsLocationStore.putNew]（已在就不写）。
  Future<bool> putContent(File src, String sha) async {
    final File staged = scratch('up');
    try {
      final String got = cipher == null
          ? await _copyHashing(src, staged)
          : await cipher.sealFile(sha, src, staged);
      if (got != sha) return false;
      final String path = srsMediaContentPath(folder, sha);
      if (content.stateOf(sha) == _Remote.suspect) {
        // 覆盖写也从文件流式传（大媒体不整份进内存）。
        await srsLocationPutFile(location, path, staged);
        if (content.key == null) {
          await location.delete(srsMediaSuspectMarkerPath(folder, sha));
        }
        report.repaired++;
      } else {
        await srsLocationPutNewFile(location, path, staged);
      }
      content.markPresent(sha);
      report.uploaded++;
      return true;
    } finally {
      await drop(staged);
    }
  }

  /// 把本机 [name]（内容应为 [sha]）传进内容目录。
  Future<bool> upload(String name, String sha) =>
      putContent(File(p.join(mediaRoot.path, name)), sha);

  /// 确保内容 [sha] 在位置上（本机有、内容就是它）。
  Future<void> ensureUploaded(String name, String sha) async {
    final _Remote state = content.stateOf(sha);
    if (state == _Remote.present) return;
    if (state == _Remote.unknown &&
        await location.exists(srsMediaContentPath(folder, sha))) {
      content.markPresent(sha);
      return;
    }
    await upload(name, sha);
  }

  /// 把内容 [sha] 记为可疑（位置上那份对不上）：不记日志的位置另在旁边写标记文件（只写一次），持有者下一轮列目录
  /// 时看到。
  Future<void> markSuspectContent(String sha) async {
    if (content.key == null && content.stateOf(sha) != _Remote.suspect) {
      await location.put(srsMediaSuspectMarkerPath(folder, sha), Uint8List(0));
    }
    content.markSuspect(sha);
  }

  /// 从内容目录拿内容 [sha] 落到 [dst]。落地的明文一律按 sha256 校验，返回它的 sha256；拿不到 / 对不上返回 null，
  /// 且不留 [dst]。
  Future<String?> fetchTo(String name, String sha, File dst) async {
    if (content.stateOf(sha) != _Remote.absent) {
      final String path = srsMediaContentPath(folder, sha);
      final File stored = cipher == null ? dst : scratch('down');
      try {
        if (!await srsLocationGetFile(location, path, stored)) {
          content.markAbsent(sha);
        } else {
          final SrsMediaOpened opened = cipher == null
              ? (sha256: await srsMediaSha256File(dst), failure: null)
              : await cipher.openFile(sha, stored, dst);
          if (opened.sha256 == sha) {
            content.markPresent(sha);
            return sha;
          }
          await drop(dst);
          report.rejected.add(name);
          final SrsMediaOpenFailure? failure = opened.failure;
          if (failure == SrsMediaOpenFailure.unauthenticated) {
            // 密钥证明不了是对的（口令 / 密钥的问题，或第一块就坏了，AEAD 分不出）：不怪对象、不记可疑——覆盖重传
            // 修不好密钥，记了就是读者每轮记、持有者每轮覆盖。调用方按口令不对提示。
            report.undecryptable.add(name);
          } else if (failure == SrsMediaOpenFailure.local) {
            // 本机读写出错：这一轮没拿到，下一轮再试；对象没有可疑之处。
          } else {
            // 内容哈希对不上 / 密钥对而对象坏了（截断的响应 / 网盘占位或同步中的半截文件 / 被改）：不落地，也不删——
            // 读者分不清是位置上那份真坏了还是这次传输坏了，删了可能就删掉了唯一的一份。只记可疑，持有原文件（本机
            // 哈希对得上）的设备看到后覆盖重传（[putContent]）；下一轮读者仍会再试。
            await markSuspectContent(sha);
          }
        }
      } finally {
        if (cipher != null) await drop(stored);
      }
    }
    return null;
  }

  Future<void> syncOne(_MediaItem item) async {
    final String name = item.name;
    final String? sha = item.sha;
    if (item.have) {
      await ensureUploaded(name, sha!);
      return;
    }
    if (uploadOnly) return;
    // 本机文件要被换成别的内容：它若还不在位置上，先传上去——那份内容此刻可能只有这台设备有。
    final String? local = item.local;
    if (local != null) await ensureUploaded(name, local);
    if (sha == null) {
      // 没有绑定、本机也没有：等绑定随段到达。
      report.missing.add(name);
      return;
    }
    final File file = File(p.join(mediaRoot.path, name));
    await mediaRoot.create(recursive: true);
    final File tmp = File('${file.path}.download');
    final String? got = await fetchTo(name, sha, tmp);
    if (got == null) {
      await drop(tmp);
      report.missing.add(name);
      return;
    }
    await tmp.rename(file.path);
    landed.add((name, got));
    report.downloaded++;
  }

  // 本机已是目标内容、位置上也确认在的（绝大多数）什么都不用做：同步地一次筛掉，只把要真做 IO 的交给并发池
  // （上万个名字逐个走异步流程会在一长串微任务里跑完、整段不回事件循环，同步收尾时 UI 卡顿）。
  final List<_MediaItem> work = <_MediaItem>[
    for (final _MediaItem it in items)
      if (!it.have || content.stateOf(it.sha!) != _Remote.present)
        if (it.have || !uploadOnly) it,
  ];

  try {
    await _reconcile(
      report: report,
      store: store,
      location: location,
      folder: folder,
      work: work,
      content: content,
      prune: !archive && !uploadOnly,
      syncOne: syncOne,
    );
  } finally {
    if (landed.isNotEmpty) {
      await store.sync2Command(<String, Object?>{
        'op': 'media_landed',
        'root': mediaRoot.path,
        'items': <Map<String, String>>[
          for (final (String name, String sha) in landed)
            <String, String>{'name': name, 'sha': sha},
        ],
        'now': store.now().$1,
      });
    }
    // 中途失败也把已经确认的事实记下（下一轮不必再查一遍）；列举标记只在整轮跑完时写。
    await content.record(store, seeded: content.listed && report.completed);
  }
  return report;
}

Future<void> _reconcile({
  required SrsMediaSyncReport report,
  required SrsDbStore store,
  required SrsLocationStore location,
  required String folder,
  required List<_MediaItem> work,
  required _Presence content,
  required bool prune,
  required Future<void> Function(_MediaItem item) syncOne,
}) async {
  // 媒体彼此无先后：同时最多 [kSrsSync2Concurrency] 个在途（首次同步一个牌组上千个图片 / 音频时，逐个等每个请求
  // 的固定延迟是主要耗时）。只差大小写的名字在不分大小写的文件系统上是同一个本机文件，归成一组在同一个任务里
  // 依次处理。
  final Map<String, List<_MediaItem>> byFolded = <String, List<_MediaItem>>{};
  for (final _MediaItem it in work) {
    byFolded.putIfAbsent(it.name.toLowerCase(), () => <_MediaItem>[]).add(it);
  }
  await srsRunPooled(byFolded.values.toList(), kSrsSync2Concurrency, (
    List<_MediaItem> group,
  ) async {
    for (final _MediaItem it in group) {
      await syncOne(it);
    }
  });
  if (prune) {
    // 只删有正面证据的：被「删除已满保留期」的笔记引用、且不被任何存活引用。本机不认识的文件一律不删——
    // 它可能是别的设备新笔记的媒体，而本机还没收到那条笔记。
    final List<String> live = (await srsLiveMediaReferences(store)).toList();
    final Set<String> liveFolded = <String>{
      for (final String n in live) n.toLowerCase(),
    };
    final List<String> expired = <String>[
      for (final String n in await store.expiredNoteMediaRefs(
        store.now().$1 - kSrsMediaRetention.inMilliseconds,
      ))
        if (!liveFolded.contains(n.toLowerCase())) n,
    ];
    if (expired.isNotEmpty) {
      // 内容：只删过期名字绑定、且不被任何存活名字绑定的那几份（内核按绑定算，`media_doomed`）。
      final List<String> doomed = <String>[
        for (final Object? s
            in (await store.sync2Command(<String, Object?>{
                  'op': 'media_doomed',
                  'expired': expired,
                  'live': live,
                })).map['sha']!
                as List<Object?>)
          if (content.present.contains(s) || content.suspect.contains(s))
            s! as String,
      ];
      await srsRunPooled(doomed, kSrsSync2Concurrency, (String sha) async {
        if (content.key == null && content.suspect.contains(sha)) {
          await location.delete(srsMediaSuspectMarkerPath(folder, sha));
        }
        await location.delete(srsMediaContentPath(folder, sha));
        content.markAbsent(sha);
        report.deleted++;
      });
    }
  }
  report.completed = true;
}
