/// 协议 3 的 profile 并入在新代（协议 4）里只剩一件事：**续做迁移带过来的半截并入**（G9-5，D23 改判）。
///
/// 协议 3 把本机一个有用户笔记的 profile 并入同步目录里已有的另一个 uid：记标记 `profile_merge/<旧 uid>`、把旧 uid 的
/// 事件重映射成新 uid 下的副本、改主库 `profiles.uid`、最后核对并删旧 uid。中途被杀的库带着标记升级到新代：迁移把两个
/// uid 各迁成一个集合、标记原样带进新代库（native/fushi_fsrs/src/store/gen4/migrate.rs `carry_library_meta`）。这里按
/// 两个文件能做到的顺序收尾（[srsResumeProfileMerge]）：
///
/// 1. 主库 profile 还指着旧 uid：先把旧 uid 的 SRS 媒体拷进新 uid（内容寻址、不覆盖），再改主库 uid——此后本机打开的就是
///    新 uid，标记还在；
/// 2. 发内核的 `profile_merge_commit {from, to, now}`（[srsFinishProfileMerge]）：内核一个事务里把旧 uid 的集合整个并进
///    新 uid 的集合（操作与设备公钥都带过去，重映射副本由别名层归回原件），删掉旧集合、标记与旧 uid 的本机状态行；
/// 3. 删旧 uid 的媒体目录。
///
/// 任何一步失败都留着标记、可以用同样的参数重跑：1 之后失败，下次主库已经是新 uid、只做 2 与 3；2 失败整笔回滚，旧集合
/// 一行不少。顺序反过来（先收尾再改主库）不行：收尾删了标记与旧集合之后、改主库之前被杀，主库指着一个已经没有集合、
/// 也没有标记的 uid，本机打开时会给它建一个空集合，数据看上去全丢了。
///
/// 新代不再**发起**协议 3 式的 uid 并入：关联已有集合是内核的 `collection_adopt` / `collection_join`（规划 §1.6），
/// 协议 3 的重映射算法整个删了（[srsMergeProfileUid] 只剩明确的拒绝）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:fushi_core/fushi_core.dart' show FushiDatabase;
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi_engine/srs/srs_profile_data.dart'
    show SrsProfileMergeFinish;
import 'package:fushi_engine/srs/srs_reads.dart';

/// srs.db `srs_meta` 里「这个旧 uid 的并入进行中」标记的键前缀（值 = `{"profileId":..,"newUid":..}`）。
const String kSrsProfileMergeMarkerPrefix = 'profile_merge/';

/// 新代不再发起协议 3 式的 uid 并入（[srsMergeProfileUid]）：本机 profile 有数据时关联别的集合要走内核的
/// `collection_adopt` / `collection_join`。什么都没改。
class SrsProfileMergeRemoved extends StateError {
  SrsProfileMergeRemoved({required this.oldUid, required this.newUid})
    : super(
        'merging profile $oldUid into $newUid by remapping its uid was '
        'removed with protocol 3; linking a profile that has data to another '
        'collection is collection_adopt / collection_join. Nothing changed.',
      );

  final String oldUid;
  final String newUid;
}

/// 还没做完的并入（迁移带过来的协议 3 标记）。调用方对每一项调 [srsResumeProfileMerge]。
class SrsPendingProfileMerge {
  const SrsPendingProfileMerge({
    required this.profileId,
    required this.oldUid,
    required this.newUid,
  });

  final int profileId;
  final String oldUid;
  final String newUid;
}

/// srs.db 里记着、还没做完的并入。
Future<List<SrsPendingProfileMerge>> srsPendingProfileMerges(
  SrsCore core,
) async {
  final SrsColumns c = (await srsReadLib(core, 'profile_merges')).table;
  final SrsStringColumn key = c.strings('key');
  final SrsStringColumn value = c.strings('value');
  final List<SrsPendingProfileMerge> out = <SrsPendingProfileMerge>[];
  for (int i = 0; i < c.rows; i++) {
    final Object? v = jsonDecode(value[i]);
    if (v is! Map) continue;
    final Object? id = v['profileId'];
    final Object? neu = v['newUid'];
    if (id is! int || neu is! String) continue;
    out.add(
      SrsPendingProfileMerge(
        profileId: id,
        oldUid: key[i].substring(kSrsProfileMergeMarkerPrefix.length),
        newUid: neu,
      ),
    );
  }
  return out;
}

/// 续做本机 profile [profileId] 从 [oldUid] 到 [newUid] 的半截并入（顺序与理由见库注释）。[commit] 发收尾那条内核命令
/// （生产：`() => srsFinishProfileMerge(core, from: oldUid, to: newUid, nowMs: ..)`）；[mediaRoot] 是全部 profile 的
/// SRS 媒体根（`<support>/srs_media`），null = 不动媒体。
///
/// 主库 profile 既不是 [oldUid] 也不是 [newUid]、或 [newUid] 已是本机另一个 profile（`profiles.uid` 唯一）时抛
/// [StateError]，什么都不改。调用之后调用方按 profiles 表的新 uid 重开 store。
Future<SrsProfileMergeFinish> srsResumeProfileMerge(
  FushiDatabase db, {
  required int profileId,
  required String oldUid,
  required String newUid,
  required Future<SrsProfileMergeFinish> Function() commit,
  Directory? mediaRoot,
}) async {
  if (oldUid.isEmpty || newUid.isEmpty || oldUid == newUid) {
    throw ArgumentError('cannot merge profile uid $oldUid into $newUid');
  }
  final String current = await db.profileUidOf(profileId);
  if (current != oldUid && current != newUid) {
    throw StateError(
      'profile $profileId has uid $current, neither $oldUid nor $newUid',
    );
  }
  if (current == oldUid) {
    final QueryRow? taken = await db
        .customSelect(
          'SELECT id FROM profiles WHERE uid = ? AND id != ?',
          variables: <Variable<Object>>[
            Variable<String>(newUid),
            Variable<int>(profileId),
          ],
        )
        .getSingleOrNull();
    if (taken != null) {
      throw StateError(
        'uid $newUid already belongs to local profile '
        '${taken.read<int>('id')}',
      );
    }
    if (mediaRoot != null) await _copyMedia(mediaRoot, oldUid, newUid);
    await db.adoptProfileUid(profileId, newUid);
  }
  final SrsProfileMergeFinish done = await commit();
  if (mediaRoot != null) {
    // 改主库之后、收尾之前旧 uid 的副本可能还写进过媒体：再拷一次（同名不覆盖），然后删旧目录。
    await _copyMedia(mediaRoot, oldUid, newUid);
    final Directory old = Directory(_join(mediaRoot.path, oldUid));
    if (old.existsSync()) await old.delete(recursive: true);
  }
  return done;
}

/// 已删：新代不再发起协议 3 式的 uid 并入，一律抛 [SrsProfileMergeRemoved]、什么都不改。签名照旧只为冻结的协议 1
/// 客户端测试副本（test/srs/sync2/v1_client，不许修改）还能编译；那份副本随 G7-6 删协议 3 一起删时这个函数一并删。
Future<void> srsMergeProfileUid(
  FushiDatabase db, {
  required SrsCore core,
  required int profileId,
  required String oldUid,
  required String newUid,
  required String deviceId,
  Directory? mediaRoot,
}) async => throw SrsProfileMergeRemoved(oldUid: oldUid, newUid: newUid);

String _join(String a, String b) => '$a${Platform.pathSeparator}$b';

/// `<root>/<old>/` 下的文件拷进 `<root>/<new>/`：已有同名的不动（内容寻址：同名即同内容），先写临时名再改名。
Future<void> _copyMedia(Directory root, String oldUid, String newUid) async {
  final Directory from = Directory(_join(root.path, oldUid));
  if (!from.existsSync()) return;
  final Directory to = Directory(_join(root.path, newUid));
  await to.create(recursive: true);
  await for (final FileSystemEntity f in from.list(followLinks: false)) {
    if (f is! File) continue;
    final String name = f.uri.pathSegments.last;
    final File dest = File(_join(to.path, name));
    if (dest.existsSync()) continue;
    final File tmp = File('${dest.path}.merge-tmp');
    await f.copy(tmp.path);
    await tmp.rename(dest.path);
  }
}
