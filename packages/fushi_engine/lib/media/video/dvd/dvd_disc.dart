// 一张 DVD（`VIDEO_TS` 目录树，或装着它的 `.iso` 镜像）到「可播放标题列表」的映射，
// 与 `bluray_disc.dart` 同一套思路：盘上 title 表里真正是内容的往往只有几条，其余是
// 厂标、警告、菜单背景、以及把各集串起来的「全部播放」。筛选链（判据取舍见
// `bluray_disc.dart` 文件头）：
//
//   1. 引用不到的 title——它所在 VTS 的 IFO 读不出 / 坏 PGC / 盘上没有它的 title VOB。
//   2. 绝对时长下限（与蓝光同一个 [kBlurayMinimumTitleDuration]）。
//   3. 同签名合并——`(cell 多重集, 总时长)` 相同即同一内容；保留章节多的、号小的。
//   4. 「全部播放」合并——cell 集合恰好等于另外 ≥2 条的并集。
//   5. 相对时长下限（[kBlurayRelativeTitleFloor]），锚点排除 play-all 形状。
//
// 没被选成 title、但仍是一段可独立观看内容的 title 是这张盘的**特典**
// （[selectDvdExtras]，与蓝光 `selectBlurayExtras` 同一规则）：入库、不进盘合集，
// 由索引器挂到正片作品下。
//
// 「片段」在 DVD 上是一段 VTS 内的扇区范围（cell 的首末扇区），不是 cell 号：不同
// PGC 可以各自给同一段扇区编不同的 cell 号，用扇区才能认出「是同一段内容」。
//
// 条目身份（虚拟成员路径）见 `dvd_title_path.dart`。规范里的盘身份是 libdvdread 的
// `DVDDiscID`（[computeDvdDiscId]），条目身份 = 盘身份 + title 号；库里不另存（不改
// schema），由成员路径的盘根随时现算。
//
// 两种盘形态共用同一条解析链：文件夹形态直接读 `VIDEO_TS/*.IFO`，镜像形态经
// `disc_image_probe.dart` 的 UDF / ISO 9660 读取器读出同样的字节（[_VideoTsFiles]）。

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/video/bluray/bluray_disc.dart'
    show kBlurayMinimumTitleDuration, kBlurayRelativeTitleFloor;
import 'package:fushi_engine/media/video/disc/disc_image_probe.dart';
import 'package:fushi_engine/media/video/disc/disc_title_selection.dart';
import 'package:fushi_engine/media/video/dvd/dvd_ifo.dart';
import 'package:fushi_engine/media/video/dvd/dvd_title_path.dart';

export 'package:fushi_engine/media/video/dvd/dvd_title_path.dart';

/// 单个 IFO 的读入上限。实测 IFO 多在几十 KB 到 1 MB，几十 MB 的一律当坏数据。
const int kDvdMaxIfoBytes = 16 * 1024 * 1024;

/// 一张盘上被选中的一个 title（正片 / 各集，或特典）。
class DvdTitle {
  const DvdTitle({
    required this.entry,
    required this.discRootPath,
    required this.name,
    required this.isMainFeature,
    required this.duration,
    required this.cellIds,
  });

  final DvdTitleEntry entry;

  /// 盘根：含 `VIDEO_TS` 的目录，或 `.iso` 文件。
  final String discRootPath;

  /// 展示名，已含盘名。
  final String name;

  /// 是否是这张盘上最长的 title。
  final bool isMainFeature;

  final Duration duration;

  /// 这个 title 依次播放的扇区段（`v<vts>:<首扇区>-<末扇区>`）。
  final List<String> cellIds;

  int get titleNumber => entry.titleNumber;

  int get chapterCount => entry.chapterCount;

  /// 这条 title 的稳定身份（虚拟路径，见 `dvd_title_path.dart`）。
  String get titlePath => dvdTitlePath(discRootPath, entry.titleNumber);
}

/// 一张已读入的 DVD。
class DvdDisc {
  const DvdDisc({
    required this.rootPath,
    required this.name,
    required this.discId,
    required this.vmg,
    required this.titles,
    this.candidates = const <DvdTitleCandidate>[],
    this.extras = const <DvdTitle>[],
    this.volumeLabel,
  });

  /// 盘根：含 `VIDEO_TS` 的目录，或 `.iso` 文件。
  final String rootPath;

  /// 盘名：目录名 / 镜像文件名（去扩展名）。卷标常是 `DVD_VIDEO` 这类占位，不拿它当名。
  final String name;

  /// libdvdread `DVDDiscID` 口径的盘身份（32 位小写十六进制）。
  final String discId;

  final DvdVmgInfo vmg;

  /// 筛选后的 title，按 title 号升序。
  final List<DvdTitle> titles;

  /// 盘上能解析出的全部 title（含被筛掉的），特典划分要用。
  final List<DvdTitleCandidate> candidates;

  /// 这张盘的特典（[selectDvdExtras]），按 title 号升序。入库但不进盘合集。
  final List<DvdTitle> extras;

  /// 镜像的卷标；文件夹形态为 null。
  final String? volumeLabel;

  /// 本卷号 / 卷总数（`vmgi_mat`），多盘排序用；取不到为 1 / 1。
  int get volumeNumber => vmg.volumeNumber;

  int get volumeCount => vmg.volumeCount;
}

/// 多盘排序：同一上级目录里的盘先按卷号（`vmgi_mat` 的本卷号），卷号相同或不同目录
/// 再按盘根路径的字典序（`Disc 1` / `Disc 2` 这类目录名）。纯函数。
int compareDvdDiscOrder(DvdDisc a, DvdDisc b) {
  final String parentA = p.dirname(p.normalize(a.rootPath));
  final String parentB = p.dirname(p.normalize(b.rootPath));
  if (parentA == parentB && a.volumeNumber != b.volumeNumber) {
    return a.volumeNumber.compareTo(b.volumeNumber);
  }
  return a.rootPath.compareTo(b.rootPath);
}

/// 一个 title 投影成筛选链要的形状。
class DvdTitleCandidate {
  const DvdTitleCandidate({
    required this.entry,
    required this.duration,
    required this.cellIds,
    this.chapterStarts = const <Duration>[],
  });

  final DvdTitleEntry entry;
  final Duration duration;
  final List<String> cellIds;

  /// 各章节（PTT）在 title 时间轴上的起点，按章节号升序；program map 缺失 / 对不上时为空
  /// （章节起点不可知，不猜）。音乐「章节导入为曲目」用，入库选片不用。
  final List<Duration> chapterStarts;

  String get _id => entry.titleNumber.toString().padLeft(2, '0');
}

/// 从盘内**文件**路径反推盘根（`<根>/VIDEO_TS/<文件>`）；不是盘内文件返回 null。
///
/// 目录名精确大小写，文件名不分大小写——与 `blurayDiscRootForFile` 同一口径（IO 层
/// 按字面 `VIDEO_TS` 开目录，宽松认出来的盘读不动，整盘反而一条不剩）。
String? dvdDiscRootForFile(String filePath) {
  final List<String> parts = p.split(p.normalize(filePath));
  if (parts.length < 3) return null;
  if (parts[parts.length - 2] != kDvdVideoDirectory) return null;
  return p.joinAll(parts.sublist(0, parts.length - 2));
}

/// 从一批文件路径里认出 DVD 盘根：盘上必须有 `VIDEO_TS/VIDEO_TS.IFO`。纯函数。
List<String> planDvdDiscRoots(Iterable<String> filePaths) {
  final Set<String> roots = <String>{};
  for (final String path in filePaths) {
    if (p.basename(path).toUpperCase() != 'VIDEO_TS.IFO') continue;
    final String? root = dvdDiscRootForFile(path);
    if (root != null) roots.add(root);
  }
  final List<String> sorted = roots.toList()..sort();
  return sorted;
}

/// [filePath] 是否落在 [discRoots] 里某张 DVD 的 `VIDEO_TS` 树下。
///
/// 盘一旦被认出来，`VIDEO_TS` 下的 VOB 不能再各自成为散装视频：它们按 1 GB 边界
/// 切开、混着菜单 VOB，单独入库只是一屏碎片。`VIDEO_TS` 之外的 `.vob` 不受影响。
bool isInsideDvdDisc(String filePath, Set<String> discRoots) {
  if (discRoots.isEmpty) return false;
  final String normalized = p.normalize(filePath);
  for (final String root in discRoots) {
    final String prefix = p.join(root, kDvdVideoDirectory) + p.separator;
    if (normalized.length > prefix.length &&
        normalized.substring(0, prefix.length) == prefix) {
      return true;
    }
  }
  return false;
}

/// [path] 指向一张文件夹形态的 DVD 时返回含 `VIDEO_TS` 的那层目录（接受盘根或
/// `VIDEO_TS` 本身）。
String? dvdDiscRootForDirectory(String path) {
  final String normalized = p.normalize(path);
  if (findDvdVideoTsIfo(normalized) != null) return normalized;
  if (p.basename(normalized) == kDvdVideoDirectory) {
    final String parent = p.dirname(normalized);
    if (findDvdVideoTsIfo(parent) != null) return parent;
  }
  return null;
}

/// 盘根下实际存在的 `VIDEO_TS/VIDEO_TS.IFO`（文件名大小写以盘上为准）；没有返回 null。
String? findDvdVideoTsIfo(String discRootPath) =>
    _listVideoTs(discRootPath)?['VIDEO_TS.IFO'];

/// `VIDEO_TS` 目录里的文件：大写文件名 → 实际路径。目录读不动返回 null。
Map<String, String>? _listVideoTs(String discRootPath) {
  final Directory dir = Directory(p.join(discRootPath, kDvdVideoDirectory));
  try {
    if (!dir.existsSync()) return null;
    return <String, String>{
      for (final FileSystemEntity entity in dir.listSync(followLinks: false))
        if (entity is File) p.basename(entity.path).toUpperCase(): entity.path,
    };
  } on FileSystemException {
    return null;
  }
}

/// `VIDEO_TS` 里的文件来源：文件夹或镜像。名字一律大写。
abstract class _VideoTsFiles {
  bool has(String upperName);

  /// 读 [upperName] 的全部内容；超过 [kDvdMaxIfoBytes] 或读不动抛
  /// [DvdIfoFormatException]。
  Future<Uint8List> read(String upperName);
}

class _FolderVideoTs implements _VideoTsFiles {
  _FolderVideoTs(this._paths);

  final Map<String, String> _paths;

  @override
  bool has(String upperName) => _paths.containsKey(upperName);

  @override
  Future<Uint8List> read(String upperName) async {
    final String? path = _paths[upperName];
    if (path == null) throw DvdIfoFormatException('$upperName not found');
    try {
      final File file = File(path);
      if (await file.length() > kDvdMaxIfoBytes) {
        throw DvdIfoFormatException('$upperName is implausibly large');
      }
      return await file.readAsBytes();
    } on FileSystemException catch (e) {
      throw DvdIfoFormatException('$upperName unreadable: ${e.message}');
    }
  }
}

class _ImageVideoTs implements _VideoTsFiles {
  _ImageVideoTs(this._fs, List<DiscImageEntry> entries)
    : _entries = <String, DiscImageEntry>{
        for (final DiscImageEntry e in entries)
          if (!e.isDirectory) discImagePlainName(e.name): e,
      };

  final DiscImageFileSystem _fs;
  final Map<String, DiscImageEntry> _entries;

  @override
  bool has(String upperName) => _entries.containsKey(upperName);

  @override
  Future<Uint8List> read(String upperName) async {
    final DiscImageEntry? entry = _entries[upperName];
    if (entry == null) throw DvdIfoFormatException('$upperName not found');
    try {
      final Uint8List bytes = _fs.readFile(entry, kDvdMaxIfoBytes + 1);
      if (bytes.length > kDvdMaxIfoBytes) {
        throw DvdIfoFormatException('$upperName is implausibly large');
      }
      return bytes;
    } on DiscImageFormatException catch (e) {
      throw DvdIfoFormatException(
        '$upperName unreadable in image: ${e.message}',
      );
    }
  }
}

/// 读入 [rootPath] 这张盘：含 `VIDEO_TS` 的目录（或 `VIDEO_TS` 本身），或 `.iso`。
///
/// 不是盘、或一条 title 都选不出来时返回 null；`VIDEO_TS.IFO` 与它的备份
/// `VIDEO_TS.BUP` 都损坏时抛 [DvdIfoFormatException]（明确报错，不当成「不是盘」吞掉）。
///
/// [keepWithoutTitles]：入库选片一条都没选出（全部短于入库下限）时仍返回这张盘
/// （[DvdDisc.titles] 为空、[DvdDisc.candidates] 照常）。音乐的「章节导入为曲目」用：MV
/// 合集的单曲 title 可能不足视频入库的一分钟下限。
Future<DvdDisc?> readDvdDisc(
  String rootPath, {
  bool keepWithoutTitles = false,
}) async {
  if (isDiscImagePath(rootPath) &&
      FileSystemEntity.typeSync(rootPath) == FileSystemEntityType.file) {
    return readDvdDiscImage(rootPath, keepWithoutTitles: keepWithoutTitles);
  }
  final String? root = dvdDiscRootForDirectory(rootPath);
  if (root == null) return null;
  final Map<String, String> paths = _listVideoTs(root)!;
  return _readDisc(
    root: root,
    name: p.basename(p.normalize(root)),
    files: _FolderVideoTs(paths),
    keepWithoutTitles: keepWithoutTitles,
  );
}

/// 读入镜像形态的 DVD：打开 `.iso` 的 UDF / ISO 9660，读出 `VIDEO_TS/*.IFO` 字节后走
/// 与文件夹形态同一条解析 / 选片链路。镜像里没有 `VIDEO_TS/VIDEO_TS.IFO`（是 BD 镜像、
/// 数据盘、或根本打不开）返回 null；IFO 两份都坏抛 [DvdIfoFormatException]。
Future<DvdDisc?> readDvdDiscImage(
  String imagePath, {
  bool keepWithoutTitles = false,
}) => withDiscImageFile<DvdDisc?>(imagePath, (DiscImageFileSystem? fs) async {
  if (fs == null) return null;
  final List<DiscImageEntry> inside;
  try {
    final DiscImageEntry? videoTs = findDiscImageEntry(
      fs.listRoot(),
      kDvdVideoDirectory,
      directory: true,
    );
    if (videoTs == null) return null;
    inside = fs.list(videoTs);
  } on DiscImageFormatException {
    return null;
  }
  final _ImageVideoTs files = _ImageVideoTs(fs, inside);
  if (!files.has('VIDEO_TS.IFO') && !files.has('VIDEO_TS.BUP')) return null;
  return _readDisc(
    root: p.normalize(imagePath),
    name: p.basenameWithoutExtension(imagePath),
    files: files,
    volumeLabel: fs.label,
    keepWithoutTitles: keepWithoutTitles,
  );
});

Future<DvdDisc?> _readDisc({
  required String root,
  required String name,
  required _VideoTsFiles files,
  String? volumeLabel,
  bool keepWithoutTitles = false,
}) async {
  final DvdVmgInfo vmg = await _readWithBackup<DvdVmgInfo>(
    files,
    'VIDEO_TS',
    (Uint8List bytes, String name) => parseDvdVmgIfo(bytes),
  );

  // 逐 VTS 读一次（多个 title 共用一个 VTS）。读不动的 VTS 记 null：只剔掉落在它
  // 上面的 title，不连坐整张盘。
  final Map<int, DvdTitleSetInfo?> titleSets = <int, DvdTitleSetInfo?>{};
  for (final DvdTitleEntry entry in vmg.titles) {
    if (titleSets.containsKey(entry.titleSetNumber)) continue;
    final String stem = _vtsStem(entry.titleSetNumber);
    final bool hasVob = files.has('${stem.substring(0, 7)}1.VOB');
    DvdTitleSetInfo? info;
    if (hasVob) {
      try {
        info = await _readWithBackup<DvdTitleSetInfo>(
          files,
          stem,
          (Uint8List bytes, String name) => parseDvdVtsIfo(bytes, name: name),
        );
      } on DvdIfoFormatException {
        info = null;
      }
    }
    titleSets[entry.titleSetNumber] = info;
  }

  final List<DvdTitleCandidate> candidates = <DvdTitleCandidate>[
    for (final DvdTitleEntry entry in vmg.titles)
      if (dvdTitleCandidate(entry, titleSets[entry.titleSetNumber])
          case final DvdTitleCandidate candidate)
        candidate,
  ];

  final List<DvdTitle> titles = selectDvdTitles(
    candidates,
    discRootPath: root,
    discName: name,
  );
  if (titles.isEmpty && (!keepWithoutTitles || candidates.isEmpty)) {
    return null;
  }
  return DvdDisc(
    rootPath: root,
    name: name,
    discId: await _discId(files),
    vmg: vmg,
    titles: List<DvdTitle>.unmodifiable(titles),
    candidates: List<DvdTitleCandidate>.unmodifiable(candidates),
    extras: List<DvdTitle>.unmodifiable(
      selectDvdExtras(
        candidates,
        titles: titles,
        discRootPath: root,
        discName: name,
      ),
    ),
    volumeLabel: volumeLabel,
  );
}

/// `VTS_<nn>_0`（不含扩展名）。
String _vtsStem(int titleSet) => 'VTS_${titleSet.toString().padLeft(2, '0')}_0';

/// 先读 `<stem>.IFO`，解析失败（或不存在）再读 `<stem>.BUP`。
///
/// BUP 是 DVD 规范里 IFO 的逐字节备份，就是为「IFO 所在扇区读坏」准备的，libdvdread
/// 同样按这个顺序回退。两份都坏才报错，报 IFO 的那条原因。
Future<T> _readWithBackup<T>(
  _VideoTsFiles files,
  String stem,
  T Function(Uint8List bytes, String name) parse,
) async {
  DvdIfoFormatException? first;
  for (final String ext in <String>['IFO', 'BUP']) {
    final String name = '$stem.$ext';
    if (!files.has(name)) continue;
    try {
      return parse(await files.read(name), name);
    } on DvdIfoFormatException catch (e) {
      first ??= e;
    }
  }
  throw first ?? DvdIfoFormatException('$stem.IFO not found');
}

/// 把 TT_SRPT 的一行投影成筛选候选；它所在的 VTS 读不出、引用了坏 PGC 时返回 null。
DvdTitleCandidate? dvdTitleCandidate(
  DvdTitleEntry entry,
  DvdTitleSetInfo? titleSet,
) {
  if (titleSet == null) return null;
  final List<int> pgcs = titleSet.programChainNumbersForTitle(
    entry.titleSetTitleNumber,
  );
  if (pgcs.isEmpty) return null;
  Duration duration = Duration.zero;
  final List<String> cellIds = <String>[];
  // 每条 PGC 在 title 时间轴上的起点（章节起点 = 所在 PGC 起点 + 入口 cell 在 PGC 内的偏移）。
  final Map<int, Duration> pgcStart = <int, Duration>{};
  for (final int pgcNumber in pgcs) {
    final DvdProgramChain? pgc = titleSet.programChains[pgcNumber - 1];
    if (pgc == null) return null;
    Duration pgcTime = pgc.playbackTime;
    if (pgcTime == Duration.zero) {
      // 有的写盘工具不填 PGC 头的总时长，只填 cell 的；那就按 cell 累加。
      for (final DvdCell cell in pgc.cells) {
        pgcTime += cell.playbackTime;
      }
    }
    pgcStart[pgcNumber] = duration;
    duration += pgcTime;
    for (final DvdCell cell in pgc.cells) {
      cellIds.add(
        'v${entry.titleSetNumber}:${cell.firstSector}-${cell.lastSector}',
      );
    }
  }
  if (cellIds.isEmpty) return null;
  return DvdTitleCandidate(
    entry: entry,
    duration: duration,
    cellIds: List<String>.unmodifiable(cellIds),
    chapterStarts: _chapterStarts(titleSet, entry, pgcStart),
  );
}

/// 一个 title 各章节的起点；任何一个章节的入口 cell 定不下来就整体返回空（半截章节表
/// 会让后面的曲目整体错位，比没有更糟）。
List<Duration> _chapterStarts(
  DvdTitleSetInfo titleSet,
  DvdTitleEntry entry,
  Map<int, Duration> pgcStart,
) {
  final int index = entry.titleSetTitleNumber - 1;
  if (index < 0 || index >= titleSet.partsByTitle.length) {
    return const <Duration>[];
  }
  final List<Duration> starts = <Duration>[];
  for (final DvdPartOfTitle part in titleSet.partsByTitle[index]) {
    final DvdProgramChain? pgc = titleSet.programChains[part.pgcNumber - 1];
    final Duration? base = pgcStart[part.pgcNumber];
    final int? cell = pgc?.entryCellOf(part.programNumber);
    if (pgc == null || base == null || cell == null) return const <Duration>[];
    final Duration start = base + pgc.offsetOfCell(cell);
    // 章节号单调：起点倒退说明 PTT 表指回了前面（含跳转命令的 title），时间轴不可知。
    if (starts.isNotEmpty && start < starts.last) return const <Duration>[];
    starts.add(start);
  }
  return List<Duration>.unmodifiable(starts);
}

List<String> _cellIdsOf(DvdTitleCandidate candidate) => candidate.cellIds;

int _durationOf(DvdTitleCandidate candidate) =>
    candidate.duration.inMilliseconds;

bool _prefers(DvdTitleCandidate candidate, DvdTitleCandidate incumbent) =>
    discPrefersOver(
      candidateChapters: candidate.entry.chapterCount,
      candidateId: candidate._id,
      incumbentChapters: incumbent.entry.chapterCount,
      incumbentId: incumbent._id,
    );

String _signature(DvdTitleCandidate c) =>
    discContentSignature(c.cellIds, c.duration.inMilliseconds);

/// 从候选里挑出该进库的 title。纯函数，筛选链见文件头。
List<DvdTitle> selectDvdTitles(
  List<DvdTitleCandidate> candidates, {
  required String discRootPath,
  required String discName,
  Duration minimumDuration = kBlurayMinimumTitleDuration,
  double relativeDurationFloor = kBlurayRelativeTitleFloor,
}) {
  final List<DvdTitleCandidate> eligible = <DvdTitleCandidate>[
    for (final DvdTitleCandidate c in candidates)
      if (c.duration >= minimumDuration && c.cellIds.isNotEmpty) c,
  ];
  if (eligible.isEmpty) return const <DvdTitle>[];

  final Map<String, DvdTitleCandidate> bySignature =
      <String, DvdTitleCandidate>{};
  for (final DvdTitleCandidate c in eligible) {
    final DvdTitleCandidate? existing = bySignature[_signature(c)];
    if (existing == null || _prefers(c, existing)) {
      bySignature[_signature(c)] = c;
    }
  }
  List<DvdTitleCandidate> unique = bySignature.values.toList(growable: false);
  unique = unique
      .where(
        (DvdTitleCandidate c) =>
            !discIsPlayAllOf<DvdTitleCandidate>(c, unique, _cellIdsOf),
      )
      .toList(growable: false);
  if (unique.isEmpty) return const <DvdTitle>[];

  final int longest = discRelativeFloorAnchor<DvdTitleCandidate>(
    unique,
    _cellIdsOf,
    _durationOf,
  );
  final int floor = (longest * relativeDurationFloor).round();
  final List<DvdTitleCandidate> kept =
      unique.where((DvdTitleCandidate c) => _durationOf(c) >= floor).toList()
        ..sort(
          (DvdTitleCandidate a, DvdTitleCandidate b) =>
              a.entry.titleNumber.compareTo(b.entry.titleNumber),
        );
  if (kept.isEmpty) return const <DvdTitle>[];

  final bool single = kept.length == 1;
  return <DvdTitle>[
    for (int i = 0; i < kept.length; i++)
      DvdTitle(
        entry: kept[i].entry,
        discRootPath: discRootPath,
        name: single
            ? discName
            : '$discName - ${(i + 1).toString().padLeft(2, '0')}',
        isMainFeature: _durationOf(kept[i]) == longest,
        duration: kept[i].duration,
        cellIds: kept[i].cellIds,
      ),
  ];
}

/// 特典在库里的名字：`<盘名> - T<nn>`（nn = title 号）。带 `T` 是为了不与正片的
/// `<盘名> - 01` 顺序编号撞名（蓝光特典用 5 位 MPLS 号，天然不撞）。
String dvdExtraTitleName(String discName, int titleNumber) =>
    '$discName - T${titleNumber.toString().padLeft(2, '0')}';

/// 从候选里挑出特典。纯函数，与 `selectBlurayExtras` 同一规则：
///
/// 逐条判据与 [selectDvdTitles] 共用（[minimumDuration] 绝对下限——厂标 / 警告画面都在
/// 一分钟内；VTS 读得出、cell 齐全），再去掉：
/// - 菜单背景循环：同一段 cell 在一个 title 里重复出现；
/// - 正片的重复与章节子集：cell 全被某条已入选的 title 包含；
/// - 特典之间的重复（同签名只留一条）与「全部播放」形状。
List<DvdTitle> selectDvdExtras(
  List<DvdTitleCandidate> candidates, {
  required List<DvdTitle> titles,
  required String discRootPath,
  required String discName,
  Duration minimumDuration = kBlurayMinimumTitleDuration,
}) {
  final Set<int> titleNumbers = <int>{
    for (final DvdTitle t in titles) t.titleNumber,
  };
  final List<Set<String>> titleCells = <Set<String>>[
    for (final DvdTitle t in titles) t.cellIds.toSet(),
  ];
  final Map<String, DvdTitleCandidate> bySignature =
      <String, DvdTitleCandidate>{};
  for (final DvdTitleCandidate c in candidates) {
    if (titleNumbers.contains(c.entry.titleNumber)) continue;
    if (c.duration < minimumDuration || c.cellIds.isEmpty) continue;
    final Set<String> cells = c.cellIds.toSet();
    if (cells.length != c.cellIds.length) continue;
    if (titleCells.any((Set<String> t) => t.containsAll(cells))) continue;
    final DvdTitleCandidate? existing = bySignature[_signature(c)];
    if (existing == null || _prefers(c, existing)) {
      bySignature[_signature(c)] = c;
    }
  }
  final List<DvdTitleCandidate> unique = bySignature.values.toList();
  final List<DvdTitleCandidate> pool = <DvdTitleCandidate>[
    for (final DvdTitle t in titles)
      DvdTitleCandidate(
        entry: t.entry,
        duration: t.duration,
        cellIds: t.cellIds,
      ),
    ...unique,
  ];
  final List<DvdTitleCandidate> kept =
      unique
          .where(
            (DvdTitleCandidate c) =>
                !discIsPlayAllOf<DvdTitleCandidate>(c, pool, _cellIdsOf),
          )
          .toList()
        ..sort(
          (DvdTitleCandidate a, DvdTitleCandidate b) =>
              a.entry.titleNumber.compareTo(b.entry.titleNumber),
        );
  return <DvdTitle>[
    for (final DvdTitleCandidate c in kept)
      DvdTitle(
        entry: c.entry,
        discRootPath: discRootPath,
        name: dvdExtraTitleName(discName, c.entry.titleNumber),
        isMainFeature: false,
        duration: c.duration,
        cellIds: c.cellIds,
      ),
  ];
}

/// libdvdread `DVDDiscID` 口径的盘身份：依次取 `VIDEO_TS.IFO`、`VTS_01_0.IFO` …
/// `VTS_09_0.IFO`（存在的那些，最多 10 个），每个取整块（2048 的整数倍）内容，拼起来
/// 求 MD5。[ifoContents] 按上述顺序给出（缺的跳过）。
///
/// 只取前 10 个 IFO 是 libdvdread 的原样行为（`for (title = 0; title < 10; ...)`）：
/// 身份要与原生侧算出的一致，播放器、字幕缓存按同一个 ID 认盘，所以这里不「改进」它。
String computeDvdDiscId(List<Uint8List> ifoContents) {
  final BytesBuilder all = BytesBuilder(copy: false);
  for (final Uint8List bytes in ifoContents.take(10)) {
    final int whole = bytes.length - bytes.length % kDvdLogicalBlockSize;
    all.add(Uint8List.sublistView(bytes, 0, whole));
  }
  return md5.convert(all.takeBytes()).toString();
}

Future<String> _discId(_VideoTsFiles files) async {
  final List<Uint8List> contents = <Uint8List>[];
  for (int i = 0; i < 10; i++) {
    final String name = i == 0 ? 'VIDEO_TS.IFO' : '${_vtsStem(i)}.IFO';
    if (!files.has(name)) continue;
    try {
      contents.add(await files.read(name));
    } on DvdIfoFormatException {
      continue;
    }
  }
  return computeDvdDiscId(contents);
}

/// 对文件夹形态的盘算 [computeDvdDiscId]。
Future<String> computeDvdDiscIdForDirectory(String discRootPath) =>
    _discId(_FolderVideoTs(_listVideoTs(discRootPath) ?? <String, String>{}));
