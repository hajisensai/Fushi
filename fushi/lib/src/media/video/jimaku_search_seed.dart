import 'package:fushi/src/media/video/jimaku_client.dart';

/// 打开在线字幕检索时的**检索种子**：把 app 早就知道的身份信息（刮削得到的外部 ID、
/// 日文原名）摆在「拿界面上的显示名去模糊搜」前面。
///
/// 存在的理由是一个真实故障：用户库里的《Re:Zero》第四季显示名是中文
/// 「Re：从零开始的异世界生活 第四季 丧失篇」，而 Jimaku 的条目名只有罗马音/英文/日文，
/// AniList 也匹配不上这种「中文译名 + 季度 + 篇名」的长串（实测：光「从零开始的异世界
/// 生活」能命中，整串 0 结果）。于是搜索必然空手而归——**尽管这个视频刮削过，库里明明
/// 白白存着它的 AniList ID 和日文原名**。有身份就别再去猜名字。
class JimakuSearchSeed {
  const JimakuSearchSeed({
    this.anilistId,
    this.tmdbId,
    this.queries = const <String>[],
  });

  /// 刮削得到的 AniList 作品 id；非空时可直接按 `anilist_id` 检索 Jimaku，
  /// 完全跳过文本匹配这一环。
  final int? anilistId;

  /// 刮削得到的 TMDB id，已按 Jimaku 的 `tv:<id>` / `movie:<id>` 编码。
  final String? tmdbId;

  /// 候选搜索词，按命中概率降序。第一项用于预填输入框。
  final List<String> queries;

  /// 预填输入框用的搜索词；一个都没有时为空串。
  String get primaryQuery => queries.isEmpty ? '' : queries.first;

  /// 除主搜索词以外的备选（主词搜空后依次再试）。
  List<String> get fallbackQueries =>
      queries.length <= 1 ? const <String>[] : queries.sublist(1);

  /// 是否带有可直接检索的强身份（无需靠名字猜）。
  bool get hasStrongIdentity => anilistId != null || tmdbId != null;
}

/// 组装 [JimakuSearchSeed]。纯函数，不碰数据库，便于单测。
///
/// [externalIds] 是 `provider → externalId`（provider 名小写，见
/// `video_metadata_provider_identities.provider`：AniList 写 `anilist`、TMDB 写 `tmdb`）。
///
/// 搜索词优先级——**日文原名排第一**：Jimaku 是日语字幕站，条目名是罗马音/英文/日文，
/// 上传的字幕文件名也基本是日文或罗马音；而库里的显示名很可能是中文译名，拿它去搜命中率
/// 最低。依次为：日文原名 → 刮削作品名 → 显示名（文件名解析结果）→ 合集名。
/// 去空白、去重，保持上述先后。
JimakuSearchSeed buildJimakuSearchSeed({
  String? originalTitle,
  String? metadataTitle,
  String? displayTitle,
  String? collectionTitle,
  Map<String, String> externalIds = const <String, String>{},
  bool isMovie = false,
}) {
  final List<String> queries = <String>[];
  void add(String? value) {
    final String trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty) return;
    if (queries.contains(trimmed)) return;
    queries.add(trimmed);
  }

  add(originalTitle);
  add(metadataTitle);
  add(displayTitle);
  add(collectionTitle);

  final String? rawAnilist = externalIds['anilist']?.trim();
  final String? rawTmdb = externalIds['tmdb']?.trim();
  final int? anilistId = rawAnilist == null || rawAnilist.isEmpty
      ? null
      : int.tryParse(rawAnilist);
  final int? tmdbNumeric =
      rawTmdb == null || rawTmdb.isEmpty ? null : int.tryParse(rawTmdb);

  return JimakuSearchSeed(
    anilistId: anilistId,
    tmdbId: tmdbNumeric == null
        ? null
        : jimakuTmdbId(movie: isMovie, tmdbId: tmdbNumeric),
    queries: List<String>.unmodifiable(queries),
  );
}
