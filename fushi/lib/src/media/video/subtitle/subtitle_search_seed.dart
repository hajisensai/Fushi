/// 在线字幕检索的**身份种子**：把 app 早就知道的身份信息（刮削得到的外部 ID、日文原名）
/// 摆在「拿界面上的显示名去模糊搜」前面。
library;

/// 打开在线字幕检索时的检索种子。
///
/// 存在的理由是一个真实故障（BUG-1842）：用户库里的《Re:Zero》第四季显示名是中文
/// 「Re：从零开始的异世界生活 第四季 丧失篇」，而 Jimaku 的条目名只有罗马音/英文/日文，
/// AniList 也匹配不上这种「中文译名 + 季度 + 篇名」的长串（实测：光「从零开始的异世界
/// 生活」能命中，整串 0 结果）。于是搜索必然空手而归——**尽管这个视频刮削过，库里明明
/// 白白存着它的 AniList ID 和日文原名**。有身份就别再去猜名字。
///
/// 本类**不绑定任何 provider**：id 与备选词经 `VideoMediaReference` / 请求的
/// `alternateTitles` 交给 `VideoSubtitleRegistry`，Jimaku 与 OpenSubtitles 各取所需。
class SubtitleSearchSeed {
  const SubtitleSearchSeed({
    this.anilistId,
    this.tmdbId,
    this.isMovie = false,
    this.queries = const <String>[],
  });

  /// 刮削得到的 AniList 作品 id；非空时可直接按 `anilist_id` 检索，完全跳过文本匹配。
  final int? anilistId;

  /// 刮削得到的 TMDB 数字 id（movie / tv 由 [isMovie] 区分，不在此编码——
  /// 「tv:<id>」这类 provider 私有拼法属于各自的客户端）。
  final int? tmdbId;

  /// 该作品是电影而不是剧集（决定 TMDB id 落在哪个命名空间）。
  final bool isMovie;

  /// 候选搜索词，按命中概率降序。第一项用于预填输入框。
  final List<String> queries;

  /// 预填输入框用的搜索词；一个都没有时为空串。
  String get primaryQuery => queries.isEmpty ? '' : queries.first;

  /// 除主搜索词以外的备选（主词搜空后由 provider 依次再试）。
  List<String> get fallbackQueries =>
      queries.length <= 1 ? const <String>[] : queries.sublist(1);

  /// 是否带有可直接检索的强身份（无需靠名字猜）。
  bool get hasStrongIdentity => anilistId != null || tmdbId != null;
}

/// 组装 [SubtitleSearchSeed]。纯函数，不碰数据库，便于单测。
///
/// [externalIds] 是 `provider → externalId`（provider 名小写，见
/// `video_metadata_provider_identities.provider`：AniList 写 `anilist`、TMDB 写 `tmdb`）。
///
/// 搜索词优先级——**日文原名排第一**：Jimaku 是日语字幕站，条目名是罗马音/英文/日文，
/// 上传的字幕文件名也基本是日文或罗马音；而库里的显示名很可能是中文译名，拿它去搜命中率
/// 最低。依次为：日文原名 → 刮削作品名 → 显示名（文件名解析结果）→ 合集名。
/// 去空白、去重，保持上述先后。
SubtitleSearchSeed buildSubtitleSearchSeed({
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

  return SubtitleSearchSeed(
    anilistId: _numericId(externalIds['anilist']),
    tmdbId: _numericId(externalIds['tmdb']),
    isMovie: isMovie,
    queries: List<String>.unmodifiable(queries),
  );
}

/// `video_metadata_provider_identities.external_id` 是文本列，只有能解析成正整数的才是
/// 可直接检索的强身份；空串/非数字（某些 provider 存 slug）一律当没有。
int? _numericId(String? raw) {
  final String trimmed = raw?.trim() ?? '';
  if (trimmed.isEmpty) return null;
  final int? value = int.tryParse(trimmed);
  if (value == null || value <= 0) return null;
  return value;
}
