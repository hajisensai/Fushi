import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:fushi/src/utils/misc/error_log_service.dart';

import 'package:fushi/src/media/video/video_filename_parser.dart';
import 'package:fushi/src/utils/net/app_http.dart';

/// Jimaku 条目的分类范围：动画 / 真人（Live Action）/ 全部。
///
/// Jimaku 站点把这两类拆成两个页面（`jimaku.cc` 与 `jimaku.cc/dramas`），API 侧对应
/// `/entries/search?anime=<bool>`。**这个参数是硬相等过滤而不是「偏好」**：服务端实现
/// （`src/routes/api/entries.rs`）第一行就是
/// `if self.anime != entry.flags.is_anime() { return None }`，且 `anime` 缺省为 `true`。
///
/// 两个后果决定了本枚举的存在：
/// 1. 不显式传 `anime=false` 就永远搜不到任何真人剧条目；
/// 2. 服务端**没有**「不限分类」这个取值，所以 [all] 只能靠发两次请求再合并去重实现
///    （见 [jimakuScopeAnimeFlags]）。
///
/// 另注：`anilist_id` / `tmdb_id` 的精确匹配也排在上面那句分类过滤之后，因此按 TMDB ID
/// 查真人剧时必须同时带 `anime=false`，否则命中率恒为 0。
enum JimakuSearchScope {
  /// 只搜动画条目（= 旧行为，服务端缺省值）。
  anime,

  /// 只搜真人条目（日剧/电影等，对应站点的 Live Action 页）。
  liveAction,

  /// 两类都搜：客户端发两次请求后按条目 id 合并去重。
  all,
}

/// 把 [scope] 展开成需要依次请求的 `anime=` 取值序列。
///
/// 单分类是「长度 1 的普通情况」，[JimakuSearchScope.all] 是「长度 2」——调用方统一按
/// 列表循环即可，不需要为「全部」写特例分支。
List<bool> jimakuScopeAnimeFlags(JimakuSearchScope scope) {
  switch (scope) {
    case JimakuSearchScope.anime:
      return const <bool>[true];
    case JimakuSearchScope.liveAction:
      return const <bool>[false];
    case JimakuSearchScope.all:
      return const <bool>[true, false];
  }
}

/// Jimaku 条目标记位。
///
/// API 层把服务端内部的 u32 bitfield 展开成 JSON 对象再返回（服务端 `models.rs` 注释
/// 原文：*At the API level, we expand the flags to a dict*），故此处按对象解析；字段缺失
/// 一律按 `false`（与服务端 `#[serde(default)]` 同语义）。
class JimakuEntryFlags {
  const JimakuEntryFlags({
    this.anime = false,
    this.unverified = false,
    this.external = false,
    this.movie = false,
    this.adult = false,
  });

  /// 该条目属于动画。
  final bool anime;

  /// 尚未经编辑审核。
  final bool unverified;

  /// 条目来自外部来源（如 kitsunekko/jpsubbers 镜像）。
  final bool external;

  /// 该条目是电影（而非剧集）。
  final bool movie;

  /// 面向成人受众。
  final bool adult;

  /// 是否为真人条目：`anime` 位取反。UI 用它给条目打「真人」标。
  bool get isLiveAction => !anime;
}

/// 解析 Jimaku entry 的 `flags` 字段；非对象（或缺失）返回全 false 的默认值。
///
/// 只认对象形态：API 只会返回对象，站点页面里内嵌的 u32 bitfield 不是本客户端的输入，
/// 不为不存在的情况写解析分支。
JimakuEntryFlags parseJimakuEntryFlags(Object? raw) {
  if (raw is! Map) return const JimakuEntryFlags();
  bool read(String key) => raw[key] == true;
  return JimakuEntryFlags(
    anime: read('anime'),
    unverified: read('unverified'),
    external: read('external'),
    movie: read('movie'),
    adult: read('adult'),
  );
}

/// 按 Jimaku 的 TMDB ID 编码拼串：`tv:<id>` / `movie:<id>`。
///
/// 编码来自服务端 schema 的 `pattern = (tv|movie):(\d+)`；Hibiki 侧的 TMDB 元数据
/// （`TmdbVideoMetadataProvider`）只给出裸数字 id + 媒体类型，需经此函数转换。
String jimakuTmdbId({required bool movie, required int tmdbId}) =>
    '${movie ? 'movie' : 'tv'}:$tmdbId';

/// Jimaku（jimaku.cc）字幕条目：一个番剧/作品。
class JimakuEntry {
  const JimakuEntry({
    required this.id,
    required this.name,
    this.anilistId,
    this.tmdbId,
    this.japaneseName,
    this.flags = const JimakuEntryFlags(),
  });

  final int id;
  final String name;
  final int? anilistId;

  /// `tv:<id>` / `movie:<id>` 形态的 TMDB ID；动画条目通常为 null。
  final String? tmdbId;

  /// 日文（含汉字假名）名。真人剧的用户输入常是日文原名，服务端模糊搜索也会匹配此字段。
  final String? japaneseName;

  final JimakuEntryFlags flags;
}

/// Jimaku 条目下的一个字幕文件。
class JimakuFile {
  const JimakuFile({
    required this.name,
    required this.url,
    this.size,
  });

  final String name;
  final String url;
  final int? size;

  /// 文件扩展名（小写，不含点）；用于选解析器（srt/ass/vtt）。
  String get extension {
    final int dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  }

  /// 是否可解析成 cue 的文本字幕（srt/ass/ssa/vtt）。
  bool get isTextSubtitle =>
      const <String>{'srt', 'ass', 'ssa', 'vtt'}.contains(extension);

  /// 从文件名启发式解析出的集号（`第01話`/`E01`/`- 12`/`S01E02` 等）；认不出为 null。
  /// 用于把「集数乱序」的候选按集号升序排列（见 [sortJimakuFilesByEpisode]）。
  int? get episode => parseSubtitleEpisode(name);
}

/// 一个 Jimaku 条目下可供 UI 预览的文本字幕清单。
///
/// 合集批量下载弹窗在用户真正点「下载全部」前先列一次条目文件，用这份清单回答两个
/// 关键问题：这个来源到底有什么字幕、合集里的哪几集能精确匹配。只统计 Hibiki 能解析
/// 的文本字幕；压缩包/图片字幕不会被误报成「可用」。
class JimakuFileInventory {
  JimakuFileInventory._(this.files)
      : episodes = <int>{
          for (final JimakuFile file in files)
            if (file.episode != null) file.episode!,
        },
        languages = <String>{
          for (final JimakuFile file in files)
            if (detectSubtitleLanguage(file.name) != null)
              detectSubtitleLanguage(file.name)!,
        },
        unlabeledCount =
            files.where((JimakuFile file) => file.episode == null).length;

  factory JimakuFileInventory.fromFiles(Iterable<JimakuFile> files) {
    return JimakuFileInventory._(
      files
          .where((JimakuFile file) => file.isTextSubtitle)
          .toList(growable: false),
    );
  }

  final List<JimakuFile> files;
  final Set<int> episodes;
  final Set<String> languages;
  final int unlabeledCount;

  List<JimakuFile> filesForEpisode(int episode) => files
      .where((JimakuFile file) => file.episode == episode)
      .toList(growable: false);
}

/// 从字幕文件名启发式解析集号。复用 [parseVideoFilename] 的集号识别规则（`SxxEyy` /
/// CJK `第N話` / `EP/E` / `- N` / 结尾裸数字），但先剥掉字幕扩展名（srt/ass/ssa/vtt）
/// 与可选的语言子标签（`.ja` / `.zh-cn` 等），使 `Show - 12.ja.srt` 这类文件名也能
/// 命中结尾集号（否则 `.srt` 后缀会让「结尾裸数字」规则失配）。纯函数，便于单测。
int? parseSubtitleEpisode(String fileName) {
  String stem = fileName;
  // ① 剥字幕扩展名。
  final int dot = stem.lastIndexOf('.');
  if (dot > 0) {
    final String ext = stem.substring(dot + 1).toLowerCase();
    if (const <String>{'srt', 'ass', 'ssa', 'vtt'}.contains(ext)) {
      stem = stem.substring(0, dot);
    }
  }
  // ② 剥可选的语言子标签（如 `name.ja` / `name.zh-cn`），否则它会被当成系列名尾巴。
  final int dot2 = stem.lastIndexOf('.');
  if (dot2 > 0) {
    final String tail = stem.substring(dot2 + 1);
    if (_languageFromToken(tail) != null) {
      stem = stem.substring(0, dot2);
    }
  }
  return parseVideoFilename(stem).episode;
}

/// 解析 Jimaku entries 响应（JSON 数组）为 [JimakuEntry] 列表。
/// 默认保留历史 fail-open 语义；provider 聚合层用 [strict] 区分「合法空数组」
/// 与损坏响应。
List<JimakuEntry> parseJimakuEntries(String body, {bool strict = false}) {
  try {
    final dynamic json = jsonDecode(body);
    if (json is! List) {
      throw const FormatException('Jimaku entries response is not an array');
    }
    final List<JimakuEntry> out = <JimakuEntry>[];
    for (int index = 0; index < json.length; index++) {
      final dynamic e = json[index];
      if (e is! Map) {
        if (strict) {
          throw FormatException(
              'Jimaku entry at index $index is not an object');
        }
        continue;
      }
      final dynamic id = e['id'];
      if (id is! int) {
        if (strict) {
          throw FormatException(
              'Jimaku entry at index $index has no integer id');
        }
        continue;
      }
      final String primaryName = (e['name'] as String?)?.trim() ?? '';
      final String englishName = (e['english_name'] as String?)?.trim() ?? '';
      final String japaneseName = (e['japanese_name'] as String?)?.trim() ?? '';
      final String tmdbId = (e['tmdb_id'] as String?)?.trim() ?? '';
      out.add(JimakuEntry(
        id: id,
        name: primaryName.isNotEmpty
            ? primaryName
            : englishName.isNotEmpty
                ? englishName
                : japaneseName.isNotEmpty
                    ? japaneseName
                    : '#$id',
        anilistId: e['anilist_id'] as int?,
        tmdbId: tmdbId.isEmpty ? null : tmdbId,
        japaneseName: japaneseName.isEmpty ? null : japaneseName,
        flags: parseJimakuEntryFlags(e['flags']),
      ));
    }
    return out;
  } catch (e, stack) {
    // fail-open：解析失败返回空列表（同旧行为），补 diagnostic 便于排障。
    ErrorLogService.instance
        .logDiagnostic('JimakuClient.parseJimakuEntries', e);
    if (strict) {
      Error.throwWithStackTrace(
        const JimakuRequestException('invalid search response'),
        stack,
      );
    }
    return const <JimakuEntry>[];
  }
}

/// 从字幕文件名识别语言代码（客户端启发式，Jimaku 无服务端语言过滤）。纯函数。
///
/// 识别两类信号，认不出一律返回 `null`（= 未知语言，绝不猜错、绝不藏候选）：
/// 1. `*.<lang>.<ext>` 倒数第二段的语言后缀（asbplayer 同款），如 `ep01.ja.srt`；
/// 2. 文件名里明确的语言标记，如 `[CHS]` / `简体` / `日本語` / `[JP]`。
///
/// 归一到大类语言代码：`ja` / `zh` / `en` / `ko`。其它/认不出 → `null`。
String? detectSubtitleLanguage(String fileName) {
  final String lower = fileName.toLowerCase();

  // ① 倒数第二段后缀（`name.<lang>.<ext>`）。
  final List<String> parts = fileName.split('.');
  if (parts.length >= 3) {
    final String? byTag = _languageFromToken(parts[parts.length - 2]);
    if (byTag != null) return byTag;
  }

  // ② 文件名里的显式语言标记（保守：只认明确标记）。
  const Map<String, String> markers = <String, String>{
    '日本語': 'ja',
    '日语': 'ja',
    '简体': 'zh',
    '簡体': 'zh',
    '繁體': 'zh',
    '繁体': 'zh',
    '中文': 'zh',
    '英語': 'en',
    '英语': 'en',
    '한국어': 'ko',
  };
  for (final MapEntry<String, String> e in markers.entries) {
    if (fileName.contains(e.key)) return e.value;
  }
  // 方括号 / 圆括号语言标记，如 [JP] / [CHS] / (ENG)。
  for (final RegExpMatch m
      in RegExp(r'[\[\(]([a-z\-]{2,5})[\]\)]').allMatches(lower)) {
    final String? byBracket = _languageFromToken(m.group(1)!);
    if (byBracket != null) return byBracket;
  }
  return null;
}

/// 可选的 Jimaku 字幕语言代码（UI 选择器与设置项共用的单一真相源，顺序即展示顺序）。
const List<String> kJimakuLanguageCodes = <String>['ja', 'zh', 'en', 'ko'];

/// 语言代码 → 显示名（chip / 设置项文案）。白名单外回退原代码大写。纯函数。
///
/// 各语言用其母语写法（`日本語` / `中文` / `English` / `한국어`），与 app 界面语言无关，
/// 故不走 i18n；放在数据层供 UI 层（字幕对话框 / 下载对话框 / 设置页）共用。
String jimakuLanguageLabel(String code) {
  switch (code) {
    case 'ja':
      return '日本語';
    case 'zh':
      return '中文';
    case 'en':
      return 'English';
    case 'ko':
      return '한국어';
    default:
      return code.toUpperCase();
  }
}

/// 语言排序权重：优先语言（[preferred]，用户按系列记忆的语言）→ ja → zh → en → ko →
/// 其它/认不出。数字越小越靠前。纯函数（供对话框排序与合集批量挑最佳字幕共用）。
int jimakuLanguageRank(String? language, {String? preferred}) {
  if (preferred != null && language == preferred) return -1;
  switch (language) {
    case 'ja':
      return 0;
    case 'zh':
      return 1;
    case 'en':
      return 2;
    case 'ko':
      return 3;
    default:
      return 4; // 其它语言 / 认不出
  }
}

/// 把单个语言 token（如 `ja`/`chs`/`zh-cn`/`ja[cc]`）归一到大类代码；认不出返回 `null`。
String? _languageFromToken(String rawToken) {
  // 尾部方括号修饰（Netflix 抽轨常见的 `ja[cc]` / `en[sdh]`）不是语言的一部分，
  // 剥掉再查表——否则整批 Netflix CC 日语字幕会被判成「语言未知」，既排不进
  // ja 优先，也筛不到「日本語」。
  final String token = rawToken
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'\[[^\]]*\]$'), '')
      .trim();
  if (token.isEmpty) return null;
  const Map<String, String> table = <String, String>{
    'ja': 'ja',
    'jpn': 'ja',
    'jp': 'ja',
    'zh': 'zh',
    'zho': 'zh',
    'chi': 'zh',
    'chs': 'zh',
    'cht': 'zh',
    'sc': 'zh',
    'tc': 'zh',
    'en': 'en',
    'eng': 'en',
    'ko': 'ko',
    'kor': 'ko',
  };
  // 先整 token 命中（保留 chs/cht 这种连体码），再退到连字符前的主标签
  // （zh-cn → zh，pt-br → pt）。
  final String? whole = table[token];
  if (whole != null) return whole;
  return table[token.split('-').first];
}

/// 解析 Jimaku files 响应（JSON 数组）为 [JimakuFile] 列表。
///
/// 默认沿用历史 fail-open 语义；库存预检查传 [strict] 时，非法 JSON、非数组顶层或
/// 缺少必需 name/url 的元素都属于响应结构失败，必须抛出
/// [JimakuRequestException]，不能与合法空数组混成同一个「零字幕」状态。
List<JimakuFile> parseJimakuFiles(String body, {bool strict = false}) {
  try {
    final dynamic json = jsonDecode(body);
    if (json is! List) {
      throw const FormatException('Jimaku files response is not a JSON array');
    }
    final List<JimakuFile> out = <JimakuFile>[];
    for (int index = 0; index < json.length; index++) {
      final dynamic f = json[index];
      if (f is! Map) {
        if (strict) {
          throw FormatException('Jimaku file at index $index is not an object');
        }
        continue;
      }
      final dynamic name = f['name'];
      final dynamic url = f['url'];
      if (name is! String || url is! String) {
        if (strict) {
          throw FormatException(
            'Jimaku file at index $index is missing name or url',
          );
        }
        continue;
      }
      out.add(JimakuFile(
        name: name,
        url: url,
        size: f['size'] is int ? f['size'] as int : null,
      ));
    }
    return out;
  } catch (e, stack) {
    // fail-open：解析失败返回空列表（同旧行为），补 diagnostic 便于排障。
    ErrorLogService.instance.logDiagnostic('JimakuClient.parseJimakuFiles', e);
    if (strict) {
      Error.throwWithStackTrace(
        const JimakuRequestException('invalid list files response'),
        stack,
      );
    }
    return const <JimakuFile>[];
  }
}

/// Jimaku 请求失败。默认客户端路径仍可 fail-open；需要向用户区分「零结果」与「请求
/// 失败」的界面可通过 `throwOnError: true` 保留这个异常。
class JimakuRequestException implements Exception {
  const JimakuRequestException(
    this.message, {
    this.statusCode,
  });

  final String message;
  final int? statusCode;

  @override
  String toString() {
    final int? status = statusCode;
    return status == null
        ? 'JimakuRequestException: $message'
        : 'JimakuRequestException($status): $message';
  }
}

/// 把一次 Jimaku 失败拼成**用户能据以行动**的一句话：`<基础文案>（HTTP <状态码>）`。
///
/// 纯函数，便于单测。失败原因必须落到 UI 上——401（key 过期/写错）、429（被限流，等会
/// 儿再试）、404（文件下架）对用户是完全不同的三件事，一律显示「下载失败」等于什么都
/// 没说。拿不到状态码（DNS/超时/代理挂了）时原样返回基础文案，不编造细节。
String describeJimakuFailure(String baseMessage, Object? error) {
  if (error is! JimakuRequestException) return baseMessage;
  final int? status = error.statusCode;
  if (status == null) return baseMessage;
  return '$baseMessage（HTTP $status）';
}

/// 构造 `/api/entries/<id>/files` 请求 URI。纯函数，便于单测断言 episode 拼参。
///
/// [episode] 非空时附 `episode=<n>`，否则 URI 不带任何 query（= 旧行为）。
Uri buildListFilesUri(String base, int entryId, {int? episode}) {
  final Uri uri = Uri.parse('$base/entries/$entryId/files');
  if (episode == null) return uri;
  return uri.replace(queryParameters: <String, String>{'episode': '$episode'});
}

/// 构造 `/api/entries/search` 请求 URI。纯函数，便于单测断言分类与检索键拼参。
///
/// [anime] 恒显式拼进 query：服务端缺省 `true`，靠缺省值等于把真人剧永久挡在门外，
/// 所以这里不做「等于缺省就省略」的优化——显式才是可读且可断言的。
Uri buildSearchEntriesUri(
  String base, {
  required bool anime,
  int? anilistId,
  String? tmdbId,
  String? query,
}) {
  final Map<String, String> params = <String, String>{
    'anime': anime ? 'true' : 'false',
    if (anilistId != null) 'anilist_id': '$anilistId',
    if (tmdbId != null && tmdbId.trim().isNotEmpty) 'tmdb_id': tmdbId.trim(),
    if (query != null && query.trim().isNotEmpty) 'query': query,
  };
  return Uri.parse('$base/entries/search').replace(queryParameters: params);
}

/// Jimaku API 客户端（参照 asbplayer 的 Jimaku 集成）。需用户在设置/对话框填 API key。
///
/// 端点：`/api/entries/search`（按 anilist_id 或 query 搜条目）、`/api/entries/<id>/files`
/// （列文件）、文件 `url` 直接下载。鉴权头 `Authorization: <apiKey>`。
class JimakuClient {
  JimakuClient({required this.apiKey, http.Client? client})
      : _client = client ?? createAppHttpIoClient();

  final String apiKey;
  final http.Client _client;

  static const String _base = 'https://jimaku.cc/api';

  Map<String, String> get _headers => <String, String>{
        'Authorization': apiKey,
        'Accept': 'application/json',
      };

  /// 按 AniList id 搜 Jimaku 条目。
  ///
  /// 不开放 scope：AniList ID 是动画专属标识，配 `anime=false` 恒返回空，没有可用取值。
  Future<List<JimakuEntry>> searchByAnilistId(
    int anilistId, {
    bool throwOnError = false,
  }) async {
    return _searchEntries(
      anilistId: anilistId,
      scope: JimakuSearchScope.anime,
      throwOnError: throwOnError,
    );
  }

  /// 按 TMDB ID（`tv:<id>` / `movie:<id>`，见 [jimakuTmdbId]）精确搜条目。
  ///
  /// 真人剧的权威关联键。默认 [JimakuSearchScope.all]：TMDB 既可能挂在真人条目上，也可能
  /// 挂在动画剧场版上，而分类过滤先于 ID 匹配执行，只查一边会漏。
  Future<List<JimakuEntry>> searchByTmdbId(
    String tmdbId, {
    JimakuSearchScope scope = JimakuSearchScope.all,
    bool throwOnError = false,
  }) async {
    if (tmdbId.trim().isEmpty) return const <JimakuEntry>[];
    return _searchEntries(
      tmdbId: tmdbId,
      scope: scope,
      throwOnError: throwOnError,
    );
  }

  /// 按文本搜 Jimaku 条目（AniList 匹配不到时的回退）。
  ///
  /// [scope] 决定搜动画还是真人；缺省 [JimakuSearchScope.anime] = 旧行为。服务端模糊匹配
  /// 覆盖 romaji / 英文 / 日文三种名字，故日文原名可直接作为 [query]。
  Future<List<JimakuEntry>> searchByQuery(
    String query, {
    JimakuSearchScope scope = JimakuSearchScope.anime,
    bool throwOnError = false,
  }) async {
    if (query.trim().isEmpty) return const <JimakuEntry>[];
    return _searchEntries(
      query: query,
      scope: scope,
      throwOnError: throwOnError,
    );
  }

  /// 「先按 AniList id 搜、搜不到再按文本搜」的收敛入口——Jimaku 条目只有被人工挂上
  /// AniList id 时 [searchByAnilistId] 才命中，冷门/非标准来源（如 YouTube 转录番）常
  /// 只有文本条目，故 [anilistId] 空结果必须回退 [queryFallbacks]（依次尝试，首个命中即
  /// 停）。下载对话框与字幕对话框共用此单一真相源，避免某一处漏写回退分支再退化成
  /// 「其实有字幕却报无字幕」。纯委托，便于用 fake [http.Client] 单测。
  Future<List<JimakuEntry>> searchEntries({
    int? anilistId,
    String? tmdbId,
    List<String> queryFallbacks = const <String>[],
    JimakuSearchScope scope = JimakuSearchScope.anime,
    bool throwOnError = false,
  }) async {
    if (anilistId != null && scope != JimakuSearchScope.liveAction) {
      final List<JimakuEntry> byId = await searchByAnilistId(
        anilistId,
        throwOnError: throwOnError,
      );
      if (byId.isNotEmpty) return byId;
    }
    if (tmdbId != null && tmdbId.trim().isNotEmpty) {
      final List<JimakuEntry> byTmdb = await searchByTmdbId(
        tmdbId,
        scope: scope,
        throwOnError: throwOnError,
      );
      if (byTmdb.isNotEmpty) return byTmdb;
    }
    for (final String query in queryFallbacks) {
      if (query.trim().isEmpty) continue;
      final List<JimakuEntry> byQuery = await searchByQuery(
        query,
        scope: scope,
        throwOnError: throwOnError,
      );
      if (byQuery.isNotEmpty) return byQuery;
    }
    return const <JimakuEntry>[];
  }

  /// 单次或多次（[JimakuSearchScope.all]）请求 `/entries/search` 并按条目 id 去重合并。
  ///
  /// 保序：先请求的分类排前（`all` 时动画在前、真人在后），同 id 只保留首次出现，服务端
  /// 已按模糊匹配得分降序返回，合并不会打乱各自内部次序。
  Future<List<JimakuEntry>> _searchEntries({
    required JimakuSearchScope scope,
    required bool throwOnError,
    int? anilistId,
    String? tmdbId,
    String? query,
  }) async {
    try {
      final List<JimakuEntry> merged = <JimakuEntry>[];
      final Set<int> seen = <int>{};
      for (final bool anime in jimakuScopeAnimeFlags(scope)) {
        final Uri uri = buildSearchEntriesUri(
          _base,
          anime: anime,
          anilistId: anilistId,
          tmdbId: tmdbId,
          query: query,
        );
        final http.Response res = await _client.get(uri, headers: _headers);
        if (res.statusCode != 200) {
          if (throwOnError) {
            throw JimakuRequestException(
              'search entries failed',
              statusCode: res.statusCode,
            );
          }
          continue;
        }
        final List<JimakuEntry> page = parseJimakuEntries(
          utf8.decode(res.bodyBytes, allowMalformed: true),
          strict: throwOnError,
        );
        for (final JimakuEntry entry in page) {
          if (seen.add(entry.id)) merged.add(entry);
        }
      }
      return merged;
    } catch (e, stack) {
      // fail-open：预期可失败的网络路径，返回空列表（同旧行为），补 diagnostic。
      ErrorLogService.instance.logDiagnostic('JimakuClient.searchEntries', e);
      if (throwOnError) Error.throwWithStackTrace(e, stack);
      return const <JimakuEntry>[];
    }
  }

  /// 列某条目下的字幕文件。
  ///
  /// [episode] 非空时附 `episode=<n>` query，由 Jimaku 服务端**按文件名启发式**只返回
  /// 匹配该集的文件（文档原文：best-effort guess based off filename matching）；为空时
  /// 不带该 query，行为 = 旧路径（列全部文件，向后兼容）。
  Future<List<JimakuFile>> listFiles(
    int entryId, {
    int? episode,
    bool throwOnError = false,
  }) async {
    try {
      final Uri uri = buildListFilesUri(_base, entryId, episode: episode);
      final http.Response res = await _client.get(uri, headers: _headers);
      if (res.statusCode != 200) {
        if (throwOnError) {
          throw JimakuRequestException(
            'list files for entry $entryId failed',
            statusCode: res.statusCode,
          );
        }
        return const <JimakuFile>[];
      }
      return parseJimakuFiles(
        utf8.decode(res.bodyBytes, allowMalformed: true),
        strict: throwOnError,
      );
    } catch (e, stack) {
      // fail-open：预期可失败的网络路径，返回空列表（同旧行为），补 diagnostic。
      ErrorLogService.instance.logDiagnostic('JimakuClient.listFiles', e);
      if (throwOnError) Error.throwWithStackTrace(e, stack);
      return const <JimakuFile>[];
    }
  }

  /// 下载 [fileUrl] 的字节；失败返回 null。
  Future<Uint8List?> downloadFile(
    String fileUrl, {
    bool throwOnError = false,
  }) async {
    try {
      final http.Response res =
          await _client.get(Uri.parse(fileUrl), headers: _headers);
      if (res.statusCode != 200) {
        if (throwOnError) {
          throw JimakuRequestException(
            'subtitle download failed',
            statusCode: res.statusCode,
          );
        }
        return null;
      }
      return res.bodyBytes;
    } catch (e, stack) {
      // fail-open：预期可失败的网络路径，返回 null（同旧行为），补 diagnostic。
      ErrorLogService.instance.logDiagnostic('JimakuClient.downloadFile', e);
      if (throwOnError) Error.throwWithStackTrace(e, stack);
      return null;
    }
  }

  void close() => _client.close();
}
