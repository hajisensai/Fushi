/// 复习库墓碑的物理清除（删牌组 / 删笔记之后磁盘要能释放）。
///
/// 删除在事件日志里只是一条「删除寄存器」修改记录（墓碑）：笔记正文、缓存行、媒体文件都还在。
/// 这里在墓碑过了**同步安全期**之后把它们物理删掉，只留墓碑本身与卡片的复习日志。
///
/// ## 为什么清除不会让实体复活、也不会让合并出错
///
/// 事件按 ID 取并集（event_store.dart），删除寄存器是「删除优先」的多值寄存器
/// （field_edit.dart `srsEffectiveDeletedAt`：只要有一条没被支配的删除记录，行就是已删）。
/// - **墓碑留着**：本机清除后，对端（或快照 / 备份）再把同一笔记的身份记录、内容修改记录、复习日志
///   送来时，它们照常落库（并集），但删除寄存器还在 → 笔记仍是已删除、不可见；下一次维护
///   （[srsPurgeExpiredTombstones]，候选见 `SrsDbStore.purgeCandidateNoteIds`）把它们再清掉。
///   晚到的内容修改与删除并发时，笔记进「待裁决」、不清除，交给用户决定——与清除前的语义一致。
/// - **并发的恢复赢不了**：没看见删除就写的「恢复」（deleted=null）不支配删除记录，删除照样生效。
///   只有看见了删除之后的恢复（支配删除）才会让笔记回来；这样的恢复只能在对端自己清除之前做，
///   而所有设备按**同一个**服务器时间 S（同步时取全网最小值）+ 同一个安全期判定，清除时刻一致。
///   剩下的窗口是「对端在安全期快到时恢复、却在本机清除之后才同步上来」：本机收到恢复，删除寄存器
///   变回未删，但身份记录 / 正文已清，笔记在本机仍不出现（不报错、不产生坏行）；正文还在那台对端上，
///   本机下次读它的快照（新目录起步、超过退役时限后重新起步）时并集回来。
/// - **安全期取 90 天 = [SrsSyncOptions.retireAfterMs]**：同步层已经约定一台设备 90 天没来就当退役，
///   它回来时整套重新起步（读全部快照）；未退役的活跃设备至少每 90 天交一次 cursor，安全期内必然
///   已经读到删除记录并按同一规则自己清除。
/// - **只认已发布的删除**：同步过的副本，删除记录的 S 未知（还没发布出去）就不清——对端还不知道删除。
///   从没同步过的副本（`SrsDbStore.neverSynced`）没有对端，按删除时刻（删除记录的值）算；
///   用户确认后可以当场清（[srsPurgeNotesNow]）。
///
/// ## 不破坏的东西
///
/// - 已冻结 / 已上传的批次与快照不改（批次冻结后逐字节不变）；本机之后写的快照不再含被清的事件，
///   旧批次照常按快照覆盖规则在同步目录里清理，云端空间随之释放。
/// - 备份文件不改：恢复到某个更早的时间点（srs_point_in_time_restore.dart）先把备份里的事件并进来，
///   被清的笔记连同正文一起回来，再按备份时的删除寄存器写恢复 / 删除；所以「清除之后能回到的过去」
///   = 还保留着的备份。备份之后才删、已被清除的笔记，只有更早的备份里有。
/// - **复习日志不删**：统计（复习日历 / 复习量 / 时长）以日志为唯一事实，过去的学习记录不能因为
///   删了卡就消失（与 Anki 删卡保留 revlog 一致）。日志不动，日志指纹不变，也就不触发 RWKV 重建；
///   RWKV 回放按卡片缓存取卡，已清除的卡不再参与。
/// - 媒体：只删「被清除笔记引用过、而此刻没有任何存活引用」的文件（存活引用见
///   [srsAllMediaReferences]，含已删未清的笔记与并发候选值），按不区分大小写比较。媒体删除不跨设备
///   传播（srs_media_sync.dart），同步目录里的媒体不动；备份的共享媒体池有自己的副本。
library;

import 'dart:io';

import 'package:fushi_engine/srs/apkg/srs_apkg_common.dart' show srsMediaRefsIn;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_sync.dart'
    show srsAllMediaReferences;
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;

/// 同步安全期：墓碑发布（服务器时间 S）后过了这么久才物理清除。与同步层的退役时限
/// （[SrsSyncOptions.retireAfterMs] 的缺省值）一致，测试钉住两者相等。
const Duration kSrsTombstonePurgeAfter = Duration(days: 90);

/// 维护时每块处理的候选笔记数（一块一个独占区 + 一个事务）。
const int kSrsPurgeChunk = 200;

/// 一次清除做了什么。
class SrsPurgeReport {
  int notes = 0;
  int cards = 0;
  int events = 0;
  int mediaFiles = 0;

  /// 被 shouldStop 叫停（下次打开 store 从剩下的候选继续）。
  bool stopped = false;

  @override
  String toString() =>
      'SrsPurgeReport(notes=$notes, cards=$cards, events=$events, '
      'media=$mediaFiles, stopped=$stopped)';
}

/// 墓碑是否已过安全期。
///
/// 参考时刻取删除寄存器里每条生效的删除记录的 S（已知时）——取其中**最晚**的一条；任何一条删除记录
/// 的 S 未知时：从没同步过的副本（[localOnly]）用删除记录的值（删除时的可信时间），否则不清。
bool srsTombstoneExpired(
  SrsRegister deleted,
  int? Function(String eventId) serverTimeOf, {
  required int nowMs,
  required int afterMs,
  required bool localOnly,
}) {
  int? latest;
  for (final SrsFieldEdit e in deleted.live) {
    final Object? v = e.value;
    if (v is! int) continue;
    final int? ref = serverTimeOf(e.id) ?? (localOnly ? v : null);
    if (ref == null) return false;
    if (latest == null || ref > latest) latest = ref;
  }
  return latest != null && nowMs - latest >= afterMs;
}

Set<String> _refsIn(String html) => <String>{
  ...srsMediaRefsIn(html),
  ...srsStyleRefsIn(html),
};

/// 维护：清除全部过了安全期的墓碑（store 打开后在后台跑）。分块、每块之间让出事件循环；
/// [shouldStop] 每块前问一次（store 换掉时停，下次从剩下的候选继续——已清的不会再成为候选）。
/// [mediaRoot] 给出时一并回收不再被引用的媒体文件。
Future<SrsPurgeReport> srsPurgeExpiredTombstones(
  SrsDbStore store, {
  Directory? mediaRoot,
  Duration after = kSrsTombstonePurgeAfter,
  int chunkSize = kSrsPurgeChunk,
  bool Function()? shouldStop,
}) async {
  final List<String> candidates = await store.purgeCandidateNoteIds();
  return _purge(
    store,
    candidates,
    afterMs: after.inMilliseconds,
    localOnly: store.neverSynced,
    mediaRoot: mediaRoot,
    chunkSize: chunkSize,
    shouldStop: shouldStop,
  );
}

/// 用户确认后当场清除 [noteIds]（例如删牌组时选了「永久删除」）。只允许从没同步过的副本：
/// 同步过的副本当场清除会让还没读到删除记录的对端无从得知删除（见库注释），调用方应先看
/// [SrsDbStore.neverSynced]。笔记必须已经删除（还没删的跳过）。
Future<SrsPurgeReport> srsPurgeNotesNow(
  SrsDbStore store,
  List<String> noteIds, {
  Directory? mediaRoot,
}) {
  if (!store.neverSynced) {
    throw StateError('immediate purge is only allowed before the first sync');
  }
  return _purge(
    store,
    noteIds,
    afterMs: 0,
    localOnly: true,
    mediaRoot: mediaRoot,
    chunkSize: kSrsPurgeChunk,
  );
}

Future<SrsPurgeReport> _purge(
  SrsDbStore store,
  List<String> noteIds, {
  required int afterMs,
  required bool localOnly,
  required Directory? mediaRoot,
  required int chunkSize,
  bool Function()? shouldStop,
}) async {
  final SrsPurgeReport report = SrsPurgeReport();
  final Set<String> mediaCandidates = <String>{};
  final int step = chunkSize < 1 ? 1 : chunkSize;
  for (int i = 0; i < noteIds.length; i += step) {
    if (shouldStop?.call() == true) {
      report.stopped = true;
      break;
    }
    final List<String> chunk = noteIds.sublist(
      i,
      i + step > noteIds.length ? noteIds.length : i + step,
    );
    // 「此刻」在每块里重取：长时间维护期间可信时间在走。
    final (int nowMs, _) = store.now();
    final SrsPurgeChunk r = await store.purgeDeletedNotes(
      chunk,
      eligible: (SrsRegister del, int? Function(String) serverTimeOf) =>
          srsTombstoneExpired(
            del,
            serverTimeOf,
            nowMs: nowMs,
            afterMs: afterMs,
            localOnly: localOnly,
          ),
      mediaRefsOf: mediaRoot == null ? null : _refsIn,
    );
    report
      ..notes += r.notes.length
      ..cards += r.cards
      ..events += r.events;
    mediaCandidates.addAll(r.mediaRefs);
    // 让出事件循环：维护在后台跑，块与块之间复习 / 编辑的写入照常插进来。
    await Future<void>.delayed(Duration.zero);
  }
  if (mediaRoot != null && mediaCandidates.isNotEmpty) {
    report.mediaFiles = await _deleteUnreferencedMedia(
      store,
      mediaRoot,
      mediaCandidates,
    );
  }
  return report;
}

/// 删掉 [candidates] 里此刻没有任何存活引用的文件（只删 [mediaRoot] 下的裸文件名）。
/// 比较不区分大小写：Windows / macOS 默认卷上大小写不同的两个名字是同一个文件。
Future<int> _deleteUnreferencedMedia(
  SrsDbStore store,
  Directory mediaRoot,
  Set<String> candidates,
) async {
  final Set<String> alive = <String>{
    for (final String n in await srsAllMediaReferences(store)) n.toLowerCase(),
  };
  int deleted = 0;
  for (final String name in candidates) {
    if (!_isBareName(name) || alive.contains(name.toLowerCase())) continue;
    final File f = File(p.join(mediaRoot.path, name));
    try {
      if (await f.exists()) {
        await f.delete();
        deleted++;
      }
    } on FileSystemException {
      // 被占用（Windows 上正在播放 / 预览）：留着。只影响这一个文件的空间。
    }
  }
  return deleted;
}

bool _isBareName(String n) =>
    n.isNotEmpty &&
    !n.contains('/') &&
    !n.contains(r'\') &&
    !n.contains(':') &&
    n != '.' &&
    n != '..';
