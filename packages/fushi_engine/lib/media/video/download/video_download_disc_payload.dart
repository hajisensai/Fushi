// 下载载荷（种子内相对路径）里的原盘：蓝光 `BDMV` 树、DVD `VIDEO_TS` 树、`.iso` 镜像。
//
// 原盘是**一个整体**（BUG-4245）：`index.bdmv` / `MovieObject.bdmv` / `PLAYLIST/*.mpls` /
// `CLIPINF/*.clpi` / `STREAM/*.m2ts` / `BACKUP/` / `CERTIFICATE/` 互相按相对位置引用，
// 拆开任何一个文件、改任何一个名字，整张盘就读不出来了。下载整理器以前把 `.m2ts` 当普通
// 视频逐个解集号、抬正片、镜像进 `Extras/`，元数据文件留在原路径，盘被拆成两半。
//
// 这里只认路径形状（纯函数，不碰文件系统），判据复用扫描器同一套
// （[planBlurayDiscRoots] / [planDvdDiscRoots]：精确大小写的 `BDMV/PLAYLIST/*.mpls`、
// `VIDEO_TS/VIDEO_TS.IFO`），下载整理与扫描导入认出的是同一批盘。

import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/video/bluray/bluray_disc.dart'
    show planBlurayDiscRoots;
import 'package:fushi_engine/media/video/dvd/dvd_disc.dart'
    show planDvdDiscRoots;
import 'package:fushi_engine/media/video/dvd/dvd_title_path.dart'
    show isDiscImagePath, kDvdVideoDirectory;

/// 下载载荷里一张盘的形态。
enum DownloadDiscFormat {
  /// 文件夹形态的蓝光（含 `BDMV/PLAYLIST/*.mpls`）。
  bluray,

  /// 文件夹形态的 DVD（含 `VIDEO_TS/VIDEO_TS.IFO`）。
  dvd,

  /// `.iso` 镜像（DVD 还是 BD 要导入时打开探测，不靠扩展名猜）。
  image,
}

/// 下载载荷里认出的一张盘。
class DownloadDiscRoot {
  const DownloadDiscRoot({required this.segments, required this.format});

  /// 盘根在种子内的路径段。文件夹形态是含 `BDMV` / `VIDEO_TS` 的那层目录（空 =
  /// 种子顶层就是盘）；镜像形态是 `.iso` 文件本身。
  final List<String> segments;

  final DownloadDiscFormat format;

  /// 盘根的种子内相对路径（`/` 分隔；顶层盘为空串）。
  String get path => segments.join('/');

  @override
  bool operator ==(Object other) =>
      other is DownloadDiscRoot && other.format == format && other.path == path;

  @override
  int get hashCode => Object.hash(format, path);

  @override
  String toString() => 'DownloadDiscRoot(${format.name}: $path)';
}

/// 文件夹形态的盘根下，属于盘的顶层目录。`BDMV` / `VIDEO_TS` 精确大小写（与认盘判据
/// 同一口径）；其余几个是盘上的附属目录（AACS 与证书、DVD 的音频区与封套图），同样
/// 只在整盘一起时才有意义。
const Set<String> _blurayDiscDirectories = <String>{
  'BDMV',
  'CERTIFICATE',
  'AACS',
};
const Set<String> _dvdDiscDirectories = <String>{
  kDvdVideoDirectory,
  'AUDIO_TS',
  'JACKET_P',
};

/// 把种子内相对路径切段（`/` 与 `\` 都认：qBittorrent 返回 `/`，内置引擎在 Windows
/// 上返回 `\`）。
List<String> downloadPayloadSegments(String relativePath) => relativePath
    .split(RegExp(r'[\\/]+'))
    .where((String s) => s.trim().isNotEmpty)
    .toList(growable: false);

/// 认盘时垫在相对路径前面的占位段：扫描器的认盘函数要求盘根之上至少还有一层
/// （它面对的是绝对路径），顶层就是 `BDMV/` 的种子没有这一层。
const String _payloadAnchor = '__fushi_download_payload__';

/// 从一批种子内相对路径里认出所有盘（按盘根路径排序，文件夹形态在前）。
List<DownloadDiscRoot> planDownloadDiscRoots(Iterable<String> relativePaths) {
  final List<List<String>> segmented = <List<String>>[
    for (final String path in relativePaths) downloadPayloadSegments(path),
  ];
  final List<String> anchored = <String>[
    for (final List<String> segments in segmented)
      if (segments.isNotEmpty) p.joinAll(<String>[_payloadAnchor, ...segments]),
  ];
  List<String> unanchor(String root) {
    final List<String> parts = p.split(p.normalize(root));
    return parts.isNotEmpty && parts.first == _payloadAnchor
        ? List<String>.unmodifiable(parts.sublist(1))
        : List<String>.unmodifiable(parts);
  }

  final List<DownloadDiscRoot> roots = <DownloadDiscRoot>[
    for (final String root in planBlurayDiscRoots(anchored))
      DownloadDiscRoot(
        segments: unanchor(root),
        format: DownloadDiscFormat.bluray,
      ),
    for (final String root in planDvdDiscRoots(anchored))
      DownloadDiscRoot(
        segments: unanchor(root),
        format: DownloadDiscFormat.dvd,
      ),
  ];
  final Set<String> folderRoots = <String>{
    for (final DownloadDiscRoot root in roots) root.path,
  };
  final List<DownloadDiscRoot> images = <DownloadDiscRoot>[
    for (final List<String> segments in segmented)
      if (segments.isNotEmpty && isDiscImagePath(segments.last))
        DownloadDiscRoot(
          segments: List<String>.unmodifiable(segments),
          format: DownloadDiscFormat.image,
        ),
  ];
  // 镜像躺在某张文件夹盘的树里（盘上自带的数据文件）时，它是那张盘的一部分。
  images.removeWhere(
    (DownloadDiscRoot image) =>
        _folderRootOwning(image.segments, roots) != null ||
        folderRoots.contains(image.path),
  );
  roots.sort(
    (DownloadDiscRoot a, DownloadDiscRoot b) => a.path.compareTo(b.path),
  );
  images.sort(
    (DownloadDiscRoot a, DownloadDiscRoot b) => a.path.compareTo(b.path),
  );
  return List<DownloadDiscRoot>.unmodifiable(<DownloadDiscRoot>[
    ...roots,
    ...images,
  ]);
}

/// [relativePath] 属于 [roots] 里哪张盘；不属于任何盘返回 null。
///
/// 文件夹形态：落在盘根下的 `BDMV/` `CERTIFICATE/` `AACS/`（蓝光）或 `VIDEO_TS/`
/// `AUDIO_TS/` `JACKET_P/`（DVD）里。盘根目录里的其它文件（扫图、说明文本）不归盘，
/// 与种子里其它非视频文件同一待遇。镜像形态：就是那个 `.iso`。
DownloadDiscRoot? downloadDiscRootOf(
  String relativePath,
  List<DownloadDiscRoot> roots,
) {
  if (roots.isEmpty) return null;
  final List<String> segments = downloadPayloadSegments(relativePath);
  for (final DownloadDiscRoot root in roots) {
    if (root.format == DownloadDiscFormat.image &&
        _sameSegments(root.segments, segments)) {
      return root;
    }
  }
  return _folderRootOwning(segments, roots);
}

DownloadDiscRoot? _folderRootOwning(
  List<String> segments,
  List<DownloadDiscRoot> roots,
) {
  for (final DownloadDiscRoot root in roots) {
    final Set<String> directories = switch (root.format) {
      DownloadDiscFormat.bluray => _blurayDiscDirectories,
      DownloadDiscFormat.dvd => _dvdDiscDirectories,
      DownloadDiscFormat.image => const <String>{},
    };
    if (directories.isEmpty) continue;
    final int depth = root.segments.length;
    // 至少还有「盘目录 + 文件」两段。
    if (segments.length < depth + 2) continue;
    if (!_sameSegments(root.segments, segments.sublist(0, depth))) continue;
    final String directory = segments[depth];
    final bool owned = directory == 'BDMV' || directory == kDvdVideoDirectory
        ? directories.contains(directory)
        : directories.contains(directory.toUpperCase());
    if (owned) return root;
  }
  return null;
}

bool _sameSegments(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 把手动选择的文件扩成**整盘**（BUG-4245）：选中了某张盘里的任何一个文件，就选中
/// 这张盘的全部文件。半张盘下下来既播不了、也入不了库。[pathsByIndex] 是种子全部
/// 文件（index → 种子内相对路径）。
Set<int> expandDownloadSelectionToWholeDiscs(
  Set<int> selected,
  Map<int, String> pathsByIndex,
) {
  final List<DownloadDiscRoot> roots = planDownloadDiscRoots(
    pathsByIndex.values,
  );
  if (roots.isEmpty) return selected;
  final Map<DownloadDiscRoot, Set<int>> members =
      <DownloadDiscRoot, Set<int>>{};
  for (final MapEntry<int, String> entry in pathsByIndex.entries) {
    final DownloadDiscRoot? root = downloadDiscRootOf(entry.value, roots);
    if (root == null) continue;
    (members[root] ??= <int>{}).add(entry.key);
  }
  final Set<int> expanded = <int>{...selected};
  for (final Set<int> disc in members.values) {
    if (disc.any(selected.contains)) expanded.addAll(disc);
  }
  return expanded;
}
