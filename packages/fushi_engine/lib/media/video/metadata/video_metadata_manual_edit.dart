/// 用户手填的作品资料（BUG-5082）。
///
/// 三家主源（AniDB / MAL / TMDB）都查不到的作品没有任何刮削产物，此前作品行
/// 不存在，详情页的字段锁入口也是灰的，用户没有任何办法补简介 / 年份。手填是
/// 「用户」这一类资料来源：值写进同一张 `video_metadata_works`（UI 与互联 / 备份
/// 不需要第二套读取口径），改过的字段同时进 v99 字段锁——之后任何一次刮削都保留
/// 手填值（与封面锁同一语义）。清空一个字段 = 撤回手填：字段解锁、值清掉，下次
/// 刮削回填刮削值。
///
/// 手填不写 provider 身份：作品仍算「未识别」，照常进自动补刮 / 待确认，等主源
/// 收录后刮到的未锁字段照常落库。
library;

import 'package:fushi_core/fushi_core.dart';

/// 手填资料要写到哪一行作品上（与刮削计划器的归属口径一致）。
sealed class VideoWorkManualTarget {
  const VideoWorkManualTarget();
}

/// 已有作品行：直接改这一行。
final class VideoWorkManualTargetExisting extends VideoWorkManualTarget {
  const VideoWorkManualTargetExisting(this.work);
  final VideoMetadataWorkRow work;
}

/// 作品挂在合集上（多集作品，计划器按合集整体刮）。
final class VideoWorkManualTargetCollection extends VideoWorkManualTarget {
  const VideoWorkManualTargetCollection(this.collectionId);
  final int collectionId;
}

/// 作品挂在单个视频上（散装电影 / 单成员合集，计划器按单集刮）。
final class VideoWorkManualTargetBook extends VideoWorkManualTarget {
  const VideoWorkManualTargetBook(this.bookUid);
  final String bookUid;
}

/// 合集页「编辑资料」写到哪一行。
///
/// 与 [FushiDatabase.resolveVideoMetadataWorkForCollection] 同一判据：合集自己
/// 的行优先；成员上恰好一条作品行就是它；**多条不猜**（各集各自识别的播放清单，
/// 页面本来就显示不出唯一作品）返回 null。都没有时按刮削计划器的归属建行：只有
/// 一个视频成员的合集按单集刮（行挂在那一集上），否则挂在合集上——手填行落在
/// 刮削日后会写的同一行上，字段锁才能在那次刮削里生效。
Future<VideoWorkManualTarget?> videoWorkManualTargetForCollection(
  FushiDatabase database,
  int collectionId,
) async {
  final VideoMetadataWorkRow? own = await database
      .getVideoMetadataWorkByCollection(collectionId);
  if (own != null) return VideoWorkManualTargetExisting(own);
  final List<String> videoMembers = <String>[
    for (final MediaCollectionItemRow item in await database.getCollectionItems(
      collectionId,
    ))
      if (item.mediaType == 'video') item.entryKey,
  ];
  final List<VideoMetadataWorkRow> memberWorks = <VideoMetadataWorkRow>[
    for (final String bookUid in videoMembers)
      if (await database.getVideoMetadataWorkByBook(bookUid)
          case final VideoMetadataWorkRow row)
        row,
  ];
  if (memberWorks.length == 1) {
    return VideoWorkManualTargetExisting(memberWorks.single);
  }
  if (memberWorks.length > 1) return null;
  // 唯一成员只在互联对端时（合集清单跨端 union，entryKey 是 host 侧 bookUid、
  // 本机没有视频行）本机计划器根本不会刮它，按单集建行还会撞 `book_uid` 外键：
  // 挂在合集上。
  if (videoMembers.length == 1 &&
      await database.getVideoBookByBookUid(videoMembers.single) != null) {
    return VideoWorkManualTargetBook(videoMembers.single);
  }
  return VideoWorkManualTargetCollection(collectionId);
}

/// 散装视频页「编辑资料」写到哪一行：有行改行，没有就挂在这个视频上。
Future<VideoWorkManualTarget> videoWorkManualTargetForBook(
  FushiDatabase database,
  String bookUid,
) async {
  final VideoMetadataWorkRow? row = await database.getVideoMetadataWorkByBook(
    bookUid,
  );
  return row == null
      ? VideoWorkManualTargetBook(bookUid)
      : VideoWorkManualTargetExisting(row);
}

/// 编辑对话框里用户确认的一份资料。空串 / 空列表 = 该字段没有手填值。
class VideoWorkManualEdit {
  const VideoWorkManualEdit({
    required this.title,
    this.originalTitle,
    this.overview,
    this.tagline,
    this.year,
    this.genres = const <String>[],
    this.studios = const <String>[],
  });

  final String title;
  final String? originalTitle;
  final String? overview;
  final String? tagline;
  final int? year;
  final List<String> genres;
  final List<String> studios;
}

/// 文本字段规范化：去首尾空白，空串归 null（「没有手填值」只有一种形态）。
String? normalizeManualText(String? value) {
  final String? trimmed = value?.trim();
  return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
}

/// 词条字段规范化：逐项去空白、丢空项、按出现顺序去重。
List<String> normalizeManualTerms(Iterable<String> values) {
  final Set<String> seen = <String>{};
  return <String>[
    for (final String raw in values)
      if (raw.trim() case final String value
          when value.isNotEmpty && seen.add(value))
        value,
  ];
}

/// 逗号 / 顿号 / 换行分隔的输入拆成词条（UI 的「类型」「制作公司」输入框）。
List<String> splitManualTerms(String input) =>
    normalizeManualTerms(input.split(RegExp(r'[,，、\n]')));
