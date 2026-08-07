/// 集显示名提案与批量改名（TODO-2491 数据层）。
///
/// 与集级刮削（`episode_scrape_service.dart`）刻意分离：**自动刮削路径永不改
/// 名**（对齐 BUG-1310 用户拍板——改名必须经用户确认）。本文件提供：
///  - [proposeEpisodeDisplayName]：纯函数，集号 + 集名 → 展示名；
///  - [renameCollectionEpisodes]：批量改名服务，`dryRun: true` 只产出
///    旧名/新名对照表（供 UI 确认弹窗渲染），`dryRun: false` 逐条写穿
///    `video_books.title`（走 `updateVideoBookTitle`，与库页手动重命名同一
///    落库口）。
///
/// 改名依据是集级刮削已落库的 `video_scrape_meta`（`episode_number` 非空的
/// 行）；未刮或作品级旧行不产生提案——先刮再改名。
library;

import 'package:fushi_core/fushi_core.dart';

/// 纯函数：集号 + 集名 → 展示名。
///
/// 格式 `E<零填充集号> <集名>`（如 `E01 出会い`；无集名时只有 `E01`）。
/// [padWidth] 是集号最小宽度（默认 2；三位数集号的长番由调用方按最大集号传
/// 3），语言中立、可被文件名排序。
String proposeEpisodeDisplayName({
  required int episodeNumber,
  String? episodeTitle,
  int padWidth = 2,
}) {
  final String number = episodeNumber.toString().padLeft(padWidth, '0');
  final String? title = episodeTitle?.trim();
  return (title == null || title.isEmpty) ? 'E$number' : 'E$number $title';
}

/// 一条改名提案：旧名 → 新名（`newTitle != oldTitle` 才产出）。
class EpisodeRenameProposal {
  const EpisodeRenameProposal({
    required this.bookUid,
    required this.oldTitle,
    required this.newTitle,
  });

  final String bookUid;
  final String oldTitle;
  final String newTitle;
}

/// 对合集 [collectionId] 的视频成员按集级刮削资料生成改名提案。
///
/// [dryRun] = true 只返回对照表；false 时对每条提案写穿
/// `video_books.title` 后返回同一份对照表（供调用方汇报）。
///
/// 提案规则：
///  - 只处理 `video_scrape_meta.episode_number` 非空的成员（集级已刮）；
///  - 集名 = 该行 `title`；若与合集作品名相同（集名缺失时集级刮削的回退值），
///    不当集名用——提案退化为纯 `E01` 式；
///  - 零填充宽度取合集内最大集号的十进制宽度（至少 2）；
///  - 新旧同名不产出提案。
Future<List<EpisodeRenameProposal>> renameCollectionEpisodes({
  required FushiDatabase db,
  required int collectionId,
  required bool dryRun,
}) async {
  final CollectionScrapeMetaRow? collectionMeta =
      await db.getCollectionScrapeMeta(collectionId);

  final List<MediaCollectionItemRow> items =
      await db.getCollectionItems(collectionId);
  final List<({VideoBookRow book, VideoScrapeMetaRow meta, int episode})>
      scraped = <({VideoBookRow book, VideoScrapeMetaRow meta, int episode})>[];
  for (final MediaCollectionItemRow item in items) {
    if (item.mediaType != 'video') continue;
    final VideoBookRow? book = await db.getVideoBookByBookUid(item.entryKey);
    if (book == null) continue;
    final VideoScrapeMetaRow? meta = await db.getVideoScrapeMeta(book.bookUid);
    final int? episode = meta?.episodeNumber;
    if (meta == null || episode == null) continue;
    scraped.add((book: book, meta: meta, episode: episode));
  }
  if (scraped.isEmpty) return const <EpisodeRenameProposal>[];

  int maxEpisode = 0;
  for (final ({VideoBookRow book, VideoScrapeMetaRow meta, int episode}) s
      in scraped) {
    if (s.episode > maxEpisode) maxEpisode = s.episode;
  }
  final int padWidth =
      maxEpisode.toString().length < 2 ? 2 : maxEpisode.toString().length;

  final List<EpisodeRenameProposal> proposals = <EpisodeRenameProposal>[];
  for (final ({VideoBookRow book, VideoScrapeMetaRow meta, int episode}) s
      in scraped) {
    // 集名缺失时集级刮削回退写了作品名——那不是集名，别拼成「E01 作品名」。
    final String? episodeTitle =
        (collectionMeta != null && s.meta.title == collectionMeta.title)
            ? null
            : s.meta.title;
    final String newTitle = proposeEpisodeDisplayName(
      episodeNumber: s.episode,
      episodeTitle: episodeTitle,
      padWidth: padWidth,
    );
    if (newTitle == s.book.title) continue;
    proposals.add(EpisodeRenameProposal(
      bookUid: s.book.bookUid,
      oldTitle: s.book.title,
      newTitle: newTitle,
    ));
  }

  if (!dryRun) {
    for (final EpisodeRenameProposal proposal in proposals) {
      await db.updateVideoBookTitle(proposal.bookUid, proposal.newTitle);
    }
  }
  return proposals;
}
