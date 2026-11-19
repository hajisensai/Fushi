/// 专辑目录里的盘面扫描图（设计稿 M3：带盘面图的专辑画成「封面 + 唱片」色块）。
///
/// 抓轨 / 扫图目录的常见习惯：盘面图与音频放在同一目录（`disc.jpg` / `cd.png` /
/// `cdart.png` / `Disc 1.jpg` / `label.jpg`），或收在扫图子目录里（`Scans/CD.jpg`、
/// `Artwork/disc1.png`、`Scans/Disc/01.jpg`）。识别规则是纯函数
/// （[musicDiscArtScore] / [pickMusicDiscArt]），文件系统只在 [MusicDiscArtIndex] 里碰。
///
/// **存放方式**：不落库，按专辑目录现场识别、进程内缓存。`media_images`
/// （`MediaImageKind.discArt`）的单一归属 CHECK 只允许合集 / 视频两种归属，挂不到
/// `music_albums` 上（`music_tables.dart` 的 `coverPath` 注释同一原因）；新开列要升
/// schema 且盘面图该由 Rust 扫描器（`native/fushi_music`）在扫描时一并认出，留作后续。
/// 现场识别只读本地目录：远程来源（SFTP / WebDAV / 服务器）的专辑不认盘面图。
library;

import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

/// 认作盘面图的图片扩展名（小写，带点）。
const Set<String> kMusicDiscArtImageExtensions = <String>{
  '.jpg',
  '.jpeg',
  '.png',
  '.webp',
  '.bmp',
};

/// 文件名 / 子目录名里表示「盘面」的词（按词比较，`cdcover` 这类连写不算）。
const Set<String> _discWords = <String>{
  'disc',
  'discs',
  'disk',
  'cd',
  'cds',
  'cdart',
  'discart',
  'label',
};

/// 盘面图之外的扫图部位：出现这些词的图不是盘面（`cd_back.jpg`、`disc tray.jpg`）。
const Set<String> _otherPartWords = <String>{
  'cover',
  'covers',
  'front',
  'back',
  'bk',
  'booklet',
  'book',
  'obi',
  'inlay',
  'tray',
  'case',
  'spine',
  'inside',
  'inner',
  'sleeve',
  'jacket',
  'box',
  'poster',
  'sticker',
  'folder',
  'thumb',
  'thumbnail',
  'logo',
  'artist',
  'lyrics',
};

/// 扫图收纳目录名里的词（只往这类子目录里找盘面图）。
const Set<String> _scanDirWords = <String>{
  'scan',
  'scans',
  'artwork',
  'artworks',
  'art',
  'covers',
  'images',
  'image',
  'pics',
  'pictures',
  'photos',
};

/// 中日文的盘面写法（子串匹配）。
const List<String> _discCjk = <String>['盘面', '盤面', '碟面', 'ディスク', 'レーベル'];

/// 中日文名整段就是「盘」的写法。
const Set<String> _discCjkWhole = <String>{'盘', '盤', '碟', '光盘', '光碟'};

/// 中日文的其它扫图部位（子串匹配）。
const List<String> _otherPartCjk = <String>[
  '封面',
  '封底',
  '背面',
  '歌词',
  '歌詞',
  'ブックレット',
  'ジャケット',
  '帯',
];

/// 中日文的扫图收纳目录名（子串匹配）。
const List<String> _scanDirCjk = <String>['扫图', '掃圖', '扫描', 'スキャン'];

final RegExp _wordPattern = RegExp(r'[a-z]+|[0-9]+');

List<String> _words(String text) => <String>[
  for (final RegExpMatch m in _wordPattern.allMatches(text.toLowerCase()))
    m[0]!,
];

/// [name] 是不是扫图收纳目录（`Scans` / `Artwork` / `扫图` …）。
bool isMusicScanDirectoryName(String name) =>
    _words(name).any(_scanDirWords.contains) || _scanDirCjk.any(name.contains);

bool _mentionsDisc(String name) {
  if (_words(name).any(_discWords.contains)) return true;
  final String trimmed = name.trim();
  return _discCjkWhole.contains(trimmed) || _discCjk.any(trimmed.contains);
}

bool _mentionsOtherPart(String name) =>
    _words(name).any(_otherPartWords.contains) ||
    _otherPartCjk.any(name.contains);

/// 文件名主干里的碟号（`disc2` / `CD 02` → 2）；没有数字为 null。
int? _discNumberOf(String stem) {
  final List<String> words = _words(stem);
  for (int i = 0; i < words.length; i++) {
    final int? n = int.tryParse(words[i]);
    if (n != null) return n;
  }
  return null;
}

/// 相对专辑目录的 [relativePath]（`/` 或 `\` 分隔）作为盘面图的得分；不是盘面图
/// 为 null。分越高越像「这张专辑的第一张盘面」。纯函数。
///
/// 认的形状：
/// - 专辑目录根下的图，文件名里有盘面词（`disc` / `cd` / `cdart` / `label` / `盘面`
///   / `ディスク` …，按词比较），且没有其它扫图部位词（`cover` / `back` / `obi` /
///   `tray` / `booklet` …）；
/// - 扫图收纳目录（`Scans` / `Artwork` / `Covers` / `扫图` …）里同样规则的图；
///   收纳目录下一层的子目录名也算（`Scans/Disc/01.jpg`），最多一层；
/// - 其它子目录（分碟目录 `Disc 1/` 等）里的图不认——那是音频目录，自己另作根。
int? musicDiscArtScore(String relativePath) {
  final List<String> segments = relativePath
      .split(RegExp(r'[\\/]'))
      .where((String s) => s.isNotEmpty)
      .toList(growable: false);
  if (segments.isEmpty) return null;
  final String file = segments.last;
  final String ext = p.extension(file).toLowerCase();
  if (!kMusicDiscArtImageExtensions.contains(ext)) return null;
  final String stem = p.basenameWithoutExtension(file);
  final List<String> dirs = segments.sublist(0, segments.length - 1);
  if (dirs.length > 2) return null;
  if (dirs.isNotEmpty && !isMusicScanDirectoryName(dirs.first)) return null;
  // 收纳目录本身（`Covers`）不参与部位判定；它下面那一层子目录参与。
  final List<String> named = <String>[...dirs.skip(1), stem];
  if (named.any(_mentionsOtherPart)) return null;
  if (!named.any(_mentionsDisc)) return null;
  int score = 100;
  if (dirs.isEmpty) score += 20;
  final List<String> stemWords = _words(stem);
  if (stemWords.contains('cdart') || stemWords.contains('discart')) {
    score += 15;
  }
  if (stemWords.contains('label') && !stemWords.any(_isPlainDiscWord)) {
    score -= 3;
  }
  final int? number = _discNumberOf(stem);
  if (number == null || number <= 1) score += 10;
  if (ext == '.png') score += 2;
  return score;
}

bool _isPlainDiscWord(String w) =>
    w == 'disc' || w == 'disk' || w == 'cd' || w == 'cdart' || w == 'discart';

/// [relativePaths] 里最像盘面图的一个；都不是为 null。同分时路径短的优先，再按
/// 字典序（结果稳定）。纯函数。
String? pickMusicDiscArt(Iterable<String> relativePaths) {
  String? best;
  int bestScore = -1;
  for (final String path in relativePaths) {
    final int? score = musicDiscArtScore(path);
    if (score == null) continue;
    final String? current = best;
    if (current == null ||
        score > bestScore ||
        (score == bestScore &&
            (path.length < current.length ||
                (path.length == current.length &&
                    path.compareTo(current) < 0)))) {
      best = path;
      bestScore = score;
    }
  }
  return best;
}

final RegExp _discSubdirPattern = RegExp(
  r'^(disc|disk|cd)\s*[-_.#]?\s*\d+\b',
  caseSensitive: false,
);
final RegExp _discSubdirCjkPattern = RegExp(r'^第?\s*\d+\s*(枚目|盘|盤|碟)');

/// 分碟目录名（`Disc 1` / `CD2` / `DISC-01 xxx` / `第2盘` / `2枚目`）。纯函数。
bool isMusicDiscSubdirectoryName(String name) {
  final String trimmed = name.trim();
  return _discSubdirPattern.hasMatch(trimmed) ||
      _discSubdirCjkPattern.hasMatch(trimmed);
}

/// 本地曲目路径（不是 `scheme://` 地址、是绝对路径）。纯函数。
bool isLocalMusicTrackPath(String path) =>
    !path.contains('://') && p.isAbsolute(path);

/// 一首曲目所属「版本目录」：曲目所在目录；分碟目录（[isMusicDiscSubdirectoryName]）
/// 取它的上一级。同一张专辑的不同目录（不同格式 / 不同版本）各是一个版本目录。纯函数。
String musicTrackVersionDirectory(String trackPath) {
  final String dir = p.dirname(trackPath);
  if (isMusicDiscSubdirectoryName(p.basename(dir))) return p.dirname(dir);
  return dir;
}

/// 一张专辑找盘面图的根目录：各版本目录在前（盘面图通常在专辑根），其后是各曲目
/// 所在目录（分碟目录里各自的 `disc.jpg`）。只收本地绝对路径，去重保序。纯函数。
List<String> musicAlbumDiscArtRoots(Iterable<String> trackPaths) {
  final List<String> versions = <String>[];
  final List<String> trackDirs = <String>[];
  for (final String path in trackPaths) {
    if (!isLocalMusicTrackPath(path)) continue;
    final String version = musicTrackVersionDirectory(path);
    if (!versions.contains(version)) versions.add(version);
    final String dir = p.dirname(path);
    if (!trackDirs.contains(dir)) trackDirs.add(dir);
  }
  return <String>[
    ...versions,
    for (final String d in trackDirs)
      if (!versions.contains(d)) d,
  ];
}

/// 一个根目录里认出的最佳盘面图（绝对路径 + 得分）。
typedef MusicDiscArtHit = ({String path, int score});

/// 列 [root] 根下的文件与扫图收纳目录（下探两层），挑出最佳盘面图。目录不存在或读不了
/// （权限 / 已拔出的移动盘）时没有盘面图。在后台 isolate 里跑。
MusicDiscArtHit? _scanRoot(String root) {
  final Directory dir = Directory(root);
  if (!dir.existsSync()) return null;
  final Map<String, String> byRelative = <String, String>{};
  try {
    for (final FileSystemEntity e in dir.listSync(followLinks: false)) {
      final String name = p.basename(e.path);
      if (e is File) {
        byRelative[name] = e.path;
      } else if (e is Directory && isMusicScanDirectoryName(name)) {
        for (final FileSystemEntity f in e.listSync(
          recursive: true,
          followLinks: false,
        )) {
          if (f is! File) continue;
          final String rel = p.relative(f.path, from: root);
          if (p.split(rel).length > 3) continue;
          byRelative[rel] = f.path;
        }
      }
    }
  } on FileSystemException {
    return null;
  }
  final String? best = pickMusicDiscArt(byRelative.keys);
  if (best == null) return null;
  return (path: byRelative[best]!, score: musicDiscArtScore(best)!);
}

Map<String, MusicDiscArtHit?> _scanRoots(List<String> roots) =>
    <String, MusicDiscArtHit?>{for (final String r in roots) r: _scanRoot(r)};

/// 曲库的盘面图索引：专辑 uid → 盘面扫描图的本地路径。
///
/// 按专辑目录（[musicAlbumDiscArtRoots]）在后台 isolate 里列目录识别，结果按目录
/// 缓存在进程里：曲库快照每次重读（播放计数等表变更也会触发）只扫没见过的目录。
/// 用户重扫曲库 / 加了文件夹后调 [invalidate]，下次重读时重新识别。
class MusicDiscArtIndex {
  MusicDiscArtIndex._();

  static final MusicDiscArtIndex instance = MusicDiscArtIndex._();

  final Map<String, MusicDiscArtHit?> _byRoot = <String, MusicDiscArtHit?>{};

  /// 缓存代数：[invalidate] 加一。进行中的 [resolve] 若在它之前起扫，扫完的结果
  /// 是重扫前的目录状态，不写回缓存（否则会把旧结果塞回刚清空的缓存）。
  int _generation = 0;

  /// 丢掉缓存（重扫 / 加文件夹后）。
  void invalidate() {
    _generation++;
    _byRoot.clear();
  }

  /// [tracksByAlbum]：专辑 uid → 该专辑曲目的路径。返回有盘面图的专辑。
  Future<Map<String, String>> resolve(
    Map<String, List<String>> tracksByAlbum,
  ) async {
    final int startGeneration = _generation;
    final Map<String, List<String>> rootsByAlbum = <String, List<String>>{
      for (final MapEntry<String, List<String>> e in tracksByAlbum.entries)
        e.key: musicAlbumDiscArtRoots(e.value),
    };
    final List<String> unknown = <String>{
      for (final List<String> roots in rootsByAlbum.values)
        for (final String r in roots)
          if (!_byRoot.containsKey(r)) r,
    }.toList(growable: false);
    final Map<String, MusicDiscArtHit?> scanned = unknown.isEmpty
        ? const <String, MusicDiscArtHit?>{}
        : await Isolate.run(() => _scanRoots(unknown));
    final int generation = _generation;
    if (unknown.isNotEmpty && generation == startGeneration) {
      _byRoot.addAll(scanned);
    }
    final Map<String, String> out = <String, String>{};
    for (final MapEntry<String, List<String>> e in rootsByAlbum.entries) {
      MusicDiscArtHit? best;
      for (final String root in e.value) {
        final MusicDiscArtHit? hit = scanned.containsKey(root)
            ? scanned[root]
            : _byRoot[root];
        if (hit != null && (best == null || hit.score > best.score)) best = hit;
      }
      if (best != null) out[e.key] = best.path;
    }
    return out;
  }
}
