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
/// **存放方式**：不落库，按专辑目录现场列目录识别。`media_images`
/// （`MediaImageKind.discArt`）的单一归属 CHECK 只允许合集 / 视频两种归属，挂不到
/// `music_albums` 上（`music_tables.dart` 的 `coverPath` 注释同一原因）。列目录便宜，
/// 每个进程第一次读快照时重列一次（文件增删立即生效）；贵的是解码——按内容判扫图与
/// 量盘面几何——两者按图片文件（路径 + 大小 + 修改时间）落盘缓存在
/// [MusicDiscArtStore]（app 缓存目录；BUG-5311：原先只在进程里，冷启动每次重解码，
/// 唱片要等一会才出来）。
/// 现场识别只读本地目录：远程来源（SFTP / WebDAV / 服务器）的专辑不认盘面图。
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show SynchronousFuture, ValueNotifier, immutable, visibleForTesting;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/music/music_disc_art_store.dart';

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

/// 专辑名的比较键：全角 ASCII（`＊` / `！` / `Ａ`）折成半角、全角空格折成空格、
/// 连续空白并一个、去首尾、小写。纯函数。
String musicAlbumTitleKey(String title) {
  final StringBuffer out = StringBuffer();
  for (final int rune in title.runes) {
    if (rune >= 0xFF01 && rune <= 0xFF5E) {
      out.writeCharCode(rune - 0xFEE0);
    } else if (rune == 0x3000) {
      out.write(' ');
    } else {
      out.writeCharCode(rune);
    }
  }
  return out.toString().toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// 盘面图在同一张专辑的各版本间共享（BUG-5058）。
///
/// 同一张专辑的两份目录（`(flac+webp)` 带扫图、`[24bit_96kHz] (flac)` 不带）专辑艺人
/// 标签一致时扫描器合成一个专辑 uid，[MusicDiscArtIndex.resolve] 按全部版本目录找图，
/// 本来就共享；标签不一致（一份有专辑艺人一份没有、`＊` 与 `*`、艺人笔误）时被拆成
/// 两张专辑，没扫图的那份就没有盘面。这里把「专辑名比较键（[musicAlbumTitleKey]）
/// 相同、且有版本目录（[musicTrackVersionDirectory]）在同一个父目录下」的专辑视为
/// 同一张的不同版本：没有盘面图的借用有图的那份。只看同一父目录，不跨目录按同名
/// 匹配（不同作品的同名专辑不串图）。
///
/// [found]：已认出的盘面图（专辑 uid → 图路径）；[albums]：专辑 uid →（专辑名，
/// 曲目路径）。返回补全后的映射；同一组里有多份图时取专辑 uid 字典序最小的那份
/// （结果稳定）。纯函数。
Map<String, String> shareMusicDiscArtAcrossVersions({
  required Map<String, String> found,
  required Map<String, ({String title, List<String> trackPaths})> albums,
}) {
  Set<String> keysOf(({String title, List<String> trackPaths}) a) {
    final String title = musicAlbumTitleKey(a.title);
    if (title.isEmpty) return const <String>{};
    return <String>{
      for (final String path in a.trackPaths)
        if (isLocalMusicTrackPath(path))
          '$title\u0000${p.dirname(musicTrackVersionDirectory(path))}',
    };
  }

  final Map<String, String> discByKey = <String, String>{};
  final List<String> withDisc = <String>[
    for (final String uid in albums.keys)
      if (found.containsKey(uid)) uid,
  ]..sort();
  for (final String uid in withDisc) {
    for (final String key in keysOf(albums[uid]!)) {
      discByKey.putIfAbsent(key, () => found[uid]!);
    }
  }
  if (discByKey.isEmpty) return found;
  final Map<String, String> out = Map<String, String>.of(found);
  for (final MapEntry<String, ({String title, List<String> trackPaths})> e
      in albums.entries) {
    if (out.containsKey(e.key)) continue;
    for (final String key in keysOf(e.value)) {
      final String? disc = discByKey[key];
      if (disc != null) {
        out[e.key] = disc;
        break;
      }
    }
  }
  return out;
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
///
/// [size] 是降采样边长；[squareOnly] 为 false 时不按宽高比提前放弃（量盘面几何
/// [MusicDiscFaceGeometryCache] 用：已认定是盘面的图照样要量）。
Future<MusicDiscFaceSample?> sampleMusicDiscFace(
  String path, {
  int size = kMusicDiscFaceSampleSize,
  bool squareOnly = true,
}) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    buffer = await ui.ImmutableBuffer.fromFilePath(path);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final int width = descriptor.width;
    final int height = descriptor.height;
    if (width <= 0 || height <= 0) return null;
    if (squareOnly && !isMusicDiscFaceAspect(width, height)) return null;
    codec = await descriptor.instantiateCodec(
      targetWidth: size,
      targetHeight: size,
    );
    image = (await codec.getNextFrame()).image;
    final ByteData? data = await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    if (data == null) return null;
    return MusicDiscFaceSample(
      sourceWidth: width,
      sourceHeight: height,
      size: size,
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

/// 一张图片文件：绝对路径 + 文件身份（落盘缓存按它判「文件变没变」）。
typedef _StampedFile = ({String path, MusicDiscArtFileStamp stamp});

/// 一个根目录的列目录结果：按文件名认出的最佳盘面图，以及（认不出时）按内容判的
/// 候选（自然序）。
typedef _RootScan = ({MusicDiscArtHit? hit, List<_StampedFile> faceCandidates});

const _RootScan _emptyRootScan = (hit: null, faceCandidates: <_StampedFile>[]);

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
      faceCandidates: const <_StampedFile>[],
    );
  }
  final List<_StampedFile> candidates = <_StampedFile>[];
  for (final String rel in musicDiscFaceCandidates(
    byRelative.keys,
  ).take(kMusicDiscFaceMaxCandidates)) {
    final String path = byRelative[rel]!;
    final MusicDiscArtFileStamp? stamp = musicDiscArtFileStampSync(path);
    if (stamp != null) candidates.add((path: path, stamp: stamp));
  }
  return (hit: null, faceCandidates: candidates);
}

Map<String, _RootScan> _scanRoots(List<String> roots) => <String, _RootScan>{
  for (final String r in roots) r: _scanRoot(r),
};

/// 曲库的盘面图索引：专辑 uid → 盘面扫描图的本地路径。
///
/// 按专辑目录（[musicAlbumDiscArtRoots]）在后台 isolate 里列目录识别，结果按目录
/// 缓存在进程里：曲库快照每次重读（播放计数等表变更也会触发）只扫没见过的目录。
/// 用户重扫曲库 / 加了文件夹后调 [invalidate]，下次重读时重新列目录。按内容判扫图
/// 的结论另按图片文件落盘（[MusicDiscArtStore]），重列 / 冷启动时文件没变就不再解码。
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

  /// 按自然序逐张判 [candidates]，第一张像光盘的就是盘面图（第一张盘）。文件没变
  /// 的图直接用落盘的结论，不再解码。
  Future<MusicDiscArtHit?> _faceHit(List<_StampedFile> candidates) async {
    final MusicDiscArtStore store = MusicDiscArtStore.instance;
    for (final _StampedFile file in candidates) {
      bool? isFace = store.faceVerdict(file.path, file.stamp);
      if (isFace == null) {
        final MusicDiscFaceSample? sample = await sampler(file.path);
        isFace = sample != null && isMusicDiscFace(sample);
        store.putFaceVerdict(file.path, file.stamp, isFace);
      }
      if (isFace) return (path: file.path, score: kMusicDiscFaceScore);
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
    if (listed.isNotEmpty) {
      await MusicDiscArtStore.instance.ensureLoaded();
      _forgetStaleVerdicts(listed);
    }
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
    // 发布前先把落盘的几何认领进进程缓存：卡片首帧就按真实盘面画，不再等解码。
    await MusicDiscFaceGeometryCache.instance.preload(out.values.toSet());
    return out;
  }

  /// 重新列过的根目录里、已不再是候选的图（删了 / 改名 / 改由文件名命中）：落盘结论
  /// 一并去掉，缓存不随曲库变动无限长。
  void _forgetStaleVerdicts(Map<String, _RootScan> listed) {
    // 本轮所有重列根的候选取并集：同一张图可能同时落在两个嵌套根（`Album` 与
    // `Album/CD2`）的扫描范围里，只要任一根还把它当候选就留着，不能拿离它最近的
    // 那个根单独判（否则那个根改由文件名命中时，外层根的候选结论每次启动都被删、
    // 每次都重解码）。
    final Set<String> live = <String>{
      for (final _RootScan scan in listed.values)
        for (final _StampedFile f in scan.faceCandidates) f.path,
    };
    MusicDiscArtStore.instance.removeFaceVerdictsWhere((String path) {
      if (live.contains(path)) return false;
      // 候选最深在根下三层（`Scans/Disc/01.jpg`）。
      String dir = p.dirname(path);
      for (int depth = 0; depth < 3; depth++) {
        if (listed.containsKey(dir)) return true;
        // 离它最近的根是本轮没重列的已知根（另一张专辑的嵌套目录）：结论归那个根
        // 管，这轮不动。
        if (_byRoot.containsKey(dir)) return false;
        final String parent = p.dirname(dir);
        if (parent == dir) break;
        dir = parent;
      }
      return false;
    });
  }
}

/// 印刷区外径占盘径的比例：CD 规格可印刷区最大直径 116mm / 盘径 120mm。外面那
/// 1～2mm 是透明塑料边，平放扫描时透出底板，画出来就是盘外一圈白（用户
/// 2026-11-22：「外面还是白色」）。
const double kMusicDiscPrintFraction = 116 / 120;

/// 中心轴孔半径占印刷区半径的比例：轴孔直径 15mm / 印刷区直径 116mm。
const double kMusicDiscSpindleFraction = 15 / 116;

/// 透明轮毂外缘（印刷区内缘）占印刷区半径比例的下限：量不出时也取它。留出轴孔
/// 外一圈夹持环。
const double kMusicDiscHubMinFraction = 0.18;

/// 透明轮毂外缘占印刷区半径比例的上限：规格可印刷区最小内径 46mm 再放一点。
const double kMusicDiscHubMaxFraction = 0.42;

/// 量盘面几何时的降采样边长（1 个采样像素 ≈ 盘径的 0.4%）。
const int kMusicDiscGeometrySampleSize = 256;

/// 盘面扫描图里光盘的位置（用户 2026-11-22：「没有对准」）：扫描图里的盘不一定在
/// 图片正中、也不一定内切（扫描仪底板留边不均），按内切圆裁出来转动会晃、外圈
/// 露白。
///
/// 坐标都是原图的比例：[centerX] / [radiusX] 按原图宽，[centerY] / [radiusY]
/// 按原图高（非正方形扫图也能直接换算）。半径是**印刷区**半径（已去掉透明塑料边）。
/// [hubFraction] 是印刷区内缘 / 印刷区半径：内缘以内是透明轮毂，画成透明。
@immutable
class MusicDiscFaceGeometry {
  const MusicDiscFaceGeometry({
    required this.centerX,
    required this.centerY,
    required this.radiusX,
    required this.radiusY,
    required this.hubFraction,
  });

  /// 量不出时的退路：盘内切于原图（[width] × [height]），印刷区按规格比例。
  factory MusicDiscFaceGeometry.inscribed(int width, int height) {
    if (width <= 0 || height <= 0) return fallback;
    final double r = math.min(width, height) / 2 * kMusicDiscPrintFraction;
    return MusicDiscFaceGeometry(
      centerX: 0.5,
      centerY: 0.5,
      radiusX: r / width,
      radiusY: r / height,
      hubFraction: kMusicDiscHubMinFraction,
    );
  }

  /// 原图读不了时的退路（正方形内切）。
  static const MusicDiscFaceGeometry fallback = MusicDiscFaceGeometry(
    centerX: 0.5,
    centerY: 0.5,
    radiusX: 0.5 * kMusicDiscPrintFraction,
    radiusY: 0.5 * kMusicDiscPrintFraction,
    hubFraction: kMusicDiscHubMinFraction,
  );

  final double centerX;
  final double centerY;
  final double radiusX;
  final double radiusY;
  final double hubFraction;

  @override
  bool operator ==(Object other) =>
      other is MusicDiscFaceGeometry &&
      other.centerX == centerX &&
      other.centerY == centerY &&
      other.radiusX == radiusX &&
      other.radiusY == radiusY &&
      other.hubFraction == hubFraction;

  @override
  int get hashCode =>
      Object.hash(centerX, centerY, radiusX, radiusY, hubFraction);

  @override
  String toString() =>
      'MusicDiscFaceGeometry(c: ${centerX.toStringAsFixed(4)}, '
      '${centerY.toStringAsFixed(4)}, r: ${radiusX.toStringAsFixed(4)}, '
      '${radiusY.toStringAsFixed(4)}, hub: ${hubFraction.toStringAsFixed(3)})';
}

/// 与背景色的距离超过它算「盘上的像素」（印刷色远在它以外）。
const double _kDiscInkDistance = 36;

/// 量 [sample] 里光盘的位置（[MusicDiscFaceGeometry]）；量不出（全图都是背景、
/// 或盘上像素的外接框不像圆）为 null。纯函数。
///
/// - 背景色：内切圆外（r > 1.1）各通道中位数，同 [isMusicDiscFace]；
/// - 盘的外接框：盘上像素（离背景色 > 36）占本行 / 本列 2% 以上的行列范围，其
///   中心即盘心、半宽半高的均值即盘半径（含透明塑料边——边上有反光与阴影，离
///   背景色不近）。印刷区半径按规格比例 [kMusicDiscPrintFraction] 收进去；
/// - 轮毂：以盘心为圆心逐圈（1 个采样像素宽）统计盘上像素占比，从 0.06 半径往外
///   第一圈「本圈及往外 3 圈都 ≥ 85%」的再往外一圈就是印刷区内缘（孔边阴影那种一两圈宽的
///   细环不算）；量不出或越界按 [kMusicDiscHubMinFraction] /
///   [kMusicDiscHubMaxFraction] 夹住。
MusicDiscFaceGeometry? measureMusicDiscFace(MusicDiscFaceSample sample) {
  final int n = sample.size;
  final Uint8List px = sample.rgba;
  if (n < 32 || px.length < n * n * 4) return null;
  if (sample.sourceWidth <= 0 || sample.sourceHeight <= 0) return null;
  final double c = (n - 1) / 2;
  final double half = n / 2;

  final List<int> rs = <int>[];
  final List<int> gs = <int>[];
  final List<int> bs = <int>[];
  for (int y = 0; y < n; y++) {
    for (int x = 0; x < n; x++) {
      final double dx = x - c;
      final double dy = y - c;
      if (math.sqrt(dx * dx + dy * dy) / half <= 1.1) continue;
      final int i = (y * n + x) * 4;
      rs.add(px[i]);
      gs.add(px[i + 1]);
      bs.add(px[i + 2]);
    }
  }
  if (rs.isEmpty) return null;
  int median(List<int> v) => (v..sort())[v.length ~/ 2];
  final int br = median(rs);
  final int bg = median(gs);
  final int bb = median(bs);

  final Uint8List ink = Uint8List(n * n);
  final List<int> rowInk = List<int>.filled(n, 0);
  final List<int> colInk = List<int>.filled(n, 0);
  const double limit = _kDiscInkDistance * _kDiscInkDistance;
  for (int y = 0; y < n; y++) {
    for (int x = 0; x < n; x++) {
      final int i = (y * n + x) * 4;
      final int dr = px[i] - br;
      final int dg = px[i + 1] - bg;
      final int db = px[i + 2] - bb;
      if (dr * dr + dg * dg + db * db > limit) {
        ink[y * n + x] = 1;
        rowInk[y]++;
        colInk[x]++;
      }
    }
  }
  final int need = math.max(2, (n * 0.02).floor());
  final int top = rowInk.indexWhere((int v) => v >= need);
  final int left = colInk.indexWhere((int v) => v >= need);
  if (top < 0 || left < 0) return null;
  final int bottom = rowInk.lastIndexWhere((int v) => v >= need);
  final int right = colInk.lastIndexWhere((int v) => v >= need);

  // 采样坐标（像素 i 占 [i, i+1)）→ 原图像素：非正方形原图两轴缩放不同。
  final double sx = sample.sourceWidth / n;
  final double sy = sample.sourceHeight / n;
  final double cx = (left + right + 1) / 2;
  final double cy = (top + bottom + 1) / 2;
  final double rx = (right - left + 1) / 2 * sx;
  final double ry = (bottom - top + 1) / 2 * sy;
  final double ratio = rx / ry;
  if (ratio < 0.9 || ratio > 1 / 0.9) return null;
  final double outer = (rx + ry) / 2;
  if (outer < math.min(sample.sourceWidth, sample.sourceHeight) * 0.2) {
    return null;
  }

  // 逐圈盘上像素占比（圈宽 = 1 个采样像素）。
  final double step = math.max(sx, sy);
  final int rings = (outer / step).floor() + 2;
  final List<int> total = List<int>.filled(rings, 0);
  final List<int> hit = List<int>.filled(rings, 0);
  for (int y = 0; y < n; y++) {
    final double dy = (y + 0.5 - cy) * sy;
    for (int x = 0; x < n; x++) {
      final double dx = (x + 0.5 - cx) * sx;
      final int ring = (math.sqrt(dx * dx + dy * dy) / step).floor();
      if (ring >= rings) continue;
      total[ring]++;
      hit[ring] += ink[y * n + x];
    }
  }
  bool dense(int ring) =>
      ring >= rings || (total[ring] > 0 && hit[ring] / total[ring] >= 0.85);
  double? innerEdge;
  for (int ring = 0; ring < rings; ring++) {
    final double r = ring * step;
    if (r < outer * 0.06) continue;
    if (r > outer * 0.5) break;
    if (dense(ring) && dense(ring + 1) && dense(ring + 2) && dense(ring + 3)) {
      // 判到的那圈常还掺着轮毂的底板色（半个采样像素），再往外一圈才是干净的印刷。
      innerEdge = r + step;
      break;
    }
  }
  final double print = outer * kMusicDiscPrintFraction;
  final double hub = innerEdge == null
      ? kMusicDiscHubMinFraction
      : (innerEdge / print).clamp(
          kMusicDiscHubMinFraction,
          kMusicDiscHubMaxFraction,
        );
  return MusicDiscFaceGeometry(
    centerX: cx / n,
    centerY: cy / n,
    radiusX: print / sample.sourceWidth,
    radiusY: print / sample.sourceHeight,
    hubFraction: hub,
  );
}

/// 盘面扫描图的几何缓存（路径 → [MusicDiscFaceGeometry]）：每张图量一次，进程内
/// 缓存，并按图片文件身份落盘（[MusicDiscArtStore]），冷启动文件没变就不再解码。
/// 曲库卡、播放页、CD 详情页共用。
class MusicDiscFaceGeometryCache {
  MusicDiscFaceGeometryCache._();

  static final MusicDiscFaceGeometryCache instance =
      MusicDiscFaceGeometryCache._();

  final Map<String, MusicDiscFaceGeometry> _done =
      <String, MusicDiscFaceGeometry>{};
  final Map<String, Future<MusicDiscFaceGeometry>> _pending =
      <String, Future<MusicDiscFaceGeometry>>{};

  /// 读图降采样的实现（测试换成不碰引擎解码的假实现）。
  @visibleForTesting
  MusicDiscFaceSampler sampler = _sampleForGeometry;

  static Future<MusicDiscFaceSample?> _sampleForGeometry(String path) =>
      sampleMusicDiscFace(
        path,
        size: kMusicDiscGeometrySampleSize,
        squareOnly: false,
      );

  /// 已量好的几何；还没量为 null。
  MusicDiscFaceGeometry? peek(String path) => _done[path];

  /// 量 [path]（同一路径只量一次）。读不了 / 量不出给退路几何，不抛。
  Future<MusicDiscFaceGeometry> load(String path) {
    final MusicDiscFaceGeometry? done = _done[path];
    if (done != null) return SynchronousFuture<MusicDiscFaceGeometry>(done);
    return _pending.putIfAbsent(path, () => _measure(path));
  }

  /// 把 [paths] 落盘过、文件没变的几何认领进进程缓存（[peek] 随即可用）；没量过 /
  /// 文件变了的不量（等 [load]）。
  Future<void> preload(Set<String> paths) async {
    final List<String> todo = <String>[
      for (final String path in paths)
        if (!_done.containsKey(path)) path,
    ];
    if (todo.isEmpty) return;
    final MusicDiscArtStore store = MusicDiscArtStore.instance;
    await store.ensureLoaded();
    for (final String path in todo) {
      final MusicDiscArtFileStamp? stamp = await musicDiscArtFileStamp(path);
      if (stamp == null) continue;
      final MusicDiscFaceGeometry? g = _fromStore(store.geometry(path, stamp));
      if (g != null) _done.putIfAbsent(path, () => g);
    }
  }

  Future<MusicDiscFaceGeometry> _measure(String path) async {
    final MusicDiscArtStore store = MusicDiscArtStore.instance;
    await store.ensureLoaded();
    final MusicDiscArtFileStamp? stamp = await musicDiscArtFileStamp(path);
    MusicDiscFaceGeometry? geometry = stamp == null
        ? null
        : _fromStore(store.geometry(path, stamp));
    if (geometry == null) {
      final MusicDiscFaceSample? sample = await sampler(path);
      geometry = sample == null
          ? MusicDiscFaceGeometry.fallback
          : await Isolate.run(() => measureMusicDiscFace(sample)) ??
                MusicDiscFaceGeometry.inscribed(
                  sample.sourceWidth,
                  sample.sourceHeight,
                );
      // 读不了的图（sample 为 null）不落盘：可能只是暂时读不到（移动盘未挂）。
      if (stamp != null && sample != null) {
        store.putGeometry(path, stamp, <double>[
          geometry.centerX,
          geometry.centerY,
          geometry.radiusX,
          geometry.radiusY,
          geometry.hubFraction,
        ]);
      }
    }
    _done[path] = geometry;
    _pending.remove(path);
    return geometry;
  }

  static MusicDiscFaceGeometry? _fromStore(List<double>? g) => g == null
      ? null
      : MusicDiscFaceGeometry(
          centerX: g[0],
          centerY: g[1],
          radiusX: g[2],
          radiusY: g[3],
          hubFraction: g[4],
        );

  /// 丢掉缓存（扫图文件被替换后）。
  @visibleForTesting
  void invalidate() {
    _done.clear();
    _pending.clear();
  }
}
