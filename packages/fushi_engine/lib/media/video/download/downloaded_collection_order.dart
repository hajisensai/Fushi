import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_filename_parser.dart';

/// 下载管理合集的**集号序**——单一真相源（BUG-2941）。
///
/// 下载合集的成员是独立下载任务按完成先后一集集落进来的，没有「用户写出来的
/// 顺序」，唯一正确的序是集号序。两处必须得出**同一个**全序：
/// - 本机落库后的自动整理（`VideoBookRepository.reorderDownloadedCollectionEpisodes`）；
/// - 合集同步对 `episodeOrdered` 条目的合并（`CollectionSyncEngine`）。
/// 两处口径一旦不同，同步就会每轮判「本地与合并结果不一致」来回改写。
///
/// 所以这里是成员键的**纯函数**：只看 wire 成员键，不看本机路径、不查库——
/// 没有这些文件、也没有下载任务的对端算出的顺序与下载端逐字节相同。下载集的
/// bookUid 是 `video/<文件名主干>`（下载整理器把季集写进文件名），季/集就从它解。
///
/// 只重排**视频成员**，且只在视频成员原来占的槽位之间重排；非视频成员原位不动
/// （它们的本地键与 wire 键可能不同域，参与排序会让本地整理与同步结果不一致）。
/// 视频成员全序：有集号的按季（缺省第 1 季）→ 集；解不出集号的（PV / 特典）殿后；
/// 最后按 entryKey 兜底，保证确定性。
///
/// [videoPathByUid] 只给本机落库整理用：旧番剧种子导入保留原文件名，季号可能只
/// 写在父目录上（`Season 2/01.mkv`），bookUid 里已经丢了，得看真实路径。同步合并
/// 不传（必须只依赖 wire 键）。两者只在「带集号序标记 + 季号只在目录上」时不同，
/// 而带标记的下载合集文件都被整理器改名成 `… - SxxEyy`，不会出现这种情况。
List<CollectionMemberKey> orderDownloadedCollectionMembers(
  List<CollectionMemberKey> members, {
  Map<String, String> videoPathByUid = const <String, String>{},
}) {
  final String video = MediaKind.video.dbValue;
  final List<CollectionMemberKey> videos = <CollectionMemberKey>[
    for (final CollectionMemberKey m in members)
      if (m.mediaType == video) m,
  ];
  final Map<CollectionMemberKey, VideoNameInfo> infoOf =
      <CollectionMemberKey, VideoNameInfo>{
        for (final CollectionMemberKey m in videos)
          m: parseVideoPath(videoPathByUid[m.entryKey] ?? m.entryKey),
      };
  videos.sort((CollectionMemberKey a, CollectionMemberKey b) {
    final VideoNameInfo ia = infoOf[a]!;
    final VideoNameInfo ib = infoOf[b]!;
    final int extrasA = ia.episode == null ? 1 : 0;
    final int extrasB = ib.episode == null ? 1 : 0;
    if (extrasA != extrasB) return extrasA.compareTo(extrasB);
    final int seasonCmp = (ia.season ?? 1).compareTo(ib.season ?? 1);
    if (seasonCmp != 0) return seasonCmp;
    final int episodeCmp = (ia.episode ?? 0).compareTo(ib.episode ?? 0);
    if (episodeCmp != 0) return episodeCmp;
    return a.entryKey.compareTo(b.entryKey);
  });
  int next = 0;
  return <CollectionMemberKey>[
    for (final CollectionMemberKey m in members)
      m.mediaType == video ? videos[next++] : m,
  ];
}
