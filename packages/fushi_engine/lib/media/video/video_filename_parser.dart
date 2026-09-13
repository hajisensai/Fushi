import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:fushi_engine/media/media_extensions.dart';
import 'package:fushi_engine/media/video/external_video.dart'
    show decodedSourceBasename;
import 'package:fushi_engine/media/video/scraper/filename_parser.dart';
import 'package:fushi_engine/media/video/scraper/scraper_types.dart';
export 'package:fushi_engine/media/media_extensions.dart' show kVideoExtensions;
import 'package:fushi_engine/media/collections/shelf_sort.dart'
    show naturalCompare;

/// 从视频文件名解析出的元信息：系列名 + 季 + 集号（Jellyfin / anitomy 式轻量实现）。
///
/// [series] 永不为空（识别不出集号时整名作系列，按单片处理）。[season] / [episode]
/// 识别不出为 null。纯数据，便于单测。
class VideoNameInfo {
  const VideoNameInfo({
    required this.series,
    this.season,
    this.episode,
  });

  /// 系列/番剧名（去字幕组 tag / 画质 / 集号后的可读主干）。
  final String series;

  /// 季号（1-based）；未识别为 null。
  final int? season;

  /// 集号；未识别为 null（此时分组按单片处理）。
  final int? episode;

  @override
  String toString() =>
      'VideoNameInfo(series: $series, season: $season, episode: $episode)';
}

/// 解析视频文件名（可带或不带扩展名）→ [VideoNameInfo]。纯函数，无 IO。
///
/// G10 第二步：本函数是刮削端规则引擎 [FilenameParser.parse] 的**窄化适配**——
/// 此前这里另持一套完整规则引擎，同一文件名两边可能解出不同集数（分组显示第 5
/// 集、刮削按第 3 集查）。现在单引擎单真相：[ParsedMediaName.title] 作系列名
/// （引擎解不出标题时退回整个 stem，保持「series 永不为空」契约），
/// season / episode 原样映射；副标题装饰（`～xxx～` / ` - xxx`）与电影关键词
/// （`Movie` / `剧场版`）由引擎剥离，不再留在系列名里。
VideoNameInfo parseVideoFilename(String filename) {
  final RegExp explicitBlock = RegExp(r'\{\[([^\]]+)\]\}');
  final RegExpMatch? explicit = explicitBlock.firstMatch(filename);
  int? explicitNumber(String shortName, String longName) {
    final String? body = explicit?.group(1);
    if (body == null) return null;
    return int.tryParse(
      RegExp(
            '(?:^|;)\\s*(?:$shortName|$longName)\\s*=\\s*(\\d+)',
            caseSensitive: false,
          ).firstMatch(body)?.group(1) ??
          '',
    );
  }

  // MoviePilot/Emby style identity blocks are matching directives, not part
  // of the display title. Keep the original path for the metadata resolver,
  // but strip the block before filename parsing and honor explicit S/E values.
  final String parsedFilename = filename.replaceAll(explicitBlock, ' ');
  final ParsedMediaName parsed = FilenameParser.parse(parsedFilename);
  return VideoNameInfo(
    series: parsed.title.isNotEmpty
        ? parsed.title
        : _fallbackSeries(parsedFilename),
    season: explicitNumber('s', 'season') ?? parsed.season,
    episode: explicitNumber('e', 'episode') ?? parsed.episode,
  );
}

/// 解析**完整路径** → [VideoNameInfo]：文件名照旧走 [parseVideoFilename]，只在
/// 「解出了集号、但没解出季号」时把季号回落到父目录名（BUG-1543）。纯函数，无 IO。
///
/// `Show/Season 2/Show - 01.mkv`、`Show/S02/01.mkv` 这类**季目录**布局里，季号只
/// 写在目录上、文件名一个字都没有；只看 basename 的旧口径把整部番全判成第 1 季，
/// 分季 tab 和「按季拆分」自然什么也分不出来。
///
/// 回落只在剧集文件上生效（`info.episode != null`）：电影目录 `Ip Man 2/xxx.mkv`
/// 没有集号，季语义不成立，保持原样不动。目录名先走同一个规则引擎（认
/// `Season 2` / `S02` / `第2季` / `2nd Season`），引擎不认时再试尾部裸数字
/// （`Hibike! Euphonium 2/`），两者同源于 [FilenameParser]。
VideoNameInfo parseVideoPath(String path) {
  final List<String> segments = _pathSegments(path);
  // 网络来源的 URL 段是百分号编码的，必须与 [groupVideosIntoPlaylists] 同口径
  // 先解码：`Show%20A%20S01E01` 里 `S` 前面是 `0`，`SxxEyy` 的分隔边界不成立，
  // 不解码就整批解不出集号（两条通路口径分叉，同一文件两处不同解）。
  final String filename =
      _decodedSegment(path, segments.isEmpty ? path : segments.last);
  final VideoNameInfo info = parseVideoFilename(filename);
  if (info.season != null || info.episode == null || segments.length < 2) {
    return info;
  }
  final ParsedMediaName dir =
      FilenameParser.parse(segments[segments.length - 2]);
  final int? dirSeason =
      dir.season ?? FilenameParser.takeTrailingNumericSeason(dir.title)?.season;
  if (dirSeason == null) return info;
  return VideoNameInfo(
    series: info.series,
    season: dirSeason,
    episode: info.episode,
  );
}

/// 剧集卡片的**显示集号**（BUG-1544）：从路径/文件名解析出的**真实**集号；
/// 解析不出返回 null，由调用方回落到列表顺位号。
///
/// 顺位号在「前面几集没导入 / 缺集」时必然说谎——`S01E05` 排在列表第 3 位就被
/// 标成 `03`。集号是文件名里写着的事实，不是列表下标的函数，故一律现场解析。
int? parsedEpisodeNumberOf(String pathOrName) =>
    parseVideoPath(pathOrName).episode;

/// 一批路径的**显示集号**（BUG-2369）：先按单文件名规则解析，解不出的再用
/// 同目录兄弟文件的差分定号补齐。返回值与 [pathsOrNames] 同序、同长。
///
/// 显示侧（选集轨道 / 合集详情页）拿到的本来就是整批路径，没有理由退化成逐个
/// 文件猜——单文件名解不出时，兄弟集合往往一眼就能定号。
List<int?> parsedEpisodeNumbersOf(List<String> pathsOrNames) =>
    _resolveWithSiblings(pathsOrNames).episodes;

/// 一个目录的兄弟差分结论：路径 → 集号，外加公共前缀推出的系列名。
class SiblingEpisodeNumbering {
  const SiblingEpisodeNumbering({required this.numbers, required this.series});

  /// 路径 → 集号（覆盖该目录里的每一个文件）。
  final Map<String, int> numbers;

  /// 公共前缀过一遍 [FilenameParser] 后的系列名；推不出时为空串。
  final String series;
}

/// 兄弟集合差分定号（BUG-2369）：把**同一目录**下的一批文件名放在一起看，
/// 公共前后缀之外那段变化的数字就是集号。判据不成立时返回 null。
///
/// 单文件名解析必须在「`Show 2` 是第 2 季还是第 2 集」这种歧义上赌一把，
/// [FilenameParser] 的赌法是「尾部裸数字要两位或带前导零才算集号」
/// （`_bareTrailingEpisode`）——于是 `Show 1.mkv … Show 12.mkv` 这种不补零的
/// 目录里 `10/11/12` 赌赢、`1..9` 赌输：同一批文件一半有集号一半没有，排序、
/// 计数、角标、归组全跟着错。**而一批兄弟文件放在一起时这个歧义根本不存在**：
/// 它们只在集号那一段不同，那段就是集号。这是集合的性质，不是猜出来的。
///
/// 判据刻意收紧到「全成立才用」，任一条不成立就返回 null、调用方保持原行为：
/// - 至少 2 个文件，stem 两两不同；
/// - 公共前缀/后缀不得切断数字段（否则 `Show 10/11/12` 会被切成 `0/1/2`）；
/// - 每个文件去掉公共前后缀后**必须**只剩 1–3 位数字（4 位挡掉 `Movie (1979)`
///   这种按年份区分的目录），且各文件解出的数值两两不同。
SiblingEpisodeNumbering? resolveSiblingEpisodeNumbers(List<String> paths) {
  if (paths.length < 2) return null;
  final List<String> stems = <String>[
    for (final String path in paths)
      p.basenameWithoutExtension(decodedSourceBasename(path)),
  ];
  if (stems.toSet().length != stems.length) return null;

  final String first = stems.first;
  int prefixLen = first.length;
  int suffixLen = first.length;
  for (final String s in stems.skip(1)) {
    prefixLen = _commonPrefixLen(first, s, prefixLen);
    suffixLen = _commonSuffixLen(first, s, suffixLen);
  }
  // 公共前后缀不得切断数字段：`Show 10/11/12` 的公共前缀是 `Show 1`，不回退
  // 就会把集号切成 `0/1/2`。前缀退回数字段起点，后缀推过数字段。
  while (prefixLen > 0 && _isAsciiDigit(first.codeUnitAt(prefixLen - 1))) {
    prefixLen--;
  }
  while (suffixLen > 0 &&
      _isAsciiDigit(first.codeUnitAt(first.length - suffixLen))) {
    suffixLen--;
  }

  final Map<String, int> numbers = <String, int>{};
  final Set<int> seen = <int>{};
  for (int i = 0; i < paths.length; i++) {
    final String stem = stems[i];
    if (prefixLen + suffixLen > stem.length) return null;
    final String middle = stem.substring(prefixLen, stem.length - suffixLen);
    if (!_pureEpisodeDigits.hasMatch(middle)) return null;
    final int? value = int.tryParse(middle);
    if (value == null || !seen.add(value)) return null;
    numbers[paths[i]] = value;
  }
  // 系列名从公共前缀来，并过一遍同一个规则引擎剥字幕组/画质块；引擎给不出
  // 标题时退回清理后的原前缀（`第` / `EP` 这类残词由 [_trimSeriesEdges] 削掉）。
  final String rawPrefix = first.substring(0, prefixLen);
  final String parsed = FilenameParser.parse(rawPrefix).title.trim();
  final String series =
      _stripTrailingEpisodeMarker(parsed.isNotEmpty ? parsed : rawPrefix);
  return SiblingEpisodeNumbering(numbers: numbers, series: series);
}

/// 用同目录兄弟文件的差分定号补齐 [perFile] 里的 null（BUG-2369）。
///
/// **只补 null、从不覆盖已解出的值**——零回归靠这条保证。补之前还要求差分结果
/// 与同目录每一个已解出的集号都对得上；对不上说明两套口径不同（例如绝对集号与
/// 分季集号混在一个目录里），此时整个目录放弃、保持原样。
List<int?> fillEpisodeNumbersFromSiblings(
  List<String> paths,
  List<int?> perFile,
) {
  if (paths.length != perFile.length) return perFile;
  if (!perFile.contains(null)) return perFile;
  final List<int?> out = List<int?>.of(perFile);
  for (final List<int> indices in _byDirectory(paths).values) {
    final SiblingEpisodeNumbering? sib =
        _acceptedSiblingNumbering(paths, perFile, indices);
    if (sib == null) continue;
    for (final int i in indices) {
      out[i] ??= sib.numbers[paths[i]];
    }
  }
  return out;
}

/// [fillEpisodeNumbersFromSiblings] 的内部形态：集号之外再带上「该目录的兄弟
/// 差分系列名」，供 [groupVideosIntoPlaylists] 统一整个目录的分组键。
class _SiblingResolution {
  const _SiblingResolution(this.episodes, this.series);

  /// 与输入同序同长的集号（含兄弟补齐）。
  final List<int?> episodes;

  /// 与输入同序同长的系列名覆盖；无覆盖为 null。
  final List<String?> series;
}

_SiblingResolution _resolveWithSiblings(List<String> paths) {
  final List<int?> perFile = <int?>[
    for (final String path in paths) parsedEpisodeNumberOf(path),
  ];
  final List<int?> episodes = List<int?>.of(perFile);
  final List<String?> series = List<String?>.filled(paths.length, null);
  for (final List<int> indices in _byDirectory(paths).values) {
    final SiblingEpisodeNumbering? sib =
        _acceptedSiblingNumbering(paths, perFile, indices);
    if (sib == null) continue;
    for (final int i in indices) {
      episodes[i] ??= sib.numbers[paths[i]];
      if (sib.series.isNotEmpty) series[i] = sib.series;
    }
  }
  return _SiblingResolution(episodes, series);
}

/// 某目录的兄弟差分结论，已过「值得用」的三道门：目录里至少 2 个文件、至少有
/// 一个文件单看文件名解不出集号（全解得出的目录一个字节都不动），差分结果与每
/// 个已解出的集号都对得上。
SiblingEpisodeNumbering? _acceptedSiblingNumbering(
  List<String> paths,
  List<int?> perFile,
  List<int> indices,
) {
  if (indices.length < 2) return null;
  if (indices.every((int i) => perFile[i] != null)) return null;
  final SiblingEpisodeNumbering? sib = resolveSiblingEpisodeNumbers(
    <String>[for (final int i in indices) paths[i]],
  );
  if (sib == null) return null;
  final bool agrees = indices.every(
      (int i) => perFile[i] == null || perFile[i] == sib.numbers[paths[i]]);
  return agrees ? sib : null;
}

/// 按父目录把下标分桶（无目录段的裸文件名归同一桶）。
Map<String, List<int>> _byDirectory(List<String> paths) {
  final Map<String, List<int>> byDir = <String, List<int>>{};
  for (int i = 0; i < paths.length; i++) {
    final List<String> segments = _pathSegments(paths[i]);
    final String key = segments.length < 2
        ? ''
        : segments.sublist(0, segments.length - 1).join('/').toLowerCase();
    byDir.putIfAbsent(key, () => <int>[]).add(i);
  }
  return byDir;
}

/// 削掉公共前缀尾巴上的季/集标记残词再清理两端：公共前缀是按字符切的，
/// `Show S01E01/02` 的公共前缀会停在 `Show S01E`，直接拿去当系列名就会把
/// `S01E` 焊死进番名。这类残词一律削掉；削完为空就等于「推不出系列名」，
/// 由调用方回落既有行为（`第1话/第12话` 的公共前缀 `第` 就走这条）。
String _stripTrailingEpisodeMarker(String s) {
  final String out = _trimSeriesEdges(s).replaceFirst(
    RegExp(r'(?:^|[\s._-])(?:[Ss]\d{1,2}[\s._-]*)?(?:[Ee][Pp]?|#|第)$'),
    '',
  );
  return _trimSeriesEdges(out);
}

/// 削掉系列名两端的分隔残渣（`Show - ` / `Show_` / `[组] Show.`）。
String _trimSeriesEdges(String s) {
  String out = s.replaceAll('_', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  out = out.replaceFirst(RegExp(r'^[\s\-_.·\[(【]+'), '');
  out = out.replaceFirst(RegExp(r'[\s\-_.·\[(【]+$'), '');
  return out.trim();
}

/// 集号中段：1–3 位数字（含前导零）。4 位挡掉按年份区分的目录。
final RegExp _pureEpisodeDigits = RegExp(r'^\d{1,3}$');

bool _isAsciiDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;

/// [a] 与 [b] 的公共前缀长度，上限 [cap]。
int _commonPrefixLen(String a, String b, int cap) {
  int n = cap < b.length ? cap : b.length;
  if (n > a.length) n = a.length;
  int i = 0;
  while (i < n && a.codeUnitAt(i) == b.codeUnitAt(i)) {
    i++;
  }
  return i;
}

/// [a] 与 [b] 的公共后缀长度，上限 [cap]。
int _commonSuffixLen(String a, String b, int cap) {
  int n = cap < b.length ? cap : b.length;
  if (n > a.length) n = a.length;
  int i = 0;
  while (i < n &&
      a.codeUnitAt(a.length - 1 - i) == b.codeUnitAt(b.length - 1 - i)) {
    i++;
  }
  return i;
}

/// 路径切段（平台无关：同时认 `/` 与 `\`，与 [FilenameParser.candidatesForPath]
/// 同口径）。`p.basename` 在 Linux 上不认 `\`，而库里存的可能是 Windows 路径。
List<String> _pathSegments(String path) => path
    .split(RegExp(r'[\\/]+'))
    .map((String s) => s.trim())
    .where((String s) => s.isNotEmpty)
    .toList(growable: false);

/// 引擎解不出标题（纯日期/设备命名、全括号无标题块、纯集数名等）时的系列名
/// 兜底：剥视频扩展名后的原始 stem（下划线转空格、折叠空白），保证「series
/// 永不为空、按单片分组」的既有契约。
String _fallbackSeries(String filename) {
  String stem = filename;
  final String ext = p.extension(filename).toLowerCase();
  if (kVideoExtensions.contains(ext)) {
    stem = filename.substring(0, filename.length - ext.length);
  }
  stem = stem.replaceAll('_', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  return stem.isEmpty ? filename.trim() : stem;
}

/// 分组里的一集：源文件绝对路径 + 显示标题 + 季/集（用于排序）。
class VideoEpisode {
  const VideoEpisode({
    required this.path,
    required this.title,
    this.season,
    this.episode,
  });

  final String path;
  final String title;
  final int? season;
  final int? episode;
}

/// 同系列的一组（≥1 集）。[episodes] 已按 季→集→标题 升序排好。
class VideoGroup {
  const VideoGroup({required this.series, required this.episodes});

  final String series;
  final List<VideoEpisode> episodes;

  /// 多集 → 作为播放列表导入；单集 → 作为单片导入。
  bool get isPlaylist => episodes.length > 1;
}

/// 分组用的系列名。
///
/// 文件名解得出标题就用它（既有行为）。**文件名只剩集号**时（`01.mp4`、
/// `第01集.mp4`、`S01E01.mkv`——番名写在目录上是常见整理方式）按 stem 分组会
/// 让每一集各成一个单集组、各成一张卡，用户看到的就是「整部番被拆成一堆分开
/// 的条目」；这时回落到父目录名，与 [parseVideoPath] 把季号回落到父目录同源。
///
/// 父目录名同样过一遍规则引擎剥掉字幕组/画质块；父目录自己也解不出标题时
/// （`Season 1`、`01`）用父目录原名——它至少能把同一目录的文件归到一起，且
/// 不会把两个季目录并成一组（并了会让 S1E01 与 S2E01 撞键丢文件）。
String _groupingSeries(String path, String name, VideoNameInfo info) {
  if (info.episode == null) return info.series;
  if (FilenameParser.parse(name).title.trim().isNotEmpty) return info.series;
  final List<String> segments = _pathSegments(path);
  if (segments.length < 2) return info.series;
  final String parent = _decodedSegment(path, segments[segments.length - 2]);
  final String parsed = FilenameParser.parse(parent).title.trim();
  if (parsed.isNotEmpty) return parsed;
  final String raw = parent.trim();
  return raw.isEmpty ? info.series : raw;
}

/// 网络来源的 URL 段是百分号编码的，与 [decodedSourceBasename] 同口径解码。
String _decodedSegment(String path, String segment) {
  if (!path.startsWith('http://') && !path.startsWith('https://')) {
    return segment;
  }
  try {
    return Uri.decodeComponent(segment);
  } catch (_) {
    return segment;
  }
}

/// 把一批视频文件路径按解析出的系列名分组成 [VideoGroup]，组内按 季→集→标题 排序，
/// 组间按系列名（不区分大小写）稳定排序。纯函数（只读文件名，不碰磁盘），便于单测。
List<VideoGroup> groupVideosIntoPlaylists(List<String> paths) {
  final Map<String, List<VideoEpisode>> byKey = <String, List<VideoEpisode>>{};
  final Map<String, String> displaySeries = <String, String>{};

  // 集号与系列名都先过一遍**兄弟集合差分**（BUG-2369）：同目录里只要有文件
  // 单看文件名解不出集号，就用「公共前后缀之外那段数字」定号，并让整个目录
  // 共用同一个系列名——否则 `Show 1.mkv … Show 12.mkv` 里 1..9 的集号留在系列
  // 名里（`Show 1` / `Show 2`），同一部番会被拆成一堆单集卡。
  // 目录里每个文件都自带集号时差分不介入，行为与修复前逐字相同。
  final _SiblingResolution sib = _resolveWithSiblings(paths);

  for (int i = 0; i < paths.length; i++) {
    final String path = paths[i];
    // 解码后的文件名参与解析/展示（decodedSourceBasename）：网络来源的
    // http(s) URL 段是百分号编码的，不解码会把 %20 之类渗进系列名与集标题；
    // 本地路径原样返回，行为不变。
    final String name = decodedSourceBasename(path);
    final VideoNameInfo info = parseVideoFilename(name);
    final String series = sib.series[i] ?? _groupingSeries(path, name, info);
    final String key = series.toLowerCase();
    displaySeries.putIfAbsent(key, () => series);
    byKey.putIfAbsent(key, () => <VideoEpisode>[]).add(VideoEpisode(
          path: path,
          title: p.basenameWithoutExtension(name),
          season: info.season,
          episode: sib.episodes[i],
        ));
  }

  final List<VideoGroup> groups = <VideoGroup>[];
  for (final MapEntry<String, List<VideoEpisode>> e in byKey.entries) {
    final List<VideoEpisode> eps = e.value..sort(_compareEpisodes);
    groups.add(VideoGroup(series: displaySeries[e.key]!, episodes: eps));
  }
  groups.sort((VideoGroup a, VideoGroup b) =>
      a.series.toLowerCase().compareTo(b.series.toLowerCase()));
  return groups;
}

/// 排序：季升序（null 视作 1）→ 集升序（null 排末尾）→ 标题**自然序**。
///
/// 末位判据用 [naturalCompare]（与书架「按名称」同一套）而不是裸字符串序：
/// 集号真的解不出时（特典/PV 混排、兄弟差分不成立），裸字符串序会排成
/// `1, 10, 11, 12, 2, …`——数字段该按数值比，这是显示层的最低要求（BUG-2369）。
int _compareEpisodes(VideoEpisode a, VideoEpisode b) {
  final int sa = a.season ?? 1;
  final int sb = b.season ?? 1;
  if (sa != sb) return sa.compareTo(sb);
  final int ea = a.episode ?? (1 << 30);
  final int eb = b.episode ?? (1 << 30);
  if (ea != eb) return ea.compareTo(eb);
  return naturalCompare(a.title, b.title);
}

/// 递归扫描 [directory] 及其所有子目录里的视频文件，返回绝对路径列表
/// （按名称排序）。仅此函数碰磁盘。
///
/// 「导入文件夹」的用户心智模型是「找出这个文件夹里的所有视频」，而视频通常
/// 按 `番剧名/Season X/E01.mkv`、`电影合集/某电影/movie.mkv` 这类结构组织——
/// 顶层只有文件夹、没有视频文件。早期只扫顶层（非递归）会让这类目录恒返回空
/// 列表，导入对话框据此误报「无视频」。改递归遍历后任意嵌套深度的视频都能找到。
///
/// [followLinks] 关闭，避免符号链接成环导致无限递归；listSync 自身对无法
/// 访问的子目录会抛 [FileSystemException]，逐项跳过而非整体失败。
List<String> listVideoFilesInDirectory(String directory) {
  final Directory dir = Directory(directory);
  if (!dir.existsSync()) return const <String>[];
  final List<String> out = <String>[];
  for (final FileSystemEntity entity
      in dir.listSync(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final String ext = p.extension(entity.path).toLowerCase();
    if (kVideoExtensions.contains(ext)) out.add(entity.path);
  }
  out.sort();
  return out;
}
