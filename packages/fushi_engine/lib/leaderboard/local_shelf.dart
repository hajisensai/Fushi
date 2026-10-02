// 本机书架汇总：把本地库 + 统计事实面折成排行榜的上报形状（设计 §3.2 / §3.3）。
//
// 数据来源（只读，一次性全表读，库规模是几千行量级）：
// - 字数 / 时长：`loadStatFacts(profileId:)` 的日面事实，按 (mediaKind, mediaKey) 汇总。
//   legacy 无身份行（mediaKey 为空）不归入任何作品，只进每日字数。
// - 书 / 漫画：`epub_books`（format manga → 漫画），读完 = completedAt 非空。
// - 视频：作品单位 = 刮削作品（剧 = collectionId，电影 = bookUid），无作品则按主合集，
//   再无则单个视频；电影读完 = 单位内全部成员都有 completedAt；剧集读完 = 同一作品身份
//   的全部单元合起来，季集骨架里每个正片集都有看完的本地文件（没骨架时只认合集单元的
//   全部成员看完）——服务端合并同一作品取「任一读完」，只看完一集不能让整部剧读完。**只上报经外部资料源刮削过
//   的作品**（作品上有非 local 的 provider 身份）：否则标题只能是文件名 / 合集名，既会
//   当公开标题泄露，弱键 `t:` 又会把所有人的「Season 1」并成一部。
// - 游戏：`galgames`，playStatus 2 = 玩过（读完），3 = 在玩。与视频同口径**只上报刮削过
//   的游戏**（有 bgm / vndb 身份）：否则标题只能是本地 exe 推出来的库名。
//
// nsfw（服务端据此模糊封面；nsfw 条目也不补传本地封面缩略图，见 leaderboard_sync）只用
// 本机真实存了的信号：游戏 = 覆盖层 / bgm / vndb 的 `nsfw`；在线漫画 / 在线视频 = 所属
// Mihon / Aniyomi 扩展的 `manga_extensions.contentWarning`（仓库索引给的，3 = NSFW；
// 只有扩展级、没有源级分级）；刮削视频 = 作品 `contentRating` 成人向（AniDB restricted →
// `R18+`、MAL `Rx - Hentai`）。拿不到信号的条目为 false。
//
// 书 / 视频 / 游戏的库表本身不分 Profile（与库页口径一致），只有统计按 Profile 隔离。
// Profile 口径：只有一个 Profile 时上传全部读完 / 在读的作品；有多个 Profile 时**别的
// Profile 有学习记录、本 Profile 没有**的作品不上传——别的 Profile 读完的书不算到本账户
// 上。哪个 Profile 都没有记录的作品（标记读完但没留统计、早于统计域的老书）归不到任何
// 一个 Profile 名下，照常上传（BUG-2870：此前多建一个 Profile 就把这些书全丢了）。
//
// 服务端 normalizeEntry 对单条坏数据会 400 拒掉**整批**，所以这里按同一口径先把形状
// 修好或丢掉（[sanitizeFinishedAt] / [sanitizeShelfText]），丢掉的记日志。

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/leaderboard/leaderboard_models.dart';
import 'package:fushi_engine/leaderboard/work_refs.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi_engine/sync/online_novel_book.dart';

/// 书架上的一条本地作品。[localKey] 是本机稳定身份（`book:<bookKey>` /
/// `video:c<collectionId>` / `video:b<bookUid>` / `game:<id>`），同步状态按它记账。
class LocalShelfEntry {
  const LocalShelfEntry({
    required this.localKey,
    required this.upload,
    this.localCoverPath,
    this.lastActiveAt,
  });

  final String localKey;
  final ShelfEntryUpload upload;

  /// 本地封面文件（服务端缺封面时据此生成缩略图补传）。
  final String? localCoverPath;

  /// 本 Profile 最后一次学习活动的时刻（毫秒）；没有记录为 null。书架超过服务端上限时
  /// 按它（与读完时刻）取舍。
  final int? lastActiveAt;
}

class LocalShelf {
  const LocalShelf({
    required this.entries,
    required this.daily,
    this.dailyFrom,
  });

  static const LocalShelf empty = LocalShelf(
    entries: <LocalShelfEntry>[],
    daily: <DailyCharsUpload>[],
  );

  /// 服务端接受的最早日期（含，`YYYY-MM-DD`；服务端只收最近 3650 天）。[daily] 已按它
  /// 过滤；同步时早于它的旧日期不发删除（会被 400），只从本地状态里忘掉。null = 不限。
  final String? dailyFrom;

  /// 按 [LocalShelfEntry.localKey] 升序。
  final List<LocalShelfEntry> entries;

  /// 每日全部种类的字数之和（只含 > 0 的日期），按日期升序。
  final List<DailyCharsUpload> daily;
}

/// 汇总 [profileId] 的本机书架。
///
/// [now] 应是**服务器时刻**（app 传按 `Date` 头校准过的时钟；测试注入）：读完时刻的上界
/// 与每日字数窗口都按它算。每日字数只保留服务端接受的窗口 [leaderboardDailyFrom] ..
/// [leaderboardDailyTo]（更早的服务端判 too_old、更晚的判 future，都会拒收整批）。
///
/// [countsUnattributed]：本机没有任何 Profile 有学习记录的作品（同机 Profile 共享的库里
/// 只有读完标记的那些）是否由本 Profile 计入作品读者数。同机每个开了上传的 Profile 都会
/// 报这类作品；只让其中一个（[leaderboardUnattributedOwner]）计入，其余带
/// `counted: false` 上报，作品读者数才不会按 Profile 个数重复（BUG-2870）。
Future<LocalShelf> buildLocalShelf(
  FushiDatabase db, {
  required int profileId,
  DateTime? now,
  bool countsUnattributed = true,
}) async {
  final DateTime at = now ?? DateTime.now();
  final String dailyFrom = leaderboardDailyFrom(at);
  final String dailyTo = leaderboardDailyTo(at);
  final StatFacts facts = await loadStatFacts(
    db,
    activityLimit: 0,
    profileId: profileId,
  );
  final _ShelfBuild build = _ShelfBuild(
    totals: _Totals.fromFacts(facts.daily),
    otherProfiles: await _otherProfileMedia(db, profileId),
    nowMs: at.millisecondsSinceEpoch,
    nsfwExtensions: await _nsfwExtensionPackages(db),
    countsUnattributed: countsUnattributed,
  );
  final List<LocalShelfEntry> entries =
      <LocalShelfEntry>[
        ...await _bookEntries(db, build),
        ...await _videoEntries(db, build),
        ...await _gameEntries(db, build),
      ]..sort(
        (LocalShelfEntry a, LocalShelfEntry b) =>
            a.localKey.compareTo(b.localKey),
      );
  build.logSkipped();
  return LocalShelf(
    entries: List<LocalShelfEntry>.unmodifiable(entries),
    daily: List<DailyCharsUpload>.unmodifiable(
      build.totals.dailyUploads().where(
        (DailyCharsUpload d) =>
            d.date.compareTo(dailyFrom) >= 0 && d.date.compareTo(dailyTo) <= 0,
      ),
    ),
    dailyFrom: dailyFrom,
  );
}

/// 服务端每日字数只收最近这么多天（shelf.js `DAILY_WINDOW_DAYS`）。
const int kLeaderboardDailyWindowDays = 3650;

/// 服务端读完时刻的下界（shelf.js `EARLIEST_MS`，2000-01-01 UTC）。
final int kLeaderboardEarliestFinishMs = DateTime.utc(
  2000,
).millisecondsSinceEpoch;

/// 服务端读完时刻比服务器时刻最多超前这么多（shelf.js `now + 5 分钟`）。
const Duration kLeaderboardFinishSkew = Duration(minutes: 5);

/// 单条匹配键个数上限（shelf.js `MAX_REFS` = 命名空间数）。
const int kLeaderboardMaxRefs = 8;

/// 标题 / 作者上限（shelf.js `str(e.title, 300)` / `str(e.author, 200)`）。
const int kLeaderboardMaxTitle = 300;
const int kLeaderboardMaxAuthor = 200;

/// 服务端接受的最早每日字数日期：UTC 的 now − 3649 天（比服务端的 3650 天少一天，
/// 给请求在途与时钟误差留余量；按天数算，闰年不会让窗口多出一两天）。
String leaderboardDailyFrom(DateTime now) => _dateKey(
  now.toUtc().subtract(const Duration(days: kLeaderboardDailyWindowDays - 1)),
);

/// 服务端接受的最晚每日字数日期：UTC 的 now + 36 小时所在日（shelf.js 同口径；本地日
/// 最多比 UTC 快一天，总落在其内）。
String leaderboardDailyTo(DateTime now) =>
    _dateKey(now.toUtc().add(const Duration(hours: 36)));

/// 读完时刻按服务端口径校验：早于 2000-01-01 或晚于 [nowMs] + 5 分钟（坏时钟 / 坏数据）
/// 返回 null——调用方降级为「读完、日期未知」（只进总榜），绝不能让它 400 掉整批。
int? sanitizeFinishedAt(int? finishedAt, int nowMs) {
  if (finishedAt == null) return null;
  if (finishedAt < kLeaderboardEarliestFinishMs ||
      finishedAt > nowMs + kLeaderboardFinishSkew.inMilliseconds) {
    return null;
  }
  return finishedAt;
}

final RegExp _serverControlChars = RegExp(r'[\u0000-\u001f]');

/// 标题 / 作者按服务端 `str()` 同口径规范：控制字符换空格、去首尾空白、截到 [max] 个
/// UTF-16 码元（不劈开代理对）。结果为空时标题会被服务端 400，调用方据此丢弃条目。
String sanitizeShelfText(String s, int max) {
  final String t = s.replaceAll(_serverControlChars, ' ').trim();
  if (t.length <= max) return t;
  int end = max;
  final int last = t.codeUnitAt(end - 1);
  if (last >= 0xd800 && last <= 0xdbff) end--;
  return t.substring(0, end).trim();
}

/// 仓库索引的扩展分级「NSFW」（`mihon_extension_store_client` 的 contentWarning 口径：
/// 0 未知 / 1 SAFE / 2 MIXED / 3 NSFW；扩展页同样按 ≥ 3 判 NSFW）。
const int kMangaExtensionContentWarningNsfw = 3;

/// 刮削作品分级是否成人向：MAL / Jikan `Rx - Hentai`、AniDB `restricted` 映射的 `R18+`；
/// `R+ - Mild Nudity` 不算。与 `VideoSourceScrapeCoordinator.isAdultContentRating` 同口径
/// （那边标了 @visibleForTesting，不能从这里调用）。
bool isAdultVideoContentRating(String? contentRating) {
  final String rating = (contentRating ?? '').trim().toUpperCase();
  return rating.startsWith('RX') || rating.startsWith('R18');
}

/// 同机代表 Profile：在仍存在的 Profile（[existing]）里、开着上传的（[uploading]：有账户、
/// 同意上传、没被别的设备顶掉）取 id 最小的那个。只有它让「哪个 Profile 都没有学习记录」
/// 的作品计入作品读者数（BUG-2870）。没有任何候选时返回 null，调用方按「自己就是代表」
/// 处理——正在上传的 Profile 本身就是候选，null 只出现在账户文件读不到的退化情形。
int? leaderboardUnattributedOwner({
  required Iterable<int> uploading,
  required Iterable<int> existing,
}) {
  final Set<int> alive = existing.toSet();
  int? owner;
  for (final int id in uploading) {
    if (alive.contains(id) && (owner == null || id < owner)) owner = id;
  }
  return owner;
}

/// 别的 Profile 有学习记录的媒体（`mediaKind|mediaKey`）；只有一个 Profile 时为空集。
/// 与本 Profile 同一口径（[loadStatFacts] 的日面事实），只是换个 profileId。
Future<Set<String>> _otherProfileMedia(FushiDatabase db, int profileId) async {
  final Set<String> media = <String>{};
  for (final ProfileRow p in await db.select(db.profiles).get()) {
    if (p.id == profileId) continue;
    final StatFacts facts = await loadStatFacts(
      db,
      activityLimit: 0,
      profileId: p.id,
    );
    for (final StatFact f in facts.daily) {
      if (f.mediaKey.isNotEmpty) media.add('${f.mediaKind}|${f.mediaKey}');
    }
  }
  return media;
}

/// 分级为 NSFW 的已装扩展包名（漫画 / 视频扩展共表）。
Future<Set<String>> _nsfwExtensionPackages(FushiDatabase db) async => <String>{
  for (final MangaExtensionRow e in await db.getMangaExtensions())
    if (e.contentWarning >= kMangaExtensionContentWarningNsfw) e.packageName,
};

/// 一次汇总的共享上下文：统计汇总、服务器时刻、Profile 口径、NSFW 扩展与被丢弃条目的
/// 记账。
class _ShelfBuild {
  _ShelfBuild({
    required this.totals,
    required this.otherProfiles,
    required this.nowMs,
    required this.nsfwExtensions,
    required this.countsUnattributed,
  });

  final _Totals totals;
  final int nowMs;

  /// 别的 Profile 有学习记录的媒体（`mediaKind|mediaKey`），见 [_otherProfileMedia]。
  final Set<String> otherProfiles;

  /// 分级为 NSFW 的扩展包名。
  final Set<String> nsfwExtensions;

  /// 见 [buildLocalShelf] 的同名参数。
  final bool countsUnattributed;

  bool isNsfwExtension(String? packageName) =>
      packageName != null && nsfwExtensions.contains(packageName);

  final List<String> _skipped = <String>[];

  /// 这部作品（的任一成员）是否归别的 Profile：本 Profile 没有学习记录、别的 Profile
  /// 有。两边都没有记录的作品不归任何 Profile，不算别人的。
  bool belongsToOtherProfile(String mediaKind, Iterable<String> mediaKeys) =>
      !mediaKeys.any((String k) => totals.has(mediaKind, k)) &&
      mediaKeys.any((String k) => otherProfiles.contains('$mediaKind|$k'));

  /// 这部作品是否计入作品读者数：有学习记录的作品归本 Profile（归别人的已在
  /// [belongsToOtherProfile] 处跳过），照常计入；哪个 Profile 都没有记录的作品由同机
  /// 代表 Profile 计入，见 [countsUnattributed]。
  bool counts(String mediaKind, Iterable<String> mediaKeys) =>
      countsUnattributed ||
      mediaKeys.any(
        (String k) =>
            totals.has(mediaKind, k) || otherProfiles.contains('$mediaKind|$k'),
      );

  void skip(String localKey, String reason) =>
      _skipped.add('$localKey($reason)');

  void logSkipped() {
    if (_skipped.isEmpty) return;
    engineLog.logDiagnostic(
      'buildLocalShelf',
      'skipped ${_skipped.length} shelf entries the server would reject: '
          '${_skipped.take(20).join(', ')}'
          '${_skipped.length > 20 ? ', …' : ''}',
    );
  }
}

// ---------------------------------------------------------------------------
// 统计汇总

final RegExp _dateKeyShape = RegExp(r'^\d{4}-\d{2}-\d{2}$');

class _Totals {
  _Totals._(this._byMedia, this._lastActive, this._charsByDate);

  factory _Totals.fromFacts(List<StatFact> facts) {
    final Map<String, (int, int)> byMedia = <String, (int, int)>{};
    final Map<String, int> lastActive = <String, int>{};
    final Map<String, int> charsByDate = <String, int>{};
    for (final StatFact f in facts) {
      if (f.chars > 0) {
        charsByDate[f.dateKey] = (charsByDate[f.dateKey] ?? 0) + f.chars;
      }
      if (f.mediaKey.isEmpty) continue;
      final String key = '${f.mediaKind}|${f.mediaKey}';
      final (int chars, int ms) old = byMedia[key] ?? (0, 0);
      byMedia[key] = (old.$1 + f.chars, old.$2 + f.ms);
      if (f.lastActiveMs > (lastActive[key] ?? 0)) {
        lastActive[key] = f.lastActiveMs;
      }
    }
    return _Totals._(byMedia, lastActive, charsByDate);
  }

  final Map<String, (int, int)> _byMedia;
  final Map<String, int> _lastActive;
  final Map<String, int> _charsByDate;

  /// (chars, ms)；负值（坏数据）夹到 0。
  (int, int) of(String mediaKind, String mediaKey) {
    final (int chars, int ms) v = _byMedia['$mediaKind|$mediaKey'] ?? (0, 0);
    return (v.$1 < 0 ? 0 : v.$1, v.$2 < 0 ? 0 : v.$2);
  }

  /// 有没有这件媒体的学习记录（哪怕字数 / 时长为 0）。
  bool has(String mediaKind, String mediaKey) =>
      _byMedia.containsKey('$mediaKind|$mediaKey');

  /// 这件媒体最后活跃时刻（毫秒）；没有记录为 null。
  int? lastActive(String mediaKind, String mediaKey) =>
      _lastActive['$mediaKind|$mediaKey'];

  List<DailyCharsUpload> dailyUploads() {
    final List<String> dates =
        _charsByDate.keys
            .where(
              (String d) => _dateKeyShape.hasMatch(d) && _charsByDate[d]! > 0,
            )
            .toList()
          ..sort();
    return <DailyCharsUpload>[
      for (final String d in dates)
        DailyCharsUpload(date: d, chars: _charsByDate[d]!),
    ];
  }
}

// ---------------------------------------------------------------------------
// 共用

/// 本地日 `YYYY-MM-DD`。
String _localDate(int ms) => _dateKey(DateTime.fromMillisecondsSinceEpoch(ms));

String _dateKey(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year.toString().padLeft(4, '0')}-${two(t.month)}-${two(t.day)}';
}

String? _nonEmpty(String? s) {
  final String? v = s?.trim();
  return v == null || v.isEmpty ? null : v;
}

String? _httpUrl(String? s) {
  final String? v = _nonEmpty(s);
  if (v == null) return null;
  final Uri? u = Uri.tryParse(v);
  if (u == null || (u.scheme != 'http' && u.scheme != 'https')) return null;
  return v;
}

Map<String, Object?>? _jsonObject(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  try {
    final Object? decoded = jsonDecode(raw);
    return decoded is Map<Object?, Object?>
        ? decoded.cast<String, Object?>()
        : null;
  } on FormatException {
    return null;
  }
}

/// 组装一条上报，形状按服务端 normalizeEntry 同口径修正：标题 / 作者去控制字符并截断，
/// 越界的读完时刻降级为「读完、日期未知」。refs 为空或标题规范后为空（服务端必 400）
/// 时返回 null 并记账。
LocalShelfEntry? _entry(
  _ShelfBuild build, {
  required String localKey,
  required LeaderboardKind kind,
  required List<String> refs,
  required String title,
  String author = '',
  String? coverUrl,
  bool nsfw = false,
  required bool finished,
  int? finishedAt,
  required int chars,
  required int ms,
  String? localCoverPath,
  int? lastActiveAt,
  bool counted = true,
}) {
  final String cleanTitle = sanitizeShelfText(title, kLeaderboardMaxTitle);
  if (refs.isEmpty || refs.length > kLeaderboardMaxRefs) {
    build.skip(localKey, 'refs');
    return null;
  }
  if (cleanTitle.isEmpty) {
    build.skip(localKey, 'title');
    return null;
  }
  final int? at = sanitizeFinishedAt(finishedAt, build.nowMs);
  if (at != finishedAt) build.skip(localKey, 'finishedAt→unknown');
  return LocalShelfEntry(
    localKey: localKey,
    localCoverPath: _nonEmpty(localCoverPath),
    lastActiveAt: lastActiveAt,
    upload: ShelfEntryUpload(
      kind: kind,
      refs: refs,
      title: cleanTitle,
      author: sanitizeShelfText(author, kLeaderboardMaxAuthor),
      coverUrl: coverUrl,
      nsfw: nsfw,
      finished: finished,
      finishedAt: at,
      finishedDate: at == null ? null : _localDate(at),
      chars: chars,
      ms: ms,
      counted: counted,
    ),
  );
}

// ---------------------------------------------------------------------------
// 书 / 漫画

/// 在线漫画描述符的类型标记（app 侧 `OnlineMangaLibraryEntry.marker` /
/// `legacyMihonMarker`）。值已写进用户库的 `sourceMetadata`，永不会变。
const String _onlineMangaMarker = 'hibiki-online-manga';
const String _legacyMihonMarker = 'hibiki-mihon';

/// 互联对端被当成漫画源时的运行时标记：它的作品 key 是对端 bookKey（本机局域身份），
/// 不是跨用户可比的源内身份，不产 `src:` 键。
const String _interconnectRuntime = 'interconnect';

/// `sourceMetadata` 里排行榜要用的三样：`src:` 键体、远端封面 URL、所属扩展包名。
typedef _SourceInfo = ({String? ref, String? cover, String? extensionPackage});

const _SourceInfo _noSource = (ref: null, cover: null, extensionPackage: null);

/// `sourceMetadata` → [_SourceInfo]。
///
/// - 在线漫画：`<sourceId>:<series.key>`（v2/v3 描述符；v1 旧 Mihon 描述符为
///   `<sourceId>:<manga.url>`），封面取 series.coverUrl / manga.thumbnail_url，扩展包名
///   取 `extensionPackage`（Aidoku 描述符的包不在扩展表里，查不到分级 → 不算 nsfw）；
/// - LNReader 在线小说：`<pluginId>:<novelPath>`，无远端封面、无扩展。
/// 其余（普通导入书、描述符损坏）全为 null。互联对端当漫画源时没有 `src:` 键。
_SourceInfo _sourceInfo(String? sourceMetadata) {
  final Map<String, Object?>? j = _jsonObject(sourceMetadata);
  if (j == null) return _noSource;
  final Object? type = j['type'];
  if (type == kLnReaderOnlineBookMarker) {
    final String? plugin = _nonEmpty(j['pluginId']?.toString());
    final String? path = _nonEmpty(j['novelPath']?.toString());
    return (
      ref: plugin == null || path == null ? null : '$plugin:$path',
      cover: null,
      extensionPackage: null,
    );
  }
  final Object? series = type == _onlineMangaMarker
      ? j['series']
      : (type == _legacyMihonMarker ? j['manga'] : null);
  if (series is! Map<Object?, Object?>) return _noSource;
  if (j['runtime']?.toString() == _interconnectRuntime) return _noSource;
  final String? sourceId = _nonEmpty(j['sourceId']?.toString());
  final String? key = _nonEmpty(
    (type == _onlineMangaMarker ? series['key'] : series['url'])?.toString(),
  );
  final String? cover = _httpUrl(
    (series['coverUrl'] ?? series['thumbnail_url'])?.toString(),
  );
  return (
    ref: sourceId == null || key == null ? null : '$sourceId:$key',
    cover: cover,
    extensionPackage: _nonEmpty(j['extensionPackage']?.toString()),
  );
}

Future<List<LocalShelfEntry>> _bookEntries(
  FushiDatabase db,
  _ShelfBuild build,
) async {
  final _Totals totals = build.totals;
  final $EpubBooksTable t = db.epubBooks;
  final List<TypedResult> rows =
      await (db.selectOnly(t)..addColumns(<Expression<Object>>[
            t.bookKey,
            t.title,
            t.author,
            t.coverPath,
            t.format,
            t.completedAt,
            t.isbn,
            t.sourceMetadata,
          ]))
          .get();
  final Map<String, int> bangumi = await _bangumiSubjects(
    db,
    'book', // TrackingMediaType.book.value
  );
  final List<LocalShelfEntry> out = <LocalShelfEntry>[];
  for (final TypedResult row in rows) {
    final String bookKey = row.read(t.bookKey)!;
    final DateTime? completedAt = row.read(t.completedAt);
    final (int chars, int ms) = totals.of(kActivityMediaBook, bookKey);
    if (completedAt == null && chars <= 0 && ms <= 0) continue;
    if (build.belongsToOtherProfile(kActivityMediaBook, <String>[bookKey])) {
      continue;
    }
    final String title = _nonEmpty(row.read(t.title)) ?? bookKey;
    final String author = _nonEmpty(row.read(t.author)) ?? '';
    final _SourceInfo source = _sourceInfo(row.read(t.sourceMetadata));
    final int? subject = bangumi[bookKey];
    final LocalShelfEntry? e = _entry(
      build,
      localKey: 'book:$bookKey',
      kind: row.read(t.format) == BookFormat.manga.dbValue
          ? LeaderboardKind.manga
          : LeaderboardKind.book,
      refs: buildWorkRefs(
        bgmSubjectId: subject == null ? null : '$subject',
        isbn: row.read(t.isbn),
        sourceRef: source.ref,
        title: title,
        author: author,
      ),
      title: title,
      author: author,
      coverUrl: source.cover,
      nsfw: build.isNsfwExtension(source.extensionPackage),
      finished: completedAt != null,
      finishedAt: completedAt?.millisecondsSinceEpoch,
      counted: build.counts(kActivityMediaBook, <String>[bookKey]),
      chars: chars,
      ms: ms,
      localCoverPath: row.read(t.coverPath),
      lastActiveAt: totals.lastActive(kActivityMediaBook, bookKey),
    );
    if (e != null) out.add(e);
  }
  return out;
}

/// Bangumi 追踪映射：mediaKey → subjectId（[mediaType] = `TrackingMediaType.value`）。
Future<Map<String, int>> _bangumiSubjects(
  FushiDatabase db,
  String mediaType,
) async {
  final List<MediaTrackingMappingRow> rows =
      await (db.select(db.mediaTrackingMappings)..where(
            ($MediaTrackingMappingsTable m) =>
                m.provider.equals('bangumi') & m.mediaType.equals(mediaType),
          ))
          .get();
  return <String, int>{
    for (final MediaTrackingMappingRow r in rows)
      if (r.subjectId > 0) r.mediaKey: r.subjectId,
  };
}

// ---------------------------------------------------------------------------
// 视频

const String _collectionMediaVideo = 'video';

class _VideoUnit {
  _VideoUnit(this.localKey, this.work);

  final String localKey;
  final VideoMetadataWorkRow? work;
  final List<VideoBookRow> members = <VideoBookRow>[];
  int? collectionId;
}

Future<List<LocalShelfEntry>> _videoEntries(
  FushiDatabase db,
  _ShelfBuild build,
) async {
  final List<VideoBookRow> videos = await db.select(db.videoBooks).get();
  if (videos.isEmpty) return const <LocalShelfEntry>[];
  final List<VideoMetadataWorkRow> works = await db.getAllVideoMetadataWorks();
  final Map<String, VideoMetadataWorkRow> workByBook =
      <String, VideoMetadataWorkRow>{
        for (final VideoMetadataWorkRow w in works)
          if (w.bookUid != null) w.bookUid!: w,
      };
  final Map<int, VideoMetadataWorkRow> workByCollection =
      <int, VideoMetadataWorkRow>{
        for (final VideoMetadataWorkRow w in works)
          if (w.collectionId != null) w.collectionId!: w,
      };
  // 视频 → 它所在的全部合集（升序）：有刮削作品的合集优先当作品单位。
  final Map<String, List<int>> collectionsOf = <String, List<int>>{};
  for (final MediaCollectionItemRow item in await db.getAllCollectionItems()) {
    if (item.mediaType != _collectionMediaVideo) continue;
    (collectionsOf[item.entryKey] ??= <int>[]).add(item.collectionId);
  }
  final Map<String, int> primaryCollection = await db
      .getPrimaryCollectionIdByEntry();
  final Map<int, MediaCollectionRow> collections = <int, MediaCollectionRow>{
    for (final MediaCollectionRow c in await db.getAllMediaCollections())
      c.id: c,
  };

  final Map<String, _VideoUnit> units = <String, _VideoUnit>{};
  _VideoUnit unitFor(String localKey, VideoMetadataWorkRow? work) =>
      units[localKey] ??= _VideoUnit(localKey, work);

  for (final VideoBookRow v in videos) {
    final VideoMetadataWorkRow? movie = workByBook[v.bookUid];
    final List<int> memberOf = (collectionsOf[v.bookUid] ?? <int>[])..sort();
    final int? scrapedCollection = memberOf
        .where((int c) => workByCollection.containsKey(c))
        .firstOrNull;
    final int? collectionId = movie != null
        ? null
        : scrapedCollection ??
              primaryCollection['$_collectionMediaVideo|${v.bookUid}'];
    final _VideoUnit unit = collectionId == null
        ? unitFor('video:b${v.bookUid}', movie)
        : (unitFor('video:c$collectionId', workByCollection[collectionId])
            ..collectionId = collectionId);
    unit.members.add(v);
  }

  final Map<int, List<VideoMetadataProviderIdentityRow>> identities =
      await _videoWorkIdentities(db);
  final Map<int, String> posters = await _videoWorkPosters(db);
  final Map<int, List<_EpisodeSlot>> episodes = await _videoWorkEpisodes(db);
  final Map<String, DateTime?> completedAt = <String, DateTime?>{
    for (final VideoBookRow v in videos) v.bookUid: v.completedAt,
  };

  final List<_VideoCandidate> candidates = <_VideoCandidate>[];
  for (final _VideoUnit unit in units.values) {
    if (build.belongsToOtherProfile(
      kActivityMediaVideo,
      unit.members.map((VideoBookRow m) => m.bookUid),
    )) {
      continue;
    }
    final VideoMetadataWorkRow? work = unit.work;
    final _VideoRefs ids = _VideoRefs.of(
      work,
      work == null
          ? const <VideoMetadataProviderIdentityRow>[]
          : identities[work.id] ?? const <VideoMetadataProviderIdentityRow>[],
    );
    // 没刮削过（无作品，或只有本地索引出的临时作品）：标题只能是文件名 / 合集名，不上报。
    if (!ids.scraped) continue;
    final String? scrapedTitle = _nonEmpty(work?.title);
    candidates.add(
      _VideoCandidate(
        unit,
        ids,
        buildWorkRefs(
          bgmSubjectId: ids.bgm,
          anidbAid: ids.anidb,
          malId: ids.mal,
          tmdbRef: ids.tmdb,
          title: scrapedTitle ?? '',
        ),
        scrapedTitle,
      ),
    );
  }

  // 「读完」是作品级事实：服务端把映射到同一作品的条目合并时取「任一读完」，所以每条
  // 上报的 finished 必须代表整部作品。剧集按作品身份分组，组内按季集骨架统一判定。
  final Map<String, List<_VideoCandidate>> groups =
      <String, List<_VideoCandidate>>{};
  for (final _VideoCandidate c in candidates) {
    (groups[c.groupKey] ??= <_VideoCandidate>[]).add(c);
  }
  final List<LocalShelfEntry> out = <LocalShelfEntry>[];
  for (final List<_VideoCandidate> group in groups.values) {
    final int? finishedAt = group.first.isSeries
        ? _seriesFinishedAt(group, episodes, completedAt)
        : _allCompletedAt(group.single.unit.members);
    final bool finished = finishedAt != null;
    for (final _VideoCandidate c in group) {
      final LocalShelfEntry? e = _videoEntry(
        build,
        c,
        finished: finished,
        finishedAt: finishedAt,
        cover: c.unit.work == null ? null : posters[c.unit.work!.id],
        collections: collections,
      );
      if (e != null) out.add(e);
    }
  }
  return out;
}

LocalShelfEntry? _videoEntry(
  _ShelfBuild build,
  _VideoCandidate c, {
  required bool finished,
  required int? finishedAt,
  required String? cover,
  required Map<int, MediaCollectionRow> collections,
}) {
  final _Totals totals = build.totals;
  final _VideoUnit unit = c.unit;
  int chars = 0;
  int ms = 0;
  for (final VideoBookRow m in unit.members) {
    final (int ch, int t) = totals.of(kActivityMediaVideo, m.bookUid);
    chars += ch;
    ms += t;
  }
  if (!finished && chars <= 0 && ms <= 0) return null;
  final MediaCollectionRow? collection = unit.collectionId == null
      ? null
      : collections[unit.collectionId];
  return _entry(
    build,
    localKey: unit.localKey,
    kind: LeaderboardKind.video,
    refs: c.refs,
    // 刮削作品没有标题时用它的资料源键占位（服务端按众数取别人的标题展示）。
    title: c.scrapedTitle ?? c.ids.fallbackTitle,
    coverUrl: cover,
    nsfw:
        isAdultVideoContentRating(unit.work?.contentRating) ||
        unit.members.any(
          (VideoBookRow m) =>
              build.isNsfwExtension(_animeSourceExtension(m.streamSpecJson)),
        ),
    finished: finished,
    finishedAt: finished ? finishedAt : null,
    chars: chars,
    ms: ms,
    counted: build.counts(
      kActivityMediaVideo,
      unit.members.map((VideoBookRow m) => m.bookUid),
    ),
    localCoverPath:
        _nonEmpty(collection?.coverPath) ??
        unit.members
            .map((VideoBookRow m) => _nonEmpty(m.coverPath))
            .whereType<String>()
            .firstOrNull,
    lastActiveAt: _maxOrNull(
      unit.members.map(
        (VideoBookRow m) => totals.lastActive(kActivityMediaVideo, m.bookUid),
      ),
    ),
  );
}

/// 一个刮削过的视频单元及其上报身份。
class _VideoCandidate {
  _VideoCandidate(this.unit, this.ids, this.refs, this.scrapedTitle);

  final _VideoUnit unit;
  final _VideoRefs ids;
  final List<String> refs;
  final String? scrapedTitle;

  /// 剧集作品：读完要看完整部，不是看完本单元里的文件。
  bool get isSeries => unit.work?.mediaType == _mediaTypeTv;

  /// 剧集按作品身份（refs 首键，与服务端合并同一作品的依据一致）分组：同一部剧可能
  /// 散在多个单元里（每集各自刮成 `book:` 作品、多个合集指向同一作品）。电影各自一组。
  String get groupKey =>
      isSeries && refs.isNotEmpty ? 'tv|${refs.first}' : 'u|${unit.localKey}';
}

const String _mediaTypeTv = 'tv';

/// 全部成员都看完 → 最晚的看完时刻；否则 null。
int? _allCompletedAt(List<VideoBookRow> members) {
  int? at = 0;
  for (final VideoBookRow m in members) {
    final int? done = m.completedAt?.millisecondsSinceEpoch;
    at = done == null || at == null ? null : (done > at ? done : at);
  }
  return members.isEmpty ? null : at;
}

/// 剧集作品看完 = 季集骨架里每个正片集（季号 > 0）都绑着看完的本地文件；返回最晚的看完
/// 时刻，否则 null。骨架里没绑本地文件的集（没下载 / 没入库）就是没看。
///
/// 作品没有骨架（资料源没给分集）时只能退回成员口径，而且只认合集单元——合集才代表
/// 「这部剧在本地的全部集」；单个文件刮成剧集作品（`book:` 单元）只是其中一集，看完它
/// 不能说明看完了整部剧。
int? _seriesFinishedAt(
  List<_VideoCandidate> group,
  Map<int, List<_EpisodeSlot>> episodes,
  Map<String, DateTime?> completedAt,
) {
  final Map<(int, int), int?> slots = <(int, int), int?>{};
  for (final _VideoCandidate c in group) {
    for (final _EpisodeSlot e
        in episodes[c.unit.work!.id] ?? <_EpisodeSlot>[]) {
      final int? done = e.bookUid == null
          ? null
          : completedAt[e.bookUid]?.millisecondsSinceEpoch;
      slots[(e.season, e.episode)] = _maxOrNull(<int?>[
        slots[(e.season, e.episode)],
        done,
      ]);
    }
  }
  if (slots.isEmpty) {
    final Iterable<_VideoCandidate> collectionUnits = group.where(
      (_VideoCandidate c) => c.unit.collectionId != null,
    );
    if (collectionUnits.isEmpty) return null;
    return _allCompletedAt(<VideoBookRow>[
      for (final _VideoCandidate c in group) ...c.unit.members,
    ]);
  }
  if (slots.values.any((int? v) => v == null)) return null;
  return _maxOrNull(slots.values);
}

/// 季集骨架的一格：(季, 集) 与绑定的本地文件（null = 本地没有这一集）。
typedef _EpisodeSlot = ({int season, int episode, String? bookUid});

/// 作品 → 正片季集骨架（季 0 = 特典，不算进「看完整部」）。一个文件可以绑多集
/// （`01-02` 合集文件），同一集也可以有多行，由调用方按 (季, 集) 归并。
Future<Map<int, List<_EpisodeSlot>>> _videoWorkEpisodes(
  FushiDatabase db,
) async {
  final $VideoMetadataEpisodesTable e = db.videoMetadataEpisodes;
  final $VideoMetadataSeasonsTable s = db.videoMetadataSeasons;
  final List<TypedResult> rows = await (db.select(e).join(<Join>[
    innerJoin(s, s.id.equalsExp(e.seasonId)),
  ])..where(s.seasonNumber.isBiggerThanValue(0))).get();
  final Map<int, List<_EpisodeSlot>> out = <int, List<_EpisodeSlot>>{};
  for (final TypedResult r in rows) {
    final VideoMetadataEpisodeRow ep = r.readTable(e);
    final VideoMetadataSeasonRow season = r.readTable(s);
    (out[season.workId] ??= <_EpisodeSlot>[]).add((
      season: season.seasonNumber,
      episode: ep.episodeNumber,
      bookUid: ep.bookUid,
    ));
  }
  return out;
}

/// Aniyomi 在线视频（`anime-source://`）重开规格里的扩展包名；不是这种规格为 null。
/// 键名与 app 侧 `AnimeSourceBookSpec`（kind `anime-source`）是同一份持久化形状。
String? _animeSourceExtension(String? streamSpecJson) {
  final Map<String, Object?>? j = _jsonObject(streamSpecJson);
  if (j == null || j['kind'] != _animeSourceSpecKind) return null;
  return _nonEmpty(j['extensionPackage']?.toString());
}

const String _animeSourceSpecKind = 'anime-source';

int? _maxOrNull(Iterable<int?> values) {
  int? out;
  for (final int? v in values) {
    if (v != null && (out == null || v > out)) out = v;
  }
  return out;
}

class _VideoRefs {
  const _VideoRefs({
    this.bgm,
    this.anidb,
    this.mal,
    this.tmdb,
    this.scraped = false,
  });

  /// 作品级 provider 身份 → 各命名空间键体。TMDB 的 tv / movie 是两个 id 空间，
  /// 按作品的 mediaType 区分。
  factory _VideoRefs.of(
    VideoMetadataWorkRow? work,
    List<VideoMetadataProviderIdentityRow> rows,
  ) {
    String? id(String provider) => rows
        .where((VideoMetadataProviderIdentityRow r) => r.provider == provider)
        .map((VideoMetadataProviderIdentityRow r) => _nonEmpty(r.externalId))
        .whereType<String>()
        .firstOrNull;
    final String? tmdb = id('tmdb');
    final String? mediaType = work?.mediaType;
    return _VideoRefs(
      bgm: id('bangumi'),
      anidb: id('anidb'),
      mal: id('mal'),
      tmdb: tmdb == null || (mediaType != 'tv' && mediaType != 'movie')
          ? null
          : '$mediaType:$tmdb',
      scraped: rows.any(
        (VideoMetadataProviderIdentityRow r) =>
            r.provider != _localProvider && _nonEmpty(r.externalId) != null,
      ),
    );
  }

  final String? bgm;
  final String? anidb;
  final String? mal;
  final String? tmdb;

  /// 作品经外部资料源刮削过（有非 local 的 provider 身份；强 ID 必然属于这种）。
  final bool scraped;

  /// 刮削作品缺标题时的占位：第一个强 ID 键（不含任何本地文件名信息）。
  String get fallbackTitle =>
      <String?>[
        if (bgm != null) 'bgm:$bgm',
        if (anidb != null) 'anidb:$anidb',
        if (mal != null) 'mal:$mal',
        if (tmdb != null) 'tmdb:$tmdb',
      ].whereType<String>().firstOrNull ??
      '';
}

/// 本地索引（未刮削）作品的 provider 名（`VideoMetadataProviderKind.local.name`）。
const String _localProvider = 'local';

Future<Map<int, List<VideoMetadataProviderIdentityRow>>> _videoWorkIdentities(
  FushiDatabase db,
) async {
  final List<VideoMetadataProviderIdentityRow> rows =
      await (db.select(db.videoMetadataProviderIdentities)..where(
            ($VideoMetadataProviderIdentitiesTable i) => i.workId.isNotNull(),
          ))
          .get();
  final Map<int, List<VideoMetadataProviderIdentityRow>> out =
      <int, List<VideoMetadataProviderIdentityRow>>{};
  for (final VideoMetadataProviderIdentityRow r in rows) {
    (out[r.workId!] ??= <VideoMetadataProviderIdentityRow>[]).add(r);
  }
  return out;
}

/// 作品 → 首张封面图的远端 URL（`cover`；旧行可能仍叫 `poster`），按 position 取最前。
Future<Map<int, String>> _videoWorkPosters(FushiDatabase db) async {
  final List<VideoMetadataImageRow> rows =
      await (db.select(db.videoMetadataImages)
            ..where(
              ($VideoMetadataImagesTable i) =>
                  i.workId.isNotNull() &
                  i.kind.isIn(<String>['cover', 'poster']),
            )
            ..orderBy(<OrderClauseGenerator<$VideoMetadataImagesTable>>[
              ($VideoMetadataImagesTable i) =>
                  OrderingTerm(expression: i.position),
              ($VideoMetadataImagesTable i) => OrderingTerm(expression: i.id),
            ]))
          .get();
  final Map<int, String> out = <int, String>{};
  for (final VideoMetadataImageRow r in rows) {
    final String? url = _httpUrl(r.remoteUrl);
    if (url != null) out.putIfAbsent(r.workId!, () => url);
  }
  return out;
}

// ---------------------------------------------------------------------------
// 游戏

const int _playStatusFinished = 2;
const int _playStatusPlaying = 3;

Future<List<LocalShelfEntry>> _gameEntries(
  FushiDatabase db,
  _ShelfBuild build,
) async {
  final _Totals totals = build.totals;
  final List<GalgameRow> games = await db.getAllGalgames();
  if (games.isEmpty) return const <LocalShelfEntry>[];
  final Map<String, List<GalgameSourceRow>> sources = await db
      .getAllGalgameSources();
  final List<LocalShelfEntry> out = <LocalShelfEntry>[];
  for (final GalgameRow g in games) {
    final (int chars, int ms) = totals.of(kActivityMediaGame, g.id);
    final bool finished = g.playStatus == _playStatusFinished;
    final bool reading =
        g.playStatus == _playStatusPlaying || chars > 0 || ms > 0;
    if (!finished && !reading) continue;
    if (build.belongsToOtherProfile(kActivityMediaGame, <String>[g.id])) {
      continue;
    }
    final _GameMeta meta = _GameMeta.of(
      g,
      sources[g.id] ?? const <GalgameSourceRow>[],
    );
    // 没刮削过（无 bgm / vndb 身份）：标题只能是本地库名，不上报（与视频同口径）。
    if (!meta.scraped) continue;
    final LocalShelfEntry? e = _entry(
      build,
      localKey: 'game:${g.id}',
      kind: LeaderboardKind.game,
      refs: buildWorkRefs(
        bgmSubjectId: meta.bgmId,
        vndbId: meta.vndbId,
        title: meta.title,
        author: meta.developer,
      ),
      title: meta.title,
      author: meta.developer,
      coverUrl: meta.coverUrl,
      nsfw: meta.nsfw,
      finished: finished,
      // 「玩过」但没有时刻（v115 前玩过且无会话）= 读完日期未知，只进总榜。
      finishedAt: finished ? g.completedAt : null,
      chars: chars,
      ms: ms,
      counted: build.counts(kActivityMediaGame, <String>[g.id]),
      localCoverPath: g.coverPath,
      lastActiveAt: totals.lastActive(kActivityMediaGame, g.id),
    );
    if (e != null) out.add(e);
  }
  return out;
}

/// 游戏展示元数据：与 app 侧 `mergeDrafts`（契约 §2.4）同优先级的最小子集——
/// 标题 custom → bgm → vndb → 资料源键占位（**不用本地库名**：它由 exe 推出，不能当公开
/// 标题）；开发商 custom → vndb → bgm；成人向 custom → bgm → vndb；封面
/// custom.coverSource → bgm → vndb。标题取原名而非中文名：排行榜跨语言共享，原名才是
/// 各地用户的公约数。
class _GameMeta {
  const _GameMeta({
    required this.title,
    required this.developer,
    required this.nsfw,
    this.coverUrl,
    this.bgmId,
    this.vndbId,
  });

  factory _GameMeta.of(GalgameRow g, List<GalgameSourceRow> rows) {
    GalgameSourceRow? row(String source) =>
        rows.where((GalgameSourceRow r) => r.source == source).firstOrNull;
    final GalgameSourceRow? bgmRow = row('bgm');
    final GalgameSourceRow? vndbRow = row('vndb');
    final Map<String, Object?> bgm = _jsonObject(bgmRow?.dataJson) ?? const {};
    final Map<String, Object?> vndb =
        _jsonObject(vndbRow?.dataJson) ?? const {};
    final Map<String, Object?> custom =
        _jsonObject(g.customDataJson) ?? const {};
    String? str(Map<String, Object?> m, String k) {
      final Object? v = m[k];
      return v is String ? _nonEmpty(v) : null;
    }

    bool? flag(Map<String, Object?> m) {
      final Object? v = m['nsfw'];
      return v is bool ? v : null;
    }

    final Map<String, Object?> preferredCover = switch (str(
      custom,
      'coverSource',
    )) {
      'bgm' => bgm,
      'vndb' => vndb,
      _ => const <String, Object?>{},
    };
    final String? bgmId = _nonEmpty(bgmRow?.externalId);
    final String? vndbId = _nonEmpty(vndbRow?.externalId);
    return _GameMeta(
      title:
          str(custom, 'name') ??
          str(bgm, 'name') ??
          str(vndb, 'name') ??
          (bgmId != null ? 'bgm:$bgmId' : 'vndb:${vndbId ?? ''}'),
      developer:
          str(custom, 'developer') ??
          str(vndb, 'developer') ??
          str(bgm, 'developer') ??
          '',
      nsfw: flag(custom) ?? flag(bgm) ?? flag(vndb) ?? false,
      coverUrl: _httpUrl(
        str(preferredCover, 'coverUrl') ??
            str(bgm, 'coverUrl') ??
            str(vndb, 'coverUrl'),
      ),
      bgmId: bgmId,
      vndbId: vndbId,
    );
  }

  /// 经 bgm / vndb 刮削过（有外部身份）。
  bool get scraped => bgmId != null || vndbId != null;

  final String title;
  final String developer;
  final bool nsfw;
  final String? coverUrl;
  final String? bgmId;
  final String? vndbId;
}
