// 一张蓝光盘（解压/免解密的 `BDMV` 目录树）到「可播放标题列表」的映射。
//
// 盘上的 `PLAYLIST/` 少则 3 条多则上百条 MPLS，其中真正是内容的往往只有几条。剩下
// 的是：菜单循环、版权警告、预告、以及有意生成的诱饵——某些发行盘会放 99 条时长与
// 正片完全相同、只是片段顺序被打乱的播放列表，专门用来让自动选片工具选错。把它们
// 原样倒进库里，用户看到的是一屏叫 `00001`~`00099` 的同名条目。
//
// 这里的筛选链按「先去掉不可能是内容的，再合并同一内容的不同写法，最后按相对时长
// 取档」排列，每一步都只用盘上能确证的事实，不做画面内容推断：
//
//   1. 非顺序播放（`playback_type != 1`）——随机/洗牌播放列表是菜单构件，不是标题。
//   2. 引用的 m2ts 在盘上不存在——`BACKUP/` 与主目录不一致的半张盘很常见。
//   3. 绝对时长下限——砍掉版权警告、厂标、菜单循环。
//   4. 同签名合并——`(片段多重集, 总时长)` 相同即同一内容；诱饵播放列表正是靠打乱
//      顺序伪装，多重集一排序就现形。同签名里保留章节最多的那条（诱饵通常只有一个
//      章节点，真正的正片章节齐全），再以编号小的为准。
//   5. 「全部播放」合并——若一条播放列表的片段集合恰好等于另外两条及以上播放列表的
//      并集，它就是把各集串起来的 play-all，丢它保各集（TV 盘的典型形态）。
//   6. 相对时长下限——正片 120 分钟时 3 分钟的花絮出局；MV 盘各曲时长相近，整批留下。
//      这一条让「电影盘只进正片」和「MV 盘全进」用同一个判据表达，不需要先猜盘的类型。
//      锚点（最长者）不取「片段集合包住另外 ≥2 条」的 play-all 形状——⑤ 漏网的
//      play-all 若当锚，7 集以上的剧集盘各集会被它整批砍掉。
//
// 另有一条前置判据：没有视频轨的播放列表（纯音轨）不是标题。
//
// 被筛掉的播放列表仍完整保留在 [BlurayDisc.playlists] 里，将来要做「显示全部标题」
// 不必回头改筛选链。

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'bluray_playlist.dart';

/// 标题的绝对时长下限。低于此的几乎只可能是厂标、警告画面或菜单循环。
const Duration kBlurayMinimumTitleDuration = Duration(seconds: 60);

/// 标题相对于最长标题的时长下限比例。
///
/// 取 0.15 的依据：电影盘的花絮通常在正片的 5% 以下（120 分钟对 2~5 分钟），而剧集
/// 盘/MV 盘的各条目彼此在同一量级（最短的一条也有最长那条的一半以上）。0.15 把两类
/// 盘分开，同时给「40 分钟的制作特辑」这种确实值得进库的长花絮留了余地。
const double kBlurayRelativeTitleFloor = 0.15;

/// 单条读入上限。MPLS 实测通常几 KB，上百 KB 的一律当坏数据。
const int kBlurayMaxPlaylistBytes = 1024 * 1024;

/// 一张盘上被选中的一个可播放标题。
class BlurayTitle {
  const BlurayTitle({
    required this.playlist,
    required this.discRootPath,
    required this.name,
    required this.isMainFeature,
  });

  final BlurayPlaylist playlist;

  /// 含 `BDMV` 的那一层目录。
  final String discRootPath;

  /// 展示名，已含盘名。
  final String name;

  /// 是否是这张盘上最长的标题。
  final bool isMainFeature;

  Duration get duration => playlist.duration;

  /// 这条标题的稳定身份：它自己的 `.mpls` 绝对路径。
  ///
  /// 用真实存在的文件而不是虚构的 `bd://` 串做身份，是为了让下游所有「这文件还在不
  /// 在」「这路径被谁引用着」的判据原样可用。
  String get playlistPath =>
      p.join(discRootPath, 'BDMV', 'PLAYLIST', playlist.fileName);
}

/// 一张已读入的蓝光盘。
class BlurayDisc {
  const BlurayDisc({
    required this.rootPath,
    required this.name,
    required this.playlists,
    required this.titles,
  });

  /// 含 `BDMV` 的那一层目录。
  final String rootPath;

  /// 盘名：优先取 `BDMV/META` 里的盘内标题，否则用目录名。
  final String name;

  /// 盘上解析成功的全部播放列表，按编号升序；含被筛掉的。
  final List<BlurayPlaylist> playlists;

  /// 筛选后的标题，按编号升序。
  final List<BlurayTitle> titles;

  /// 最长标题在 [titles] 里的下标；[titles] 为空时为 null。
  int? get mainTitleIndex {
    for (int i = 0; i < titles.length; i++) {
      if (titles[i].isMainFeature) return i;
    }
    return null;
  }
}

/// 一张盘入库时合集名的候选序列：盘名 → 「盘名 (上级目录名)」→ 再加 `(2)`、`(3)`…
///
/// 盘名在无 `META` 时就是目录名，而压制 / 抓取出来的盘目录名极常见是 `DISC1` /
/// `BDROM` / `Vol.1`——一个系列多卷就是 `S1/DISC1/BDMV` 与 `S2/DISC1/BDMV`。合集若
/// 只按盘名全局对号，第二张盘会被对到第一张的合集上：两张盘的 `00001.mpls` 基身份
/// 相同被判「已是成员」、第一张独有的 `00003.mpls` 被移出，每次重扫按盘顺序把成员
/// 翻一遍。调用方按这个序列逐个试，撞上属于**别的盘**的合集就换下一个名字
/// （PR #1604 审查）。
Iterable<String> blurayCollectionNameCandidates(
  String discName,
  String discRootPath,
) sync* {
  yield discName;
  final String parent = p.basename(p.dirname(p.normalize(discRootPath)));
  final String qualified = parent.isEmpty || parent == discName
      ? discName
      : '$discName ($parent)';
  if (qualified != discName) yield qualified;
  for (int n = 2; ; n++) {
    yield '$qualified ($n)';
  }
}

/// [path] 指向一张盘时返回含 `BDMV` 的那层目录，否则返回 null。
///
/// 同时接受「盘根」与「`BDMV` 目录本身」两种指法——用户拖进来的可能是任意一种。
String? blurayDiscRootForDirectory(String path) {
  final String normalized = p.normalize(path);
  if (_looksLikeBlurayRoot(normalized)) return normalized;
  // 指的是 BDMV 目录本身：上跳一层（精确大小写，见 [blurayDiscRootForFile]）。
  if (p.basename(normalized) == 'BDMV') {
    final String parent = p.dirname(normalized);
    if (_looksLikeBlurayRoot(parent)) return parent;
  }
  return null;
}

bool _looksLikeBlurayRoot(String dirPath) {
  final String bdmv = p.join(dirPath, 'BDMV');
  if (!Directory(bdmv).existsSync()) return false;
  return Directory(p.join(bdmv, 'PLAYLIST')).existsSync();
}

/// 从盘内**文件**路径反推盘根；不是盘内文件时返回 null。
///
/// 递归扫描只会交出文件、从不交出目录（`LocalSourceFileSystem.listFiles` 在递归模式
/// 下只回 `File`），所以规划层只能靠这个纯函数从路径形状认盘。这里刻意只认
/// `BDMV/<PLAYLIST|STREAM|CLIPINF>/<文件>` 与 `BDMV/index.bdmv` 两种形状，不碰文件
/// 系统——同一条扫描里会对上万个路径调用它。
///
/// **目录名按精确大小写认**（BD 规范强制大写），与 IO 层（[readBlurayDisc] /
/// `resolveBluraySource` 按 `BDMV` / `PLAYLIST` / `STREAM` / `CLIPINF` 字面开文件）
/// 同一口径。若这里宽松到不分大小写，Android / Linux 上一张小写 `bdmv/` 的盘会被规划
/// 层认出来、把它的 `stream/*.m2ts` 全部从散装视频里摘掉，IO 层却开不出 `BDMV/`、
/// `readBlurayDisc` 返回 null 被静默跳过——整张盘一条都不剩。不认的盘退回散装 m2ts，
/// 至少还能播（PR #1604 审查）。文件名（`index.bdmv` / 扩展名）照旧不分大小写。
String? blurayDiscRootForFile(String filePath) {
  final List<String> parts = p.split(p.normalize(filePath));
  if (parts.length < 3) return null;
  // .../BDMV/index.bdmv 或 .../BDMV/MovieObject.bdmv
  final String fileName = parts.last.toUpperCase();
  if (parts[parts.length - 2] == 'BDMV' &&
      (fileName == 'INDEX.BDMV' || fileName == 'MOVIEOBJECT.BDMV')) {
    return p.joinAll(parts.sublist(0, parts.length - 2));
  }
  if (parts.length < 4) return null;
  const Set<String> contentDirs = <String>{'PLAYLIST', 'STREAM', 'CLIPINF'};
  if (!contentDirs.contains(parts[parts.length - 2])) return null;
  if (parts[parts.length - 3] != 'BDMV') return null;
  // `BDMV/BACKUP/PLAYLIST/...` 会在这里被挡下：它的上上层是 BACKUP 不是 BDMV。
  return p.joinAll(parts.sublist(0, parts.length - 3));
}

/// 从一批文件路径里认出盘根。纯函数，不碰文件系统。
///
/// 判据是「这张盘至少有一条 `BDMV/PLAYLIST/*.mpls`」——没有播放列表的目录树即便顶着
/// `BDMV` 这个名字也没有任何可播放的东西。与 [planMangaFolders] 同一形状：扫描器递归
/// 列目录只交出文件，目录级条目只能从文件路径反推。
List<String> planBlurayDiscRoots(Iterable<String> filePaths) {
  final Set<String> roots = <String>{};
  for (final String path in filePaths) {
    if (p.extension(path).toLowerCase() != '.mpls') continue;
    final String? root = blurayDiscRootForFile(path);
    if (root != null) roots.add(root);
  }
  final List<String> sorted = roots.toList()..sort();
  return sorted;
}

/// [filePath] 是否落在 [discRoots] 里某张盘的 `BDMV` 树下（含 `BACKUP/`）。
///
/// 盘一旦被认出来，它 `BDMV` 下的所有东西都归盘管：`STREAM/*.m2ts` 不能再各自成为一
/// 条散装视频条目，否则用户会同时看到「正片」和一堆叫 `00001` 的碎片。
bool isInsideBlurayDisc(String filePath, Set<String> discRoots) {
  if (discRoots.isEmpty) return false;
  final String normalized = p.normalize(filePath);
  for (final String root in discRoots) {
    // 精确大小写，与 [blurayDiscRootForFile] 同一口径。
    final String prefix = p.join(root, 'BDMV') + p.separator;
    if (normalized.length > prefix.length &&
        normalized.substring(0, prefix.length) == prefix) {
      return true;
    }
  }
  return false;
}

/// 读入 [rootPath] 这张盘。不是盘、或一条标题都选不出来时返回 null。
Future<BlurayDisc?> readBlurayDisc(String rootPath) async {
  final String? root = blurayDiscRootForDirectory(rootPath);
  if (root == null) return null;

  final Directory playlistDir = Directory(p.join(root, 'BDMV', 'PLAYLIST'));
  final List<FileSystemEntity> entries;
  try {
    entries = playlistDir.listSync(followLinks: false);
  } on FileSystemException {
    return null;
  }

  final List<BlurayPlaylist> playlists = <BlurayPlaylist>[];
  for (final FileSystemEntity entity in entries) {
    if (entity is! File) continue;
    if (p.extension(entity.path).toLowerCase() != '.mpls') continue;
    final BlurayPlaylist? playlist = await _readPlaylistFile(entity);
    if (playlist != null) playlists.add(playlist);
  }
  if (playlists.isEmpty) return null;
  playlists.sort((BlurayPlaylist a, BlurayPlaylist b) => a.id.compareTo(b.id));

  final Directory streamDir = Directory(p.join(root, 'BDMV', 'STREAM'));
  Set<String>? presentClips = <String>{};
  try {
    for (final FileSystemEntity entity in streamDir.listSync(
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final String name = p.basename(entity.path);
      if (p.extension(name).toLowerCase() == '.m2ts') {
        presentClips.add(p.basenameWithoutExtension(name).toUpperCase());
      }
    }
  } on FileSystemException {
    // STREAM 读不动（不存在 / 无权限）就不按「片段是否存在」筛，其余判据照常。
    // 读得动但一个 m2ts 都没有（只拷了 PLAYLIST 的半张盘）是另一回事：那时每条
    // 标题都引用着不存在的片段，照筛——否则整盘进库、一播就失败。
    presentClips = null;
  }

  final String name = await readBlurayDiscName(root);
  final List<BlurayTitle> titles = selectBlurayTitles(
    playlists,
    discRootPath: root,
    discName: name,
    presentClipIds: presentClips,
  );
  if (titles.isEmpty) return null;

  return BlurayDisc(
    rootPath: root,
    name: name,
    playlists: List<BlurayPlaylist>.unmodifiable(playlists),
    titles: List<BlurayTitle>.unmodifiable(titles),
  );
}

Future<BlurayPlaylist?> _readPlaylistFile(File file) async {
  try {
    if (await file.length() > kBlurayMaxPlaylistBytes) return null;
    final Uint8List bytes = await file.readAsBytes();
    return parseBlurayPlaylist(
      bytes,
      id: p.basenameWithoutExtension(file.path),
    );
  } on FileSystemException {
    return null;
  }
}

/// 盘名：`BDMV/META/DL/bdmt_*.xml` 里的盘内标题，读不到就用目录名。
///
/// META 是可选段，多数压制盘没有；有的时候它比目录名准得多（目录名常带压制组后缀）。
Future<String> readBlurayDiscName(String rootPath) async {
  final String fallback = p.basename(p.normalize(rootPath));
  final Directory metaDir = Directory(p.join(rootPath, 'BDMV', 'META', 'DL'));
  try {
    if (!metaDir.existsSync()) return fallback;
    final List<File> candidates =
        metaDir
            .listSync(followLinks: false)
            .whereType<File>()
            .where((File f) => p.extension(f.path).toLowerCase() == '.xml')
            .toList()
          ..sort((File a, File b) => a.path.compareTo(b.path));
    for (final File file in candidates) {
      if (await file.length() > kBlurayMaxPlaylistBytes) continue;
      final String? title = parseBlurayMetaTitle(await file.readAsString());
      if (title != null && title.isNotEmpty) return title;
    }
  } on FileSystemException {
    return fallback;
  } on FormatException {
    return fallback;
  }
  return fallback;
}

/// 从 `bdmt_*.xml` 里抽盘内标题。
///
/// 只取 `<di:name>` 下的 `<di:title>`/`<di:name>` 文本，不引 XML 解析器：这个文件在
/// 不同厂牌的盘上命名空间前缀写法不一，正则按局部名匹配反而更稳，而且解不出来的最坏
/// 后果只是回退到目录名。
String? parseBlurayMetaTitle(String xml) {
  final RegExp pattern = RegExp(
    r'<(?:\w+:)?name[^>]*>([^<]+)</(?:\w+:)?name>',
    caseSensitive: false,
  );
  final Match? match = pattern.firstMatch(xml);
  if (match == null) return null;
  final String raw = match.group(1) ?? '';
  return _unescapeXml(raw).trim();
}

String _unescapeXml(String value) => value
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');

/// 从一盘播放列表里挑出真正该进库的标题。纯函数，筛选链见文件头。
List<BlurayTitle> selectBlurayTitles(
  List<BlurayPlaylist> playlists, {
  required String discRootPath,
  required String discName,
  Set<String>? presentClipIds,
  Duration minimumDuration = kBlurayMinimumTitleDuration,
  double relativeDurationFloor = kBlurayRelativeTitleFloor,
}) {
  // 1 / 2 / 3：逐条判据，都只看这条播放列表自己。
  final int minimumTicks =
      minimumDuration.inMilliseconds * kBlurayTimeScale ~/ 1000;
  final List<BlurayPlaylist> candidates = <BlurayPlaylist>[];
  for (final BlurayPlaylist playlist in playlists) {
    if (playlist.playbackType != 1) continue;
    if (playlist.durationTicks < minimumTicks) continue;
    if (playlist.videoStreams.isEmpty) continue;
    if (presentClipIds != null &&
        !playlist.clipIds.every(
          (String id) => presentClipIds.contains(id.toUpperCase()),
        )) {
      continue;
    }
    candidates.add(playlist);
  }
  if (candidates.isEmpty) return const <BlurayTitle>[];

  // 4：同签名合并。
  final Map<String, BlurayPlaylist> bySignature = <String, BlurayPlaylist>{};
  for (final BlurayPlaylist playlist in candidates) {
    final String signature = _contentSignature(playlist);
    final BlurayPlaylist? existing = bySignature[signature];
    if (existing == null || _prefersOver(playlist, existing)) {
      bySignature[signature] = playlist;
    }
  }
  List<BlurayPlaylist> unique = bySignature.values.toList(growable: false);

  // 5：丢掉「全部播放」。
  unique = unique
      .where((BlurayPlaylist playlist) => !_isPlayAllOf(playlist, unique))
      .toList(growable: false);
  if (unique.isEmpty) return const <BlurayTitle>[];

  // 6：相对时长下限。锚点（最长者）**排除 play-all 形状**——片段集合包住另外 ≥2 条
  // 的那种：⑤ 只丢「恰好等于并集」的 play-all，剧集盘的 play-all 多含一段各集里没有
  // 的 NCOP / 预告 / 过场就漏网存活；若再拿它当锚，7 集以上的盘 0.15 × 总长就超过
  // 单集，各集全部出局、库里只剩一条几小时的 play-all。锚点退到「不是别人超集」的
  // 最长者，play-all 本身照旧按下限判（PR #1604 审查）。
  int longest = 0;
  for (final BlurayPlaylist playlist in unique) {
    if (_supersetOfOthers(playlist, unique) >= 2) continue;
    if (playlist.durationTicks > longest) longest = playlist.durationTicks;
  }
  if (longest == 0) {
    for (final BlurayPlaylist playlist in unique) {
      if (playlist.durationTicks > longest) longest = playlist.durationTicks;
    }
  }
  final int relativeFloor = (longest * relativeDurationFloor).round();
  final List<BlurayPlaylist> kept =
      unique
          .where(
            (BlurayPlaylist playlist) =>
                playlist.durationTicks >= relativeFloor,
          )
          .toList()
        ..sort((BlurayPlaylist a, BlurayPlaylist b) => a.id.compareTo(b.id));
  if (kept.isEmpty) return const <BlurayTitle>[];

  final bool single = kept.length == 1;
  final List<BlurayTitle> titles = <BlurayTitle>[];
  for (int i = 0; i < kept.length; i++) {
    final BlurayPlaylist playlist = kept[i];
    titles.add(
      BlurayTitle(
        playlist: playlist,
        discRootPath: discRootPath,
        name: single
            ? discName
            : '$discName - ${(i + 1).toString().padLeft(2, '0')}',
        isMainFeature: playlist.durationTicks == longest,
      ),
    );
  }
  return titles;
}

/// 内容签名：片段多重集（排序后）+ 总时长。顺序被打乱的诱饵播放列表在这里与正片同签名。
String _contentSignature(BlurayPlaylist playlist) {
  final List<String> ids = playlist.clipIds.toList()..sort();
  return '${ids.join(",")}@${playlist.durationTicks}';
}

/// 同签名里谁更可能是「真正那条」：章节多的优先，其次编号小的。
bool _prefersOver(BlurayPlaylist candidate, BlurayPlaylist incumbent) {
  if (candidate.chapters.length != incumbent.chapters.length) {
    return candidate.chapters.length > incumbent.chapters.length;
  }
  return candidate.id.compareTo(incumbent.id) < 0;
}

/// [pool] 里有几条别的播放列表的片段集合被 [playlist] 严格包住（集合比较）。
int _supersetOfOthers(BlurayPlaylist playlist, List<BlurayPlaylist> pool) {
  final Set<String> own = playlist.clipIds.toSet();
  int count = 0;
  for (final BlurayPlaylist other in pool) {
    if (identical(other, playlist)) continue;
    final Set<String> ids = other.clipIds.toSet();
    if (ids.isEmpty || ids.length >= own.length) continue;
    if (own.containsAll(ids)) count++;
  }
  return count;
}

/// [playlist] 是否只是把 [pool] 里另外两条及以上播放列表串起来的「全部播放」。
bool _isPlayAllOf(BlurayPlaylist playlist, List<BlurayPlaylist> pool) {
  if (playlist.clips.length < 2) return false;
  final Set<String> own = playlist.clipIds.toSet();
  if (own.length != playlist.clips.length) return false;

  final Set<String> covered = <String>{};
  int parts = 0;
  for (final BlurayPlaylist other in pool) {
    if (identical(other, playlist)) continue;
    final Set<String> ids = other.clipIds.toSet();
    if (ids.isEmpty || !own.containsAll(ids)) continue;
    covered.addAll(ids);
    parts++;
  }
  return parts >= 2 && covered.length == own.length;
}
