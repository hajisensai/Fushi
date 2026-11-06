// DVD title 的虚拟成员路径：纯字符串判据，不碰文件系统。
//
// 蓝光一条标题的身份是它自己的 `.mpls`——一个真实文件。DVD 没有「一个 title 一个
// 文件」的对应物：同一 VTS 里的多个 title 共用 `VTS_nn_0.IFO` 与那几个 VOB（TV 盘
// 一个 VTS 放 4 集是常态），镜像形态的盘更是整张只有一个 `.iso`。所以身份只能是
// 虚拟路径，两种形态同一个写法：
//
//     <盘根>/VIDEO_TS/TITLE_<nn>.dvdtitle      （nn = 全盘 title 号，两位补零）
//
// 盘根是含 `VIDEO_TS` 的目录（文件夹形态），或 `.iso` 文件本身（镜像形态，例如
// `D:/dvd/Show.iso/VIDEO_TS/TITLE_02.dvdtitle`）。
//
// 选它的理由：纯字符串就能反推盘根与 title 号；文件名去扩展名（`TITLE_03`）就是
// `coreSingleVideoBookUid` 的基身份，与蓝光 `00003` 同一形状，重扫对齐 / 去重逻辑原样
// 可用；扩展名 `.dvdtitle` 不在任何媒体白名单里，扫描器永远不会把它当文件列出来。
//
// 代价是它**不是真实文件**：「这一条还在不在」要经 [dvdTitleBackingFilePath] 换成
// 真实存在的那个文件再判（全仓统一入口是 `video_member_file.dart`）；它也**没有可直接
// 读的媒体字节**（`lacksLocalMediaFile` 为真），抽帧 / 哈希 / 上传一律跳过。
//
// 播放映射见 [dvdPlaybackUriForTitlePath]（原生 libdvdnav，mpv 的 `dvd://`）。

import 'package:path/path.dart' as p;

/// DVD 标题虚拟成员路径的扩展名。
const String kDvdTitlePathExtension = '.dvdtitle';

/// 盘目录名（规范强制大写，按精确大小写认，与 `bluray_disc.dart` 的 `BDMV` 同口径）。
const String kDvdVideoDirectory = 'VIDEO_TS';

/// [path] 是不是光盘镜像文件（`.iso`）。只看扩展名——它决定的是「盘根是文件还是
/// 目录」这种路径形状；镜像里装的是不是 DVD 由 `disc_image_probe.dart` 打开探测。
bool isDiscImagePath(String path) => p.extension(path).toLowerCase() == '.iso';

/// [titleNumber] 号 title 的虚拟成员路径。
String dvdTitlePath(String discRootPath, int titleNumber) => p.join(
  discRootPath,
  kDvdVideoDirectory,
  'TITLE_${titleNumber.toString().padLeft(2, '0')}$kDvdTitlePathExtension',
);

/// [path] 是不是一条 DVD title 的成员路径。
bool isDvdTitlePath(String path) =>
    p.extension(path).toLowerCase() == kDvdTitlePathExtension;

/// 从 title 成员路径反推盘根（目录或 `.iso` 文件）；形状不对返回 null。
String? dvdDiscRootForTitlePath(String titlePath) {
  if (!isDvdTitlePath(titlePath)) return null;
  final List<String> parts = p.split(p.normalize(titlePath));
  if (parts.length < 3) return null;
  if (parts[parts.length - 2] != kDvdVideoDirectory) return null;
  if (dvdTitleNumberForPath(titlePath) == null) return null;
  return p.joinAll(parts.sublist(0, parts.length - 2));
}

/// 从 title 成员路径取 title 号（1 起）；形状不对返回 null。
int? dvdTitleNumberForPath(String titlePath) {
  if (!isDvdTitlePath(titlePath)) return null;
  final Match? match = RegExp(
    r'^TITLE_(\d{2,3})$',
  ).firstMatch(p.basenameWithoutExtension(titlePath));
  if (match == null) return null;
  final int value = int.parse(match.group(1)!);
  return value >= 1 && value <= 99 ? value : null;
}

/// title 成员路径背后真实存在的那个文件：镜像形态是 `.iso` 本身，文件夹形态是
/// `VIDEO_TS/VIDEO_TS.IFO`。形状不对返回 null。
String? dvdTitleBackingFilePath(String titlePath) {
  final String? root = dvdDiscRootForTitlePath(titlePath);
  if (root == null) return null;
  if (isDiscImagePath(root)) return root;
  return p.join(root, kDvdVideoDirectory, 'VIDEO_TS.IFO');
}

/// 播放这一条 title 时交给 libmpv 的地址：`dvd://<title-1>/<盘根>`。
///
/// mpv 的 `dvd://` title 号从 0 起（`stream_dvdnav.c`：`dvdnav_title_play(…,
/// track + 1)`），库里的 title 号从 1 起，所以减一；盘根是目录或 `.iso`，libdvdread
/// 两种都直接吃。形状不对返回 null。
String? dvdPlaybackUriForTitlePath(String titlePath) {
  final String? root = dvdDiscRootForTitlePath(titlePath);
  final int? number = dvdTitleNumberForPath(titlePath);
  if (root == null || number == null) return null;
  return 'dvd://${number - 1}/$root';
}
