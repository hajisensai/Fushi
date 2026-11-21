/// 专辑目录里的盘面扫描图（设计稿 M3：带盘面图的专辑画成「封面 + 唱片」色块）。
///
/// 抓轨 / 扫图目录的常见习惯：盘面图与音频放在同一目录（`disc.jpg` / `cd.png` /
/// `cdart.png` / `Disc 1.jpg` / `label.jpg`），或收在扫图子目录里（`Scans/CD.jpg`、
/// `Artwork/disc1.png`、`Scans/Disc/01.jpg`）。识别规则是纯函数
/// （[musicDiscArtScore] / [pickMusicDiscArt]），文件系统只在 [MusicDiscArtIndex] 里碰。
///
/// **按内容认**（2026-11-21，BUG-5057）：VCB-Studio 等
/// 压制组的扫图目录只有编号（`Scans/01.webp`、`SCAN_06.webp`、`BK/Scan 120.jpg`），
/// 文件名里没有盘面词。文件名认不出时，扫图目录里的图按内容判（[isMusicDiscFace]）：
/// 近似正方形、四角是均匀背景、中心孔透出背景、圆周内外反差明显——即「平放扫描的
/// 一张光盘」。像素判据是纯函数，解码在 [sampleMusicDiscFace]（引擎按 96×96 降采样
/// 解码，不在 Dart 堆里解整张大图）。
///
/// **存放方式**：不落库，按专辑目录现场识别、进程内缓存。`media_images`
/// （`MediaImageKind.discArt`）的单一归属 CHECK 只允许合集 / 视频两种归属，挂不到
/// `music_albums` 上（`music_tables.dart` 的 `coverPath` 注释同一原因）；新开列要升
/// schema 且盘面图该由 Rust 扫描器（`native/fushi_music`）在扫描时一并认出，留作后续。
/// 现场识别只读本地目录：远程来源（SFTP / WebDAV / 服务器）的专辑不认盘面图。
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueNotifier, visibleForTesting;
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

/// 整个目录名就是这些时也算扫图收纳目录（EAC 抓轨常见的 `BK` = booklet 扫图；
/// `bk` 作为文件名里的词仍是「背面」部位，见 [_otherPartWords]）。
const Set<String> _scanDirWhole = <String>{'bk'};

/// [name] 是不是扫图收纳目录（`Scans` / `Artwork` / `BK` / `扫图` …）。
bool isMusicScanDirectoryName(String name) =>
    _scanDirWhole.contains(name.trim().toLowerCase()) ||
    _words(name).any(_scanDirWords.contains) ||
    _scanDirCjk.any(name.contains);

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

/// 按内容认出的盘面图得分：低于任何按文件名认出的（≥ 97），同一专辑两种都有时
/// 文件名优先。
const int kMusicDiscFaceScore = 90;

/// 一个根目录最多按内容判几张扫图（编号扫图目录一般十几张，Hi-Res 大目录二十来张）。
const int kMusicDiscFaceMaxCandidates = 48;

/// 按内容判盘面时的降采样边长。
const int kMusicDiscFaceSampleSize = 96;

/// 一张图按内容判盘面的输入：原图宽高 + 降采样成 [size]×[size] 的 RGBA。
class MusicDiscFaceSample {
  const MusicDiscFaceSample({
    required this.sourceWidth,
    required this.sourceHeight,
    required this.size,
    required this.rgba,
  });

  final int sourceWidth;
  final int sourceHeight;
  final int size;

  /// `size * size * 4` 字节，行优先 RGBA。
  final Uint8List rgba;
}

/// 读一张图的 [MusicDiscFaceSample]；不是近似正方形（[isMusicDiscFaceAspect]）或
/// 解不了时为 null。
typedef MusicDiscFaceSampler =
    Future<MusicDiscFaceSample?> Function(String path);

/// 宽高比是否像平放扫描的一张光盘（近似正方形）。纯函数。
bool isMusicDiscFaceAspect(int width, int height) {
  if (width <= 0 || height <= 0) return false;
  final double ratio = width / height;
  return ratio >= 0.95 && ratio <= 1 / 0.95;
}

/// [sample] 是不是一张平放扫描的光盘。纯函数。
///
/// 以内切圆为盘（半径归一化成 1）：
/// - 四角（r > 1.1）是均匀背景：到背景色（四角各通道中位数）的平均距离 < 15；
/// - 中心孔（r < 0.06）透出背景：孔的平均色到背景色 < 45；
/// - 圆周有边：盘缘内侧（0.92–0.97）比外侧（1.03–1.1）离背景色远 18 以上。
///
/// 阈值在真实扫图上标定（VCB-Studio / EAC 扫图 19 个目录，盘面全中；圆形 INDEX
/// 内页、特典卡、托盘照、跨页均不中）。
bool isMusicDiscFace(MusicDiscFaceSample sample) {
  if (!isMusicDiscFaceAspect(sample.sourceWidth, sample.sourceHeight)) {
    return false;
  }
  final int n = sample.size;
  final Uint8List px = sample.rgba;
  if (n < 32 || px.length < n * n * 4) return false;
  final double c = (n - 1) / 2;
  final double half = n / 2;
  double radius(int x, int y) =>
      math.sqrt((x - c) * (x - c) + (y - c) * (y - c)) / half;

  final List<int> rs = <int>[];
  final List<int> gs = <int>[];
  final List<int> bs = <int>[];
  for (int y = 0; y < n; y++) {
    for (int x = 0; x < n; x++) {
      if (radius(x, y) <= 1.1) continue;
      final int i = (y * n + x) * 4;
      rs.add(px[i]);
      gs.add(px[i + 1]);
      bs.add(px[i + 2]);
    }
  }
  if (rs.isEmpty) return false;
  int median(List<int> v) => (v..sort())[v.length ~/ 2];
  final int br = median(rs);
  final int bg = median(gs);
  final int bb = median(bs);
  double dist(double r, double g, double b) => math.sqrt(
    (r - br) * (r - br) + (g - bg) * (g - bg) + (b - bb) * (b - bb),
  );

  double cornerSum = 0;
  int cornerN = 0;
  double holeR = 0, holeG = 0, holeB = 0;
  int holeN = 0;
  double rimInSum = 0;
  int rimInN = 0;
  double rimOutSum = 0;
  int rimOutN = 0;
  for (int y = 0; y < n; y++) {
    for (int x = 0; x < n; x++) {
      final double r = radius(x, y);
      final int i = (y * n + x) * 4;
      final double pr = px[i].toDouble();
      final double pg = px[i + 1].toDouble();
      final double pb = px[i + 2].toDouble();
      if (r > 1.1) {
        cornerSum += dist(pr, pg, pb);
        cornerN++;
      } else if (r < 0.06) {
        holeR += pr;
        holeG += pg;
        holeB += pb;
        holeN++;
      } else if (r > 0.92 && r < 0.97) {
        rimInSum += dist(pr, pg, pb);
        rimInN++;
      } else if (r > 1.03) {
        rimOutSum += dist(pr, pg, pb);
        rimOutN++;
      }
    }
  }
  if (cornerN == 0 || holeN == 0 || rimInN == 0 || rimOutN == 0) return false;
  final double corner = cornerSum / cornerN;
  final double hole = dist(holeR / holeN, holeG / holeN, holeB / holeN);
  final double rimIn = rimInSum / rimInN;
  final double rimOut = rimOutSum / rimOutN;
  return corner < 15 && hole < 45 && rimIn - rimOut > 18;
}

/// [MusicDiscFaceSampler] 的默认实现：先只读图头拿宽高（不是近似正方形就不解码），
/// 再让引擎按 [kMusicDiscFaceSampleSize] 降采样解码（JPEG / WebP 走解码器的缩放
/// 解码，几十兆像素的扫图也不在 Dart 堆里展开）。读不了 / 解不了为 null。
Future<MusicDiscFaceSample?> sampleMusicDiscFace(String path) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    buffer = await ui.ImmutableBuffer.fromFilePath(path);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final int width = descriptor.width;
    final int height = descriptor.height;
    if (!isMusicDiscFaceAspect(width, height)) return null;
    codec = await descriptor.instantiateCodec(
      targetWidth: kMusicDiscFaceSampleSize,
      targetHeight: kMusicDiscFaceSampleSize,
    );
    image = (await codec.getNextFrame()).image;
    final ByteData? data = await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    if (data == null) return null;
    return MusicDiscFaceSample(
      sourceWidth: width,
      sourceHeight: height,
      size: kMusicDiscFaceSampleSize,
      rgba: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  } on Object {
    // 损坏 / 不支持的图片、读不了的文件：不当盘面，不打断其余识别。
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

/// [a] / [b] 按「数字段按数值」比较（`Scan 119` < `Scan 120`，`2` < `10`）。纯函数。
int compareMusicNatural(String a, String b) {
  final RegExp chunk = RegExp(r'\d+|\D+');
  final List<String> ca = <String>[
    for (final RegExpMatch m in chunk.allMatches(a.toLowerCase())) m[0]!,
  ];
  final List<String> cb = <String>[
    for (final RegExpMatch m in chunk.allMatches(b.toLowerCase())) m[0]!,
  ];
  for (int i = 0; i < ca.length && i < cb.length; i++) {
    final int? na = int.tryParse(ca[i]);
    final int? nb = int.tryParse(cb[i]);
    final int cmp = na != null && nb != null
        ? na.compareTo(nb)
        : ca[i].compareTo(cb[i]);
    if (cmp != 0) return cmp;
  }
  final int byLength = ca.length.compareTo(cb.length);
  return byLength != 0 ? byLength : a.compareTo(b);
}

/// 扫图收纳目录里、文件名认不出部位的图（相对路径）：按内容判盘面的候选，按自然序
/// 排（第一张盘通常编号在前）。文件名写明是别的部位（`cover` / `back` / `obi` …）的
/// 不进候选。纯函数。
List<String> musicDiscFaceCandidates(Iterable<String> relativePaths) {
  final List<String> out = <String>[];
  for (final String path in relativePaths) {
    final List<String> segments = path
        .split(RegExp(r'[\\/]'))
        .where((String s) => s.isNotEmpty)
        .toList(growable: false);
    if (segments.length < 2 || segments.length > 3) continue;
    final String file = segments.last;
    if (!kMusicDiscArtImageExtensions.contains(
      p.extension(file).toLowerCase(),
    )) {
      continue;
    }
    if (!isMusicScanDirectoryName(segments.first)) continue;
    final List<String> named = <String>[
      ...segments.sublist(1, segments.length - 1),
      p.basenameWithoutExtension(file),
    ];
    if (named.any(_mentionsOtherPart)) continue;
    out.add(path);
  }
  out.sort(compareMusicNatural);
  return out;
}

/// 一个根目录的列目录结果：按文件名认出的最佳盘面图，以及（认不出时）按内容判的
/// 候选（绝对路径，自然序）。
typedef _RootScan = ({MusicDiscArtHit? hit, List<String> faceCandidates});

const _RootScan _emptyRootScan = (hit: null, faceCandidates: <String>[]);

/// 列 [root] 根下的文件与扫图收纳目录（下探两层），挑出按文件名认的最佳盘面图；
/// 认不出时给出按内容判的候选。目录不存在或读不了（权限 / 已拔出的移动盘）时
/// 没有盘面图。在后台 isolate 里跑。
_RootScan _scanRoot(String root) {
  final Directory dir = Directory(root);
  if (!dir.existsSync()) return _emptyRootScan;
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
    return _emptyRootScan;
  }
  final String? best = pickMusicDiscArt(byRelative.keys);
  if (best != null) {
    return (
      hit: (path: byRelative[best]!, score: musicDiscArtScore(best)!),
      faceCandidates: const <String>[],
    );
  }
  return (
    hit: null,
    faceCandidates: <String>[
      for (final String rel in musicDiscFaceCandidates(
        byRelative.keys,
      ).take(kMusicDiscFaceMaxCandidates))
        byRelative[rel]!,
    ],
  );
}

Map<String, _RootScan> _scanRoots(List<String> roots) => <String, _RootScan>{
  for (final String r in roots) r: _scanRoot(r),
};

/// 曲库的盘面图索引：专辑 uid → 盘面扫描图的本地路径。
///
/// 按专辑目录（[musicAlbumDiscArtRoots]）在后台 isolate 里列目录识别，结果按目录
/// 缓存在进程里：曲库快照每次重读（播放计数等表变更也会触发）只扫没见过的目录。
/// 用户重扫曲库 / 加了文件夹后调 [invalidate]，下次重读时重新识别。
class MusicDiscArtIndex {
  MusicDiscArtIndex._();

  static final MusicDiscArtIndex instance = MusicDiscArtIndex._();

  final Map<String, MusicDiscArtHit?> _byRoot = <String, MusicDiscArtHit?>{};

  /// 曲库当前的盘面图（专辑 uid → 图路径）：曲库页每次读完快照、[resolve] 出结果后
  /// 发布到这里（[publish]），是这份映射的唯一持有处。曲库网格、推荐页「最近播放」、
  /// 「继续收听」都读它：没有盘面图的专辑不在里面，就不画唱片（不造假唱片）。
  final ValueNotifier<Map<String, String>> albums =
      ValueNotifier<Map<String, String>>(const <String, String>{});

  /// 发布新的盘面图映射；内容没变不通知。
  void publish(Map<String, String> found) {
    final Map<String, String> current = albums.value;
    if (current.length == found.length &&
        found.entries.every(
          (MapEntry<String, String> e) => current[e.key] == e.value,
        )) {
      return;
    }
    albums.value = Map<String, String>.unmodifiable(found);
  }

  /// 缓存代数：[invalidate] 加一。进行中的 [resolve] 若在它之前起扫，扫完的结果
  /// 是重扫前的目录状态，不写回缓存（否则会把旧结果塞回刚清空的缓存）。
  int _generation = 0;

  /// 丢掉缓存（重扫 / 加文件夹后）。
  void invalidate() {
    _generation++;
    _byRoot.clear();
  }

  /// 按内容判盘面时读图的实现（测试换成不碰引擎解码的假实现）。
  @visibleForTesting
  MusicDiscFaceSampler sampler = sampleMusicDiscFace;

  /// 按自然序逐张判 [candidates]，第一张像光盘的就是盘面图（第一张盘）。
  Future<MusicDiscArtHit?> _faceHit(List<String> candidates) async {
    for (final String path in candidates) {
      final MusicDiscFaceSample? sample = await sampler(path);
      if (sample != null && isMusicDiscFace(sample)) {
        return (path: path, score: kMusicDiscFaceScore);
      }
    }
    return null;
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
    final Map<String, _RootScan> listed = unknown.isEmpty
        ? const <String, _RootScan>{}
        : await Isolate.run(() => _scanRoots(unknown));
    // 文件名认不出的根目录，扫图按内容判（解码交给引擎，逐张串行，不并发解大图）。
    final Map<String, MusicDiscArtHit?> scanned = <String, MusicDiscArtHit?>{};
    for (final MapEntry<String, _RootScan> e in listed.entries) {
      scanned[e.key] =
          e.value.hit ??
          (e.value.faceCandidates.isEmpty
              ? null
              : await _faceHit(e.value.faceCandidates));
    }
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
