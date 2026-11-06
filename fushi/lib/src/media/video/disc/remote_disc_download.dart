import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/disc/disc_format.dart'
    show discMemberBackingFilePath, discRootForMemberPath;
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;
import 'package:fushi_engine/sync/remote_collection_adoption_service.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/sync/remote_disc_share.dart';

/// 整盘下载落地后，把 host 库里这张盘上的标题行**认领**成本机行：bookUid 沿用
/// host 的（与单集下载同一口径，详情页里同一集从「远端」变「本机」，合集成员不变），
/// `videoPath` 指向本机盘根下的同一条成员路径，于是本机原盘的全部能力（原盘菜单、
/// 规格角标、选盘）立刻可用，不需要再扫描一次。
///
/// [remoteById] 是当前远端清单（取标题 / 合集归属 / 看完标记）；不在清单里的标题
/// 用成员文件名做标题，仍然认领（它确实在这张盘上）。成员路径在本机不存在（清单与
/// 落地不一致）的标题跳过并返回在 `missing` 里，不建一条打不开的行。
Future<({List<String> registered, List<String> missing})>
registerDownloadedRemoteDisc({
  required VideoBookRepository repo,
  required RemoteCollectionAdoptionService adoption,
  required RemoteDiscShare share,
  required String localRoot,
  required Map<String, RemoteVideoInfo> remoteById,
  int Function()? now,
}) async {
  final List<String> registered = <String>[];
  final List<String> missing = <String>[];
  final int importedAt = (now ?? _wallClock)();
  for (final RemoteDiscShareTitle title in share.titles) {
    final String memberPath = title.localMemberPath(localRoot);
    if (discRootForMemberPath(memberPath) == null ||
        FileSystemEntity.typeSync(discMemberBackingFilePath(memberPath)) ==
            FileSystemEntityType.notFound) {
      missing.add(title.id);
      continue;
    }
    final RemoteVideoInfo? info = remoteById[title.id];
    await repo.saveVideoBook(
      VideoBooksCompanion(
        bookUid: Value(title.id),
        title: Value(
          info?.title ?? p.basenameWithoutExtension(title.path.split('/').last),
        ),
        videoPath: Value(memberPath),
        // 与本机原盘导入同一口径（`importSplitPlaylist`）：盘内 PGS 由盘自己管。
        embeddedSubtitleTrack: const Value<int?>(0),
        importedAt: Value(info?.importedAt ?? importedAt),
        completedAt: Value<DateTime?>(
          info?.completedAt == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(info!.completedAt!),
        ),
      ),
    );
    if (info != null) await adoption.adoptVideo(info);
    registered.add(title.id);
  }
  return (registered: registered, missing: missing);
}

int _wallClock() => DateTime.now().millisecondsSinceEpoch;

/// 把一组远端成员按「所在的盘」分组：每组签发一次共享会话（[open]），会话的
/// `titles` 认领同盘的其余成员，于是一张盘只问 host 一次、只建一个下载任务。
/// 返回顺序 = 成员顺序里每张盘第一次出现的位置。签发失败的成员单独返回（调用方
/// 按失败报给用户），不影响其它盘。
Future<({List<RemoteDiscShare> shares, List<RemoteVideoInfo> failed})>
groupRemoteDiscMembers(
  List<RemoteVideoInfo> members,
  Future<RemoteDiscShare> Function(String videoId) open,
) async {
  final List<RemoteDiscShare> shares = <RemoteDiscShare>[];
  final List<RemoteVideoInfo> failed = <RemoteVideoInfo>[];
  final Set<String> covered = <String>{};
  final Set<String> discKeys = <String>{};
  for (final RemoteVideoInfo member in members) {
    if (covered.contains(member.id)) continue;
    final RemoteDiscShare share;
    try {
      share = await open(member.id);
    } on RemoteDiscShareUnsupported {
      rethrow;
    } catch (_) {
      failed.add(member);
      continue;
    }
    covered
      ..add(member.id)
      ..addAll(share.titles.map((RemoteDiscShareTitle t) => t.id));
    if (discKeys.add(share.manifest.discKey)) shares.add(share);
  }
  return (shares: shares, failed: failed);
}
